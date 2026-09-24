import Foundation
import StoreKit
import Combine
import OSLog

@MainActor
final class MembershipManager: ObservableObject {
    static let shared = MembershipManager()

    @Published private(set) var snapshot: MembershipSnapshot?
    @Published private(set) var products: [MembershipPlan: Product] = [:]
    /// Card text replacing `displayPrice` only while Apple's product metadata
    /// disagrees with its own storefront. Purchases still use `products`.
    @Published private(set) var listedPrices: [MembershipPlan: String] = [:]
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var productMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var diagnosticSummary: String?
    /// A completed explicit action owns this result. Background status updates
    /// may refresh inline feedback but must not erase or manufacture its alert.
    @Published private(set) var manualOperationFailure: String?
    @Published private(set) var isUsingCachedState = false
    @Published private(set) var dataDeleted = false

    // No persisted state is read until StoreKit verifies the current environment.
    private var keychain = MembershipKeychain(service: "com.shukaihu.RainyClock.membership.unresolved")
    private var client: MembershipClient?
    private var routing: MembershipRouting?
    private var identityGeneration = UUID()
    private var updates: Task<Void, Never>?
    private var subscriptionUpdates: Task<Void, Never>?
    private var storefrontUpdates: Task<Void, Never>?
    private var productLoadVersion = 0
    private var productLoadTask: Task<Void, Never>?
    private var localRefreshVersion = 0
    private var started = false
    private var accountIdentity: String?
    private var latestDiagnostic: MembershipDiagnostic?
    private var storefrontCountryCode: String?
    private var productCurrencyCodes: [String] = []
    private static let logger = Logger(subsystem: "com.shukaihu.RainyClock", category: "Membership")

    var isConfigured: Bool { MembershipConfiguration.serviceURL != nil || MembershipConfiguration.localStoreKitTesting }
    var isLocalStoreKitTesting: Bool { MembershipConfiguration.localStoreKitTesting }
    /// Only a verified Apple Sandbox context (or the isolated simulator fixture)
    /// exposes the temporary read-only price investigation tool.
    var canInspectSandboxPrices: Bool {
        isLocalStoreKitTesting || routing?.appleEnvironment == .sandbox
    }
    var entitlements: MembershipEntitlements { snapshot?.entitlements.valid(at: Date()) ?? .free }
    var canUseAdvancedRules: Bool { entitlements.calendar }
    /// Last server-confirmed rights, intentionally not recomputed from a phone clock.
    /// Failure to refresh must never reinterpret an existing alarm's paid rules.
    var schedulingEntitlements: MembershipEntitlements? {
        isConfigured ? snapshot?.entitlements : nil
    }
    var remaining: Int {
        guard let quota = snapshot?.quota else { return 0 }
        // Never replenish a daily allowance based on the phone clock. A server sync
        // is needed at the boundary, including after time-zone or device changes.
        let daily = quota.nextResetAt > Date().timeIntervalSince1970 * 1_000 ? quota.dailyRemaining : 0
        return max(0, daily) + max(0, quota.freeRemaining) + max(0, quota.rewardCredits)
    }

    init() {}

    deinit {
        updates?.cancel()
        subscriptionUpdates?.cancel()
        storefrontUpdates?.cancel()
        productLoadTask?.cancel()
    }

    /// Does not call AppTransaction.refresh or AppStore.sync: opening the app must
    /// not unexpectedly trigger an Apple sign-in sheet.
    func start() async {
        guard !started, isConfigured else { return }
        started = true
        clearFeedback()
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
        // Changing renewal preferences does not necessarily create a transaction.
        // This sequence is available on iOS 15+, including our iOS 17 minimum.
        subscriptionUpdates = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard let self else { return }
                guard case .verified(let transaction) = status.transaction,
                      MembershipPlan(rawValue: transaction.productID)?.isSubscription == true,
                      case .verified = status.renewalInfo else { continue }
                await self.refreshAfterManagingSubscriptions()
            }
        }
        storefrontUpdates = Task { [weak self] in
            for await storefront in Storefront.updates {
                guard !Task.isCancelled, let self else { return }
                self.storefrontCountryCode = storefront.countryCode
                self.updateDiagnosticSummary()
                // Storefront changes affect prices and availability, not membership
                // identity. Refreshing products never opens an Apple sign-in sheet.
                await self.loadProducts(invalidate: true)
            }
        }
        await loadProducts()
        if isLocalStoreKitTesting { await refreshLocalStoreKitState() }
        else {
            do {
                guard let current = try await prepareCurrentContext() else { throw MembershipError.sessionExpired }
                retryPendingJournalDeletion()
                if !dataDeleted {
                    if canReuseCurrentSession {
                        do { try await synchronizeExistingSession() }
                        catch {
                            // The session is bound to a device key this install no
                            // longer holds (the keychain outlived a reinstall). Only
                            // that local failure bootstraps here; server rejections
                            // still wait for an explicit action.
                            guard MembershipDeviceProof.isUnusableLocalKey(error) else { throw error }
                            keychain.remove("session")
                            try await establishSession(current, restoresDeletedMembership: false)
                        }
                    } else {
                        // A fresh shared proof can establish a new free member
                        // without a login sheet. An old proof is rejected by the
                        // server; only an explicit action may call refresh().
                        try await establishSession(current, restoresDeletedMembership: false)
                    }
                }
            } catch { report(error, at: .startup) }
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        manualOperationFailure = nil
        clearFeedback()
        defer { isBusy = false }
        var failure: MembershipDiagnosticFailure?
        do {
            try await synchronizeIdentity(restoresDeletedMembership: true)
        } catch {
            failure = MembershipDiagnosticFailure.wrapping(error, at: .refresh)
            report(error, at: .refresh)
        }
        // A failed membership sync must not leave prices from the old storefront.
        await loadProducts()
        if let failure { recordManualFailure(failure) }
    }

    /// Refresh on returning from Apple's subscription sheet without asking for
    /// sign-in or changing the user's renewal preference inside our own app.
    func refreshAfterManagingSubscriptions() async {
        // Returning from Apple's sheets can change the storefront even when a
        // purchase is still busy. Price refresh must not depend on identity sync.
        await refreshPrices()
        guard isConfigured, !isBusy else { return }
        if isLocalStoreKitTesting {
            await refreshLocalStoreKitState()
        } else {
            do {
                guard try await prepareCurrentContext() != nil else { throw MembershipError.sessionExpired }
                guard !dataDeleted else { return }
                if canReuseCurrentSession {
                    try await synchronizeExistingSession()
                } else if snapshot != nil {
                    // Re-authentication remains an explicit user action.
                    isUsingCachedState = true
                    message = MembershipText.value("請點「同步會員狀態」更新訂閱資訊。", "Tap Refresh membership to update your subscription status.")
                }
            } catch { report(error) }
        }
    }

    func refreshPrices() async {
        guard isConfigured else { return }
        await loadProducts()
    }

    func purchase(_ plan: MembershipPlan) async {
        guard !isBusy else { return }
        isBusy = true
        manualOperationFailure = nil
        clearFeedback()
        defer { isBusy = false }
        var attemptedPurchase = false
        do {
            guard plan.isOffered else { throw MembershipError.productUnavailable }
            guard isConfigured else { throw MembershipError.notConfigured }
            try await synchronizeIdentity(restoresDeletedMembership: true)
            // Authentication can switch the Storefront. Select a freshly fetched
            // Product before opening Apple's purchase confirmation.
            await loadProducts()
            // The plan may have been bought on another device since this view
            // appeared. Check the refreshed rights before opening Apple's sheet.
            if entitlements.lifetimeActive, plan.isSubscription {
                message = MembershipText.value("買斷已包含此方案的權益，不需要再訂閱。既有 Apple 訂閱可至「管理訂閱」取消續訂。", "Your one-time purchase already includes these benefits. You can cancel renewal of any existing Apple subscription in Manage subscriptions.")
                return
            }
            if entitlements.owns(plan) {
                message = MembershipText.value("此方案已生效。", "This plan is already active.")
                return
            }
            if entitlements.pendingSubscriptionPlan == plan {
                message = MembershipText.value("此方案將於下次續訂生效。", "This plan starts at your next renewal.")
                return
            }
            guard entitlements.canPurchase(plan) else { throw MembershipError.productUnavailable }
            guard let product = products[plan] else { throw MembershipError.productUnavailable }
            var options: Set<Product.PurchaseOption> = []
            if let raw = snapshot?.appAccountToken, let token = UUID(uuidString: raw) {
                options.insert(.appAccountToken(token))
            } else if !isLocalStoreKitTesting { throw MembershipError.unverified }
            attemptedPurchase = true
            switch try await product.purchase(options: options) {
            case .success(let result):
                guard case .verified(let transaction) = result else { throw MembershipError.unverified }
                try await recordTransaction(result)
                // Leave it unfinished when the backend cannot durably record it;
                // StoreKit will redeliver it for safe retry.
                await transaction.finish()
                message = MembershipText.value("購買已完成。", "Purchase completed.")
            case .pending: message = MembershipError.pending.localizedDescription
            case .userCancelled: message = nil
            @unknown default: throw MembershipError.unavailable
            }
        } catch { report(error, at: .purchase); recordManualFailure() }
        // Persist the purchase before waiting on unrelated price metadata. Apple
        // authentication may also switch storefront on cancellation or failure.
        if attemptedPurchase { await loadProducts(invalidate: true) }
    }

    func restorePurchases() async {
        guard !isBusy else { return }
        isBusy = true
        manualOperationFailure = nil
        clearFeedback()
        defer { isBusy = false }
        do {
            guard isConfigured else { throw MembershipError.notConfigured }
            try await AppStore.sync()
            try await synchronizeIdentity(restoresDeletedMembership: true)
            for await result in Transaction.unfinished {
                guard case .verified(let transaction) = result,
                      MembershipPlan(rawValue: transaction.productID) != nil else { continue }
                try await recordTransaction(result)
                await transaction.finish()
            }
            message = MembershipText.value("購買權益已恢復。鬧鐘設定及音檔不會跨裝置同步。", "Purchases restored. Alarm settings and audio do not sync between devices.")
        } catch { report(error, at: .restore); recordManualFailure() }
        await loadProducts(invalidate: true)
    }

    /// Used by generation and reward flows; proof and usage decisions stay on the server.
    /// Call this only for an explicit user action, because establishing identity can ask Apple
    /// to authenticate. The exact returned raw bytes are never interpreted as a client grant.
    func performAuthenticated(path: String, body: Data = Data("{}".utf8), expectedMemberId: String? = nil) async throws -> Data {
        do {
            guard isConfigured else { throw MembershipError.notConfigured }
            if dataDeleted { throw MembershipError.sessionExpired }
            // Polling and saved-audio downloads must not repeat full purchase sync
            // or depend on Apple Server API availability. Each request still reads
            // the verified current Apple identity before using its bound session.
            var response: Data?
            try await MembershipIdentitySynchronization.run(
                allowInteractiveRefresh: true, restoresDeletedMembership: false,
                shared: { try await self.prepareCurrentContext() },
                refresh: { try await self.prepareRefreshedContext() },
                isDeleted: { self.dataDeleted }, canReuseSession: { self.canReuseCurrentSession },
                reuseSession: {
                    response = try await self.requestForCurrentIdentity(path: path, body: body, expectedMemberId: expectedMemberId)
                },
                clearSession: { self.keychain.remove("session") },
                bootstrap: { proof in
                    try await self.establishSession(proof, restoresDeletedMembership: false)
                    // Only an explicit invalid_session/401 may retry the original
                    // request, preserving the same body and generation request ID.
                    response = try await self.requestForCurrentIdentity(path: path, body: body, expectedMemberId: expectedMemberId)
                })
            guard let response else { throw MembershipError.unavailable }
            return response
        } catch {
            report(error, at: .request)
            // Generation/reward callers must continue seeing their original server
            // errors so retry, journal recovery and quota handling stay unchanged.
            throw MembershipDiagnosticFailure.original(error)
        }
    }

    private func requestForCurrentIdentity(path: String, body: Data, expectedMemberId: String?) async throws -> Data {
        guard canReuseCurrentSession, let client else { throw MembershipError.sessionExpired }
        let generation = identityGeneration
        do {
            let data = try await client.request(path: path, body: body, expectedMemberId: expectedMemberId)
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            return data
        } catch {
            // Never let a stale account's invalid_session response clear the new
            // account's Keychain or trigger a bootstrap with the old proof.
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            throw error
        }
    }

    func updateSnapshot(_ data: Data) throws {
        let value = try JSONDecoder().decode(MembershipSnapshot.self, from: data)
        try save(value)
    }

    /// Explicit generation/ad action; may ask Apple to authenticate.
    func ensureIdentity() async throws {
        clearFeedback()
        do { try await synchronizeIdentity() }
        catch {
            report(error, at: .refresh)
            throw MembershipDiagnosticFailure.original(error)
        }
    }
    func refreshStatus() async throws {
        do { try await fetchStatus() }
        catch {
            report(error, at: .refresh)
            throw MembershipDiagnosticFailure.original(error)
        }
    }

    /// Uses an existing verified session only; starting banners must not open an
    /// Apple authentication sheet. Reward actions establish identity beforehand.
    func configureAdvertisingForVerifiedSession() async throws {
        guard AppEnvironment.allowsAdvertising else { throw MembershipError.server("advertising_unavailable_in_test_environment", 409) }
        guard let client, let memberId = snapshot?.memberId, !dataDeleted else {
            throw MembershipError.sessionExpired
        }
        let generation = identityGeneration
        let data = try await client.request(path: "/v1/membership/rewards/identity", expectedMemberId: memberId)
        struct Identity: Decodable { let userId: String }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard generation == identityGeneration, identity.userId.count == 48,
              snapshot?.memberId == memberId, !dataDeleted else {
            throw MembershipError.sessionExpired
        }
        guard ConsentManager.shared.configureRewardIdentity(identity.userId) else {
            throw MembershipError.server("reward_account_changed_restart_required", 409)
        }
        await ConsentManager.shared.requestConsentThenStartAds()
    }

    func deleteMembership() async {
        guard !isBusy else { return }
        isBusy = true
        manualOperationFailure = nil
        clearFeedback()
        defer { isBusy = false }
        do {
            guard isConfigured, !isLocalStoreKitTesting else { throw MembershipError.notConfigured }
            try await synchronizeIdentity()
            guard let client else { throw MembershipError.notConfigured }
            let generation = identityGeneration
            let deletedMember = snapshot?.memberId
            let response = try await client.request(path: "/v1/membership/delete", expectedMemberId: deletedMember)
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            if let accountIdentity { try keychain.markMembershipDeleted(for: accountIdentity) }
            let deletion = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            let cleanupPending = deletion?["cleanupPending"] as? Bool == true
            await client.forgetDeletedMembership()
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            keychain.remove("session")
            keychain.remove("snapshot")
            keychain.remove("accountIdentity")
            snapshot = nil
            accountIdentity = nil
            identityGeneration = UUID()
            dataDeleted = true
            isUsingCachedState = false
            ConsentManager.shared.invalidateMembershipRewardIdentity()
            if let deletedMember {
                try keychain.write(deletedMember, key: "pendingJournalDeletion")
                retryPendingJournalDeletion()
            }
            message = cleanupPending
                ? MembershipText.value("刪除請求已受理，資料清理中。Apple 訂閱不會因此取消，可至「管理訂閱」處理。", "Deletion accepted; cleanup is in progress. This does not cancel an Apple subscription. Use Manage subscriptions to cancel it.")
                : MembershipText.value("會員資料已刪除。Apple 訂閱不會因此取消，可至「管理訂閱」處理。", "Membership data deleted. This does not cancel an Apple subscription. Use Manage subscriptions to cancel it.")
        } catch { report(error, at: .deletion); recordManualFailure() }
    }

    private func loadProducts(invalidate: Bool = false) async {
        if invalidate {
            productLoadVersion += 1
            productLoadTask?.cancel()
            productLoadTask = nil
        }
        if productLoadTask == nil {
            productLoadVersion += 1
            let version = productLoadVersion
            products = [:]
            listedPrices = [:]
            productCurrencyCodes = []
            productMessage = nil
            isLoadingProducts = true
            updateDiagnosticSummary()
            productLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.fetchProducts(version: version)
                guard version == self.productLoadVersion else { return }
                self.isLoadingProducts = false
                self.productLoadTask = nil
            }
        }
        // Coalesce foreground/view refreshes. If Storefront.updates supersedes a
        // load, purchase preparation waits for its replacement too.
        while let pending = productLoadTask {
            await pending.value
            if Task.isCancelled { return }
        }
    }

    private func fetchProducts(version: Int) async {
        do {
            // Retired products may still supply renewal metadata for an existing
            // subscriber; the offered catalog and purchase guard exclude new sales.
            let catalog = try await MembershipProductCatalog.load(
                storefront: { await Storefront.current.map(MembershipCatalogStorefront.init) },
                products: { try await Product.products(for: MembershipPlan.allCases.map(\.rawValue)) },
                currency: { $0.priceFormatStyle.currencyCode })
            guard version == productLoadVersion, !Task.isCancelled else { return }
            storefrontCountryCode = catalog.storefront.countryCode
            productCurrencyCodes = catalog.products.map { $0.priceFormatStyle.currencyCode }
            updateDiagnosticSummary()
            products = Dictionary(uniqueKeysWithValues: catalog.products.compactMap { product in
                guard let plan = MembershipPlan(rawValue: product.id),
                      product.type == (plan.isSubscription ? .autoRenewable : .nonConsumable) else { return nil }
                return (plan, product)
            })
            // TestFlight can serve another storefront's products. Show this storefront's
            // listed price; Apple's payment sheet still states the actual charge.
            listedPrices = catalog.currencyMismatch ? products.keys.reduce(into: [:]) { prices, plan in
                prices[plan] = MembershipListedPrice.text(for: plan, storefrontCountryCode: catalog.storefront.countryCode)
            } : [:]
            if MembershipPlan.offeredPlans.contains(where: { products[$0] == nil }) {
                productMessage = MembershipText.value("部分方案價格暫時無法載入，請重試。", "Some plan prices could not be loaded. Please retry.")
            }
        } catch {
            guard version == productLoadVersion, !Task.isCancelled else { return }
            products = [:]
            listedPrices = [:]
            productMessage = MembershipText.value("暫時無法更新 App Store 價格，請重試。", "Could not update App Store prices. Please retry.")
            // Price availability is independent of membership verification. Never
            // replace a completed purchase result or mark verified rights stale.
            let diagnostic = MembershipDiagnostic(stage: .products, error: error)
            Self.logger.error("\(diagnostic.summary(storefront: self.storefrontCountryCode, currencies: self.productCurrencyCodes), privacy: .public)")
        }
    }

    private func synchronizeIdentity(restoresDeletedMembership: Bool = false) async throws {
        guard isConfigured else { throw MembershipError.notConfigured }
        if isLocalStoreKitTesting { await refreshLocalStoreKitState(); return }
        try await MembershipIdentitySynchronization.run(
            allowInteractiveRefresh: true, restoresDeletedMembership: restoresDeletedMembership,
            shared: { try await self.prepareCurrentContext() },
            refresh: { try await self.prepareRefreshedContext() },
            isDeleted: { self.dataDeleted }, canReuseSession: { self.canReuseCurrentSession },
            reuseSession: { try await self.synchronizeExistingSession() },
            clearSession: { self.keychain.remove("session") },
            bootstrap: { try await self.establishSession($0, restoresDeletedMembership: restoresDeletedMembership) })
    }

    private var canReuseCurrentSession: Bool {
        MembershipSessionBinding.canReuse(currentAccount: accountIdentity,
            persistedAccount: keychain.read(String.self, key: "accountIdentity"),
            environment: routing?.appleEnvironment, snapshot: snapshot,
            session: keychain.read(MembershipSession.self, key: "session"), deleted: dataDeleted)
    }

    private func synchronizeExistingSession() async throws {
        guard canReuseCurrentSession, let client, let memberId = snapshot?.memberId else { throw MembershipError.sessionExpired }
        let generation = identityGeneration
        do {
            // /status reconciles against Apple's server, using App Attest. A cached
            // snapshot alone can never count as a successful membership refresh.
            try await fetchStatus()
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            let signed = await signedCurrentTransactions()
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            if !signed.isEmpty {
                let body = try JSONSerialization.data(withJSONObject: ["signedTransactions": signed])
                let data = try await client.request(path: "/v1/membership/purchases", body: body, expectedMemberId: memberId)
                guard generation == identityGeneration else { throw MembershipError.sessionExpired }
                try updateSnapshot(data)
            }
            if let quota = snapshot?.quota,
               MembershipSessionBinding.needsTimeZoneUpdate(quota, currentTimeZone: TimeZone.current.identifier) {
                let body = try JSONSerialization.data(withJSONObject: ["timeZone": TimeZone.current.identifier])
                let data = try await client.request(path: "/v1/membership/time-zone", body: body, expectedMemberId: memberId)
                guard generation == identityGeneration else { throw MembershipError.sessionExpired }
                try updateSnapshot(data)
            }
            try? await submitLegacyMigrationIfNeeded()
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            if !entitlements.removeBanner { try? await configureAdvertisingForVerifiedSession() }
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        } catch {
            // A late A-account error must not clear B's session or bootstrap A.
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            throw error
        }
    }

    private func prepareRefreshedContext() async throws -> VerificationResult<AppTransaction>? {
        let generation = identityGeneration
        let result: VerificationResult<AppTransaction>
        do { result = try await AppTransaction.refresh() }
        catch {
            guard generation == identityGeneration else { return nil }
            throw MembershipDiagnosticFailure.wrapping(error, at: .appleRefresh)
        }
        guard generation == identityGeneration else { return nil }
        guard case .verified(let app) = result else {
            throw MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleProof)
        }
        try activateVerifiedContext(app)
        return result
    }

    private func establishSession(_ result: VerificationResult<AppTransaction>, restoresDeletedMembership: Bool) async throws {
        guard case .verified(let app) = result else {
            throw MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleProof)
        }
        guard !app.appTransactionID.isEmpty, let deviceID = AppStore.deviceVerificationID else {
            throw MembershipDiagnosticFailure.wrapping(MembershipError.missingIdentity, at: .appleProof)
        }
        try activateVerifiedContext(app)
        guard !dataDeleted || restoresDeletedMembership else { throw MembershipError.sessionExpired }
        guard let client, let routing else { throw MembershipError.notConfigured }
        let generation = identityGeneration
        let proof = MembershipAppleProof(environment: routing.appleEnvironment, signedAppTransaction: result.jwsRepresentation,
            appTransactionID: app.appTransactionID, deviceVerificationID: deviceID.uuidString,
            signedTransactions: await signedCurrentTransactions())
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        let session: MembershipSession
        do { session = try await client.bootstrap(proof) }
        catch {
            guard generation == identityGeneration else { throw MembershipError.sessionExpired }
            throw error
        }
        // No await is allowed between the identity check and Keychain persistence.
        // A late response for A can therefore never overwrite B's active session.
        guard MembershipSessionBinding.canPersist(capturedGeneration: generation, currentGeneration: identityGeneration,
            capturedAccount: app.appTransactionID, currentAccount: accountIdentity,
            capturedRouting: routing, currentRouting: self.routing) else { throw MembershipError.sessionExpired }
        try keychain.write(app.appTransactionID, key: "accountIdentity")
        try keychain.write(session, key: "session")
        try keychain.clearMembershipDeletion(for: app.appTransactionID)
        accountIdentity = app.appTransactionID
        dataDeleted = false
        try save(session.state)
        // Failure to submit an unverifiable legacy claim must not prevent verified
        // purchases or paid daily usage. Local counters remain entirely untouched.
        try? await submitLegacyMigrationIfNeeded()
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        if !entitlements.removeBanner { try? await configureAdvertisingForVerifiedSession() }
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
    }

    private func prepareCurrentContext() async throws -> VerificationResult<AppTransaction>? {
        // shared reads StoreKit's signed App Transaction without forcing the
        // authentication sheet that refresh() may present. Do not fall back to a
        // receipt filename, launch hint, or a cached member to choose the environment.
        let generation = identityGeneration
        let result: VerificationResult<AppTransaction>
        do { result = try await AppTransaction.shared }
        catch {
            guard generation == identityGeneration else { return nil }
            throw MembershipDiagnosticFailure.wrapping(error, at: .appleShared)
        }
        guard generation == identityGeneration else { return nil }
        guard case .verified(let app) = result else {
            throw MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleProof)
        }
        try activateVerifiedContext(app)
        return result
    }

    private func activateVerifiedContext(_ app: AppTransaction) throws {
        guard !app.appTransactionID.isEmpty,
              let environment = MembershipAppleEnvironment(rawValue: app.environment.rawValue),
              let url = MembershipConfiguration.serviceURL else {
            throw MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleRouting)
        }
        let next: MembershipRouting
        do { next = try MembershipConfiguration.routing(verifiedEnvironment: environment, baseURL: url) }
        catch { throw MembershipDiagnosticFailure.wrapping(error, at: .appleRouting) }
        guard routing != next || accountIdentity != app.appTransactionID else { return }
        let changesRoute = routing != next
        identityGeneration = UUID()
        ConsentManager.shared.invalidateMembershipRewardIdentity()
        MembershipAdvertisingGate.setVerifiedEnvironment(environment)
        let scoped = MembershipKeychain(service: next.keychainService)
        let storedIdentity = scoped.read(String.self, key: "accountIdentity")
        let cached = scoped.read(MembershipSnapshot.self, key: "snapshot")
        let deleted = scoped.membershipWasDeleted(for: app.appTransactionID)
        let acceptsCache = storedIdentity == app.appTransactionID && cached?.environment == environment.rawValue
        if storedIdentity != app.appTransactionID || (cached != nil && !acceptsCache) {
            scoped.remove("session")
            scoped.remove("snapshot")
            scoped.remove("accountIdentity")
        }
        keychain = scoped
        routing = next
        if changesRoute { client = MembershipClient(routing: next) }
        accountIdentity = app.appTransactionID
        snapshot = acceptsCache ? cached : nil
        isUsingCachedState = snapshot != nil
        dataDeleted = deleted
    }

    private func submitLegacyMigrationIfNeeded() async throws {
        guard let client, let snapshot, snapshot.quota.migrationPending else { return }
        let marker = "migrationSubmitted.\(snapshot.memberId)"
        guard keychain.read(Bool.self, key: marker) != true else { return }
        struct Claim: Codable {
            let migrationId: String
            let claimedFreeRemaining: Int
            let claimedRewardCredits: Int
        }
        let claim: Claim
        if let existing = keychain.read(Claim.self, key: "legacyMigrationClaim") { claim = existing }
        else {
            claim = .init(migrationId: UUID().uuidString, claimedFreeRemaining: AIVoiceQuota.freeRemaining,
                          claimedRewardCredits: AIVoiceQuota.earnedCredits)
            try keychain.write(claim, key: "legacyMigrationClaim")
        }
        let generation = identityGeneration
        _ = try await client.request(path: "/v1/membership/migration", body: JSONEncoder().encode(claim), expectedMemberId: snapshot.memberId)
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        try keychain.write(true, key: marker)
    }

    private func retryPendingJournalDeletion() {
        guard let memberId = keychain.read(String.self, key: "pendingJournalDeletion") else { return }
        do {
            try MembershipGenerationJournal.standard.removeMember(memberId)
            keychain.remove("pendingJournalDeletion")
        } catch { /* Retry after first unlock / next launch. Saved alarm audio is separate. */ }
    }

    private func signedCurrentTransactions() async -> [String] {
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let value) = result,
                  MembershipPlan(rawValue: value.productID) != nil else { continue }
            signed.append(result.jwsRepresentation)
        }
        return signed
    }

    private func recordTransaction(_ result: VerificationResult<Transaction>) async throws {
        guard case .verified(let value) = result, MembershipPlan(rawValue: value.productID) != nil else {
            throw MembershipError.unverified
        }
        if isLocalStoreKitTesting { await refreshLocalStoreKitState(); return }
        guard value.environment.rawValue == routing?.appleEnvironment.rawValue else { throw MembershipError.unverified }
        guard let client else { throw MembershipError.notConfigured }
        let generation = identityGeneration
        let body = try JSONSerialization.data(withJSONObject: ["signedTransactions": [result.jwsRepresentation]])
        let data = try await client.request(path: "/v1/membership/purchases", body: body, expectedMemberId: snapshot?.memberId)
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        try updateSnapshot(data)
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result, MembershipPlan(rawValue: transaction.productID) != nil,
              !dataDeleted else { return }
        do {
            // Background StoreKit updates never open an Apple login sheet. If the session
            // has expired, leave the transaction unfinished until the next explicit sync.
            try await recordTransaction(result)
            await transaction.finish()
        } catch { report(error) }
    }

    private func fetchStatus() async throws {
        guard let client, let memberId = snapshot?.memberId, canReuseCurrentSession else { throw MembershipError.sessionExpired }
        let generation = identityGeneration
        let data = try await client.request(path: "/v1/membership/status", expectedMemberId: memberId)
        guard generation == identityGeneration else { throw MembershipError.sessionExpired }
        try updateSnapshot(data)
    }

    private func save(_ value: MembershipSnapshot) throws {
        guard value.environment == routing?.appleEnvironment.rawValue else { throw MembershipError.unverified }
        try keychain.write(value, key: "snapshot")
        snapshot = value
        isUsingCachedState = false
        clearFeedback()
    }

    private func clearFeedback() {
        message = nil
        latestDiagnostic = nil
        diagnosticSummary = nil
    }

    private func recordManualFailure(_ failure: MembershipDiagnosticFailure? = nil) {
        // Refresh awaits StoreKit prices after authentication. Keep its captured
        // failure even if a background status response updated the inline state.
        let detail = failure?.diagnostic.summary(storefront: storefrontCountryCode,
                                                currencies: productCurrencyCodes) ?? diagnosticSummary
        let description = failure.map { MembershipFailureMessage.description(for: $0) } ?? message
        manualOperationFailure = [description, detail].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func updateDiagnosticSummary() {
        diagnosticSummary = latestDiagnostic?.summary(storefront: storefrontCountryCode,
                                                     currencies: productCurrencyCodes)
    }

    private func report(_ error: Error, at stage: MembershipDiagnosticStage = .request) {
        isUsingCachedState = snapshot != nil
        let failure = MembershipDiagnosticFailure.wrapping(error, at: stage)
        message = MembershipFailureMessage.description(for: failure)
        latestDiagnostic = failure.diagnostic
        updateDiagnosticSummary()
        if let diagnosticSummary {
            Self.logger.error("Membership failure: \(diagnosticSummary, privacy: .public)")
        }
    }

    private func refreshLocalStoreKitState() async {
        #if DEBUG && targetEnvironment(simulator)
        guard isLocalStoreKitTesting else { return }
        localRefreshVersion += 1
        let refreshVersion = localRefreshVersion
        let entitlement = await MembershipStoreKitEntitlements.current(products: products)
        guard refreshVersion == localRefreshVersion else { return }
        snapshot = MembershipSnapshot(memberId: "STOREKIT-LOCAL-TEST", supportCode: "LOCAL-TEST", environment: "Xcode",
            appAccountToken: "DA89FCC7-AE1D-42CF-A6E2-7914278FCF3E", verifiedAt: Date().timeIntervalSince1970 * 1_000,
            entitlements: entitlement,
            quota: .init(serviceDate: nil, nextResetAt: 0, timeZone: TimeZone.current.identifier,
                         dailyRemaining: 0, freeRemaining: 0, rewardCredits: 0, reserved: 0, migrationPending: false),
            policy: .init(version: "storekit-local-only", approved: false))
        isUsingCachedState = false
        #endif
    }
}

/// An independent reader used by the simulator-only membership preview and its
/// StoreKit tests. Production rights and AI quota remain server-authoritative.
enum MembershipStoreKitEntitlements {
    static func current(products: [MembershipPlan: Product], now: Date = Date()) async -> MembershipEntitlements {
        var subscriptionTransaction: Transaction?
        var lifetime = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  !transaction.isUpgraded, let plan = MembershipPlan(rawValue: transaction.productID) else { continue }
            if plan == .lifetime { lifetime = true }
            else if let expiry = transaction.expirationDate, expiry > now,
                    expiry > (subscriptionTransaction?.expirationDate ?? .distantPast) {
                subscriptionTransaction = transaction
            }
        }

        var autoRenews: Bool?
        var renewalProductId: String?
        if let transaction = subscriptionTransaction,
           let plan = MembershipPlan(rawValue: transaction.productID),
           let subscription = products[plan]?.subscription,
           let statuses = try? await subscription.status {
            for status in statuses {
                guard case .verified(let statusTransaction) = status.transaction,
                      statusTransaction.id == transaction.id,
                      statusTransaction.revocationDate == nil, !statusTransaction.isUpgraded,
                      case .verified(let renewal) = status.renewalInfo,
                      renewal.originalTransactionID == transaction.originalID,
                      renewal.currentProductID == transaction.productID else { continue }
                autoRenews = renewal.willAutoRenew
                if let preference = renewal.autoRenewPreference,
                   MembershipPlan(rawValue: preference)?.isSubscription == true {
                    renewalProductId = preference
                }
                break
            }
        }
        let subscription = subscriptionTransaction != nil
        return MembershipEntitlements(removeBanner: lifetime || subscription, calendar: lifetime || subscription,
            temporaryClosures: subscription, dailyAI: lifetime || subscription, subscriptionActive: subscription,
            lifetimeActive: lifetime,
            subscriptionExpiresAt: subscriptionTransaction?.expirationDate.map { $0.timeIntervalSince1970 * 1_000 },
            subscriptionProductId: subscriptionTransaction?.productID,
            subscriptionAutoRenews: autoRenews, subscriptionRenewalProductId: renewalProductId)
    }
}
