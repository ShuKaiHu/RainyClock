import Foundation
import StoreKit

/// A consistency fence for product metadata, not proof of the payment sheet's
/// storefront. Some TestFlight OS versions can return consistently wrong metadata.
struct MembershipCatalogStorefront: Equatable, Sendable {
    let id: String
    let countryCode: String
    let currencyCode: String?

    init(id: String, countryCode: String, currencyCode: String?) {
        self.id = id
        self.countryCode = countryCode
        self.currencyCode = currencyCode
    }

    init(_ storefront: Storefront) {
        self.init(id: storefront.id, countryCode: storefront.countryCode,
                  currencyCode: storefront.currency?.identifier)
    }
}

enum MembershipProductCatalog {
    /// Discard a catalog fetched across a storefront change or with mixed currencies.
    /// Retry once; never substitute a locally calculated price.
    ///
    /// A stable storefront whose products all carry one other currency is still
    /// Apple's own catalog: TestFlight on iOS 27 reports the Taiwan storefront while
    /// serving US products, and Apple's payment sheet charges the Taiwan price. It is
    /// published with `currencyMismatch` so the card can show the listed price, rather
    /// than hiding every plan and blocking the purchase.
    @MainActor static func load<Item>(
        storefront: () async -> MembershipCatalogStorefront?,
        products: () async throws -> [Item],
        currency: (Item) -> String
    ) async throws -> (storefront: MembershipCatalogStorefront, products: [Item], currencyMismatch: Bool) {
        var mismatched: (storefront: MembershipCatalogStorefront, products: [Item])?
        for _ in 0..<2 {
            try Task.checkCancellation()
            mismatched = nil
            let before = await storefront()
            let loaded = try await products()
            let after = await storefront()
            try Task.checkCancellation()
            guard let before, before == after else { continue }
            let currencies = Set(loaded.map(currency))
            guard let expected = before.currencyCode, currencies.contains(where: { $0 != expected }) else {
                return (before, loaded, false)
            }
            // A catalog cached from the previous storefront looks the same, so retry
            // first. Only the last attempt's stable, single-currency result may stand.
            if currencies.count == 1 { mismatched = (before, loaded) }
        }
        if let mismatched { return (mismatched.storefront, mismatched.products, true) }
        throw MembershipError.productUnavailable
    }
}

/// App Store Connect prices of the storefronts where plans are sold. Shown only when
/// Apple's product metadata disagrees with its own storefront (see
/// `MembershipProductCatalog.load`); otherwise the card shows `Product.displayPrice`.
/// Keep in step with App Store Connect. Any other storefront keeps Apple's price.
enum MembershipListedPrice {
    static func text(for plan: MembershipPlan, storefrontCountryCode: String) -> String? {
        switch (storefrontCountryCode, plan) {
        case ("TWN", .monthly): "NT$10"
        case ("TWN", .lifetime): "NT$100"
        case ("USA", .monthly): "$1.00"
        case ("USA", .lifetime): "$10.00"
        default: nil
        }
    }
}

/// Routing only. Backend signature validation still decides identity and rights.
enum MembershipAppleEnvironment: String, Codable, Sendable {
    case production = "Production"
    case sandbox = "Sandbox"
}

struct MembershipRouting: Equatable, Sendable {
    let baseURL: URL
    let appleEnvironment: MembershipAppleEnvironment
    let keychainService: String
}

enum MembershipPlan: String, CaseIterable, Identifiable, Sendable {
    case monthly = "com.shukaihu.RainyClock.plus.monthly"
    case yearly = "com.shukaihu.RainyClock.plus.yearly"
    case lifetime = "com.shukaihu.RainyClock.banner.lifetime"

    /// Retired products remain recognizable for restores and existing subscriptions.
    /// Only these plans may be displayed or selected for a new purchase.
    static let offeredPlans: [Self] = [.monthly, .lifetime]

    var id: String { rawValue }
    var isOffered: Bool { Self.offeredPlans.contains(self) }
    var isSubscription: Bool { self != .lifetime }
    var title: String {
        switch self {
        case .monthly: MembershipText.value("月訂閱", "Monthly subscription")
        case .yearly: MembershipText.value("年訂閱", "Yearly")
        case .lifetime: MembershipText.value("買斷", "One-time purchase")
        }
    }
}

struct MembershipEntitlements: Codable, Equatable, Sendable {
    var removeBanner: Bool
    var calendar: Bool
    var temporaryClosures: Bool
    var dailyAI: Bool
    var subscriptionActive: Bool
    var lifetimeActive: Bool
    var subscriptionExpiresAt: Double?
    var subscriptionProductId: String? = nil
    /// nil means Apple renewal information has not been verified yet, not cancelled.
    var subscriptionAutoRenews: Bool? = nil
    var subscriptionRenewalProductId: String? = nil

    static let free = Self(removeBanner: false, calendar: false, temporaryClosures: false,
                           dailyAI: false, subscriptionActive: false, lifetimeActive: false)

    var currentSubscriptionPlan: MembershipPlan? {
        guard subscriptionActive, let subscriptionProductId,
              let plan = MembershipPlan(rawValue: subscriptionProductId), plan.isSubscription else { return nil }
        return plan
    }

    var pendingSubscriptionPlan: MembershipPlan? {
        guard currentSubscriptionPlan != nil, subscriptionAutoRenews == true,
              let subscriptionRenewalProductId,
              let plan = MembershipPlan(rawValue: subscriptionRenewalProductId), plan.isSubscription,
              plan != currentSubscriptionPlan else { return nil }
        return plan
    }

    /// A permanent purchase is the displayed membership even while an Apple
    /// subscription remains active. Its renewal metadata must remain available.
    var preferredPlan: MembershipPlan? {
        lifetimeActive ? .lifetime : currentSubscriptionPlan
    }

    func owns(_ plan: MembershipPlan) -> Bool {
        plan == .lifetime ? lifetimeActive : currentSubscriptionPlan == plan
    }

    func canPurchase(_ plan: MembershipPlan) -> Bool {
        plan.isOffered && !owns(plan) && pendingSubscriptionPlan != plan
            && !(lifetimeActive && plan.isSubscription)
    }

    /// Expiring a cached access grant never changes saved rules or cancels scheduled alarms.
    /// Only the scheduling layer can perform a safe, explicit transition.
    func valid(at now: Date) -> Self {
        guard subscriptionActive, let subscriptionExpiresAt,
              now.timeIntervalSince1970 * 1_000 >= subscriptionExpiresAt else { return self }
        return .init(removeBanner: lifetimeActive, calendar: lifetimeActive, temporaryClosures: false,
                     dailyAI: lifetimeActive, subscriptionActive: false, lifetimeActive: lifetimeActive,
                     subscriptionExpiresAt: subscriptionExpiresAt,
                     subscriptionProductId: subscriptionProductId,
                     subscriptionAutoRenews: subscriptionAutoRenews,
                     subscriptionRenewalProductId: subscriptionRenewalProductId)
    }
}

struct MembershipQuota: Codable, Equatable, Sendable {
    var serviceDate: String?
    var nextResetAt: Double
    var timeZone: String?
    var pendingTimeZone: String? = nil
    var dailyRemaining: Int
    var freeRemaining: Int
    var rewardCredits: Int
    var rewardGrantCount: Int? = nil
    var reserved: Int
    var migrationPending: Bool
}

struct MembershipPolicy: Codable, Equatable, Sendable {
    var version: String
    var approved: Bool
}

struct MembershipSnapshot: Codable, Equatable, Sendable {
    var memberId: String
    var supportCode: String?
    var environment: String?
    var appAccountToken: String?
    var verifiedAt: Double?
    var entitlements: MembershipEntitlements
    var quota: MembershipQuota
    var policy: MembershipPolicy
}

struct MembershipSession: Codable, Sendable {
    var token: String
    var expiresAt: Double
    var memberId: String
    var state: MembershipSnapshot

    var isValid: Bool { expiresAt > Date().timeIntervalSince1970 * 1_000 + 30_000 }
}

/// Bounded identity refresh policy. Closures keep Apple and App Attest in their
/// production adapters, while tests exercise cancellations, expiry and account races.
@MainActor
enum MembershipIdentitySynchronization {
    static func run<Proof: Sendable>(
        allowInteractiveRefresh: Bool, restoresDeletedMembership: Bool,
        shared: @MainActor () async throws -> Proof?, refresh: @MainActor () async throws -> Proof?,
        isDeleted: @MainActor () -> Bool, canReuseSession: @MainActor () -> Bool,
        reuseSession: @MainActor () async throws -> Void, clearSession: @MainActor () -> Void,
        bootstrap: @MainActor (Proof) async throws -> Void
    ) async throws {
        var refreshed = false
        func freshProof() async throws -> Proof {
            guard allowInteractiveRefresh, !refreshed else { throw MembershipError.sessionExpired }
            refreshed = true
            guard let proof = try await refresh() else { throw MembershipError.sessionExpired }
            return proof
        }
        let sharedProof: Proof?
        do { sharedProof = try await shared() }
        catch {
            // Only Apple acquisition / verification failure can ask Apple to retry.
            // Routing, Keychain, identity-generation and server failures cannot.
            guard allowInteractiveRefresh, let failure = error as? MembershipDiagnosticFailure,
                  failure.diagnostic.stage == .appleShared || failure.diagnostic.stage == .appleProof else { throw error }
            sharedProof = try await freshProof()
        }
        // nil means another verified identity won while StoreKit was suspended.
        // Never turn that cancellation into a bootstrap for the old account.
        guard var proof = sharedProof else { throw MembershipError.sessionExpired }
        if isDeleted() {
            guard restoresDeletedMembership, allowInteractiveRefresh else { throw MembershipError.sessionExpired }
            // Deletion rotates the device key. A previously used shared proof must
            // not bind that new key; explicit recreation needs a fresh Apple proof.
            if !refreshed { proof = try await freshProof() }
        } else if canReuseSession() {
            do { try await reuseSession(); return }
            catch {
                // A server-expired/revoked session can bootstrap once, and so can a
                // session bound to a device key this install no longer holds (a
                // keychain that outlived a reinstall); bootstrap rotates that key.
                // Other 401s, App Attest service failures and network errors remain
                // fail-closed.
                guard isServerError(error, code: "invalid_session", status: 401)
                        || MembershipDeviceProof.isUnusableLocalKey(error) else { throw error }
                clearSession()
            }
        }
        do { try await bootstrap(proof) }
        catch {
            guard allowInteractiveRefresh, !refreshed,
                  isServerError(error, code: "app_transaction_refresh_required", status: 401) else { throw error }
            proof = try await freshProof()
            try await bootstrap(proof)
        }
    }

    static func isServerError(_ error: any Error, code: String, status: Int) -> Bool {
        guard case .server(let actualCode, let actualStatus) = MembershipDiagnosticFailure.original(error) as? MembershipError else { return false }
        return code == actualCode && status == actualStatus
    }
}

/// Existing build-31 sessions remain valid; no new persisted identity claim is
/// invented. All existing bindings must agree before the server session is reused.
enum MembershipSessionBinding {
    static func canReuse(currentAccount: String?, persistedAccount: String?, environment: MembershipAppleEnvironment?,
                         snapshot: MembershipSnapshot?, session: MembershipSession?, deleted: Bool) -> Bool {
        guard !deleted, let currentAccount, !currentAccount.isEmpty, currentAccount == persistedAccount,
              let environment, let snapshot, let session, session.isValid, !session.token.isEmpty,
              session.memberId == snapshot.memberId, session.memberId == session.state.memberId,
              snapshot.environment == environment.rawValue, session.state.environment == environment.rawValue else { return false }
        return true
    }

    static func canPersist(capturedGeneration: UUID, currentGeneration: UUID,
                           capturedAccount: String, currentAccount: String?,
                           capturedRouting: MembershipRouting, currentRouting: MembershipRouting?) -> Bool {
        capturedGeneration == currentGeneration && capturedAccount == currentAccount && capturedRouting == currentRouting
    }

    static func needsTimeZoneUpdate(_ quota: MembershipQuota, currentTimeZone: String) -> Bool {
        // The server activates a pending zone only at its protected daily boundary.
        // Returning to the active zone must also cancel a different pending change.
        if let pending = quota.pendingTimeZone { return pending != currentTimeZone }
        return quota.timeZone != currentTimeZone
    }
}

enum MembershipFailureMessage {
    static func description(for error: any Error) -> String {
        let original = MembershipDiagnosticFailure.original(error)
        if let appleError = original as? StoreKitError, case .userCancelled = appleError {
            return MembershipText.value("Apple 認證未完成，此次操作已停止，請再試一次。",
                "Apple authentication was not completed. This action has stopped. Please try again.")
        }
        return (original as? MembershipError ?? .unavailable).localizedDescription
    }
}

enum MembershipConfiguration {
    static func routing(verifiedEnvironment: MembershipAppleEnvironment, baseURL: URL,
                        legacySandbox: Bool = sandboxTesting,
                        legacyKeychainService: String = keychainService) throws -> MembershipRouting {
        guard let origin = validatedServiceURL(baseURL.absoluteString) else { throw MembershipError.notConfigured }
        if legacySandbox {
            guard verifiedEnvironment == .sandbox else { throw MembershipError.unverified }
            return MembershipRouting(baseURL: origin, appleEnvironment: .sandbox,
                                     keychainService: legacyKeychainService)
        }
        // Separate keys as well as sessions: production App Attest and development
        // App Attest must never share an attested key, nor may Apple environments.
        return MembershipRouting(baseURL: origin, appleEnvironment: verifiedEnvironment,
            keychainService: "com.shukaihu.RainyClock.membership.v2.\(verifiedEnvironment.rawValue).\(origin.host!)")
    }

    /// A dedicated installed test build must keep its endpoint and ad isolation
    /// when launched from the Home Screen without Xcode arguments/environment.
    static var isSandboxBuild: Bool {
        #if DEBUG && MEMBERSHIP_SANDBOX
        true
        #else
        false
        #endif
    }

    static var sandboxTesting: Bool {
        sandboxTesting(arguments: ProcessInfo.processInfo.arguments)
    }

    static func sandboxTesting(arguments: [String], sandboxBuild: Bool = isSandboxBuild) -> Bool {
        #if DEBUG
        sandboxBuild || arguments.contains("-membership-sandbox-test")
        #else
        false
        #endif
    }

    /// Blank until the independent membership backend and its verification are configured.
    static var serviceURL: URL? {
        resolvedServiceURL(
            bundleValue: Bundle.main.object(forInfoDictionaryKey: "MembershipServiceURL") as? String,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
    }

    /// The installed Debug Sandbox build pins the isolated test endpoint. Normal
    /// Debug builds can still opt in with launch arguments. Release ignores both.
    static func resolvedServiceURL(bundleValue: String?, arguments: [String],
                                   environment: [String: String], sandboxBuild: Bool = isSandboxBuild) -> URL? {
        #if DEBUG
        if arguments.contains("-membership-storekit-test") { return nil }
        if sandboxBuild {
            return URL(string: "https://rainyclock-membership-sandbox-510427696731.asia-east1.run.app")
        }
        if arguments.contains("-membership-sandbox-test") {
            // A missing/malformed Sandbox URL must not fall through to production.
            return validatedServiceURL(environment["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL"])
        }
        #endif
        return validatedServiceURL(bundleValue)
    }

    /// Accept an HTTPS service origin only: paths, query strings, credentials and
    /// fragments can change request routing or accidentally expose proof material.
    static func validatedServiceURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || components.port == 443 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 &&
                  label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { byte in
                      (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 45
                  }
              }) else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.port = nil
        components.path = ""
        return components.url
    }

    static var keychainService: String {
        keychainService(arguments: ProcessInfo.processInfo.arguments,
                        environment: ProcessInfo.processInfo.environment)
    }

    static func keychainService(arguments: [String], environment: [String: String],
                                sandboxBuild: Bool = isSandboxBuild) -> String {
        let normalService = "com.shukaihu.RainyClock.membership.v1"
        #if DEBUG
        if sandboxTesting(arguments: arguments, sandboxBuild: sandboxBuild),
           let host = resolvedServiceURL(bundleValue: nil, arguments: arguments, environment: environment,
                                         sandboxBuild: sandboxBuild)?.host {
            // Isolate sessions, cached rights and App Attest keys from the normal
            // app and from other test backends without deleting any saved data.
            return normalService + ".sandbox." + host
        }
        #endif
        return normalService
    }

    static var localStoreKitTesting: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-membership-storekit-test")
        #else
        return false
        #endif
    }
}

enum MembershipError: Error, LocalizedError, Equatable {
    case notConfigured, unavailable, unverified, missingIdentity, deviceUnsupported
    case sessionExpired, pending, productUnavailable, keychainUnavailable
    case server(String, Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return MembershipText.value("會員服務尚未開放。", "Membership is not available yet.")
        case .unavailable: return MembershipText.value("目前無法連線，請稍後再試。原有鬧鐘仍會保留。", "Could not connect. Try again later. Your existing alarms are preserved.")
        case .unverified, .missingIdentity: return MembershipText.value("無法驗證 App Store 資料，請稍後恢復購買。", "Could not verify App Store information. Try restoring purchases later.")
        case .deviceUnsupported: return MembershipText.value("這台裝置目前無法完成安全驗證。", "This device cannot complete secure verification.")
        case .sessionExpired: return MembershipText.value("請重新同步會員狀態。", "Please refresh your membership.")
        case .pending: return MembershipText.value("購買正在等待 Apple 批准。", "Your purchase is awaiting approval from Apple.")
        case .productUnavailable: return MembershipText.value("此方案目前無法購買。", "This plan is currently unavailable.")
        case .keychainUnavailable: return MembershipText.value("無法安全儲存會員資料，請解鎖裝置後重試。", "Could not securely save membership information. Unlock your device and try again.")
        case .server(let code, _):
            if code == "quota_exhausted" { return MembershipText.value("今天的額度已用完，可完成一次獎勵廣告或等明天。", "Today's allowance is used. Complete a rewarded ad or wait until tomorrow.") }
            return MembershipText.value("會員服務暫時無法完成此操作，請稍後重試。", "Membership could not complete this action. Please try again later.")
        }
    }
}

/// Diagnostic labels are fixed by the app, never supplied by Apple, a URL or the server.
enum MembershipDiagnosticStage: String, Sendable {
    case startup = "startup", appleShared = "apple-shared", appleRefresh = "apple-refresh"
    case appleProof = "apple-proof", appleRouting = "apple-routing"
    case appAttestKey = "attest-key", appAttestRegistration = "attest-registration"
    case appAttestAssertion = "attest-assertion", keychain = "keychain"
    case challenge = "challenge", session = "session", request = "request"
    case challengeNetwork = "challenge-network", sessionNetwork = "session-network"
    case requestNetwork = "request-network", products = "products"
    case refresh = "refresh", purchase = "purchase", restore = "restore", deletion = "deletion"
}

struct MembershipDiagnostic: Equatable, Sendable {
    let stage: MembershipDiagnosticStage
    let domain: String
    let code: Int

    init(stage: MembershipDiagnosticStage, error: any Error) {
        self.stage = stage
        if let memberError = error as? MembershipError {
            switch memberError {
            case .server(_, let status): domain = "MembershipHTTP"; code = status
            case .notConfigured: domain = "Membership"; code = 1
            case .unavailable: domain = "Membership"; code = 2
            case .unverified: domain = "Membership"; code = 3
            case .missingIdentity: domain = "Membership"; code = 4
            case .deviceUnsupported: domain = "Membership"; code = 5
            case .sessionExpired: domain = "Membership"; code = 6
            case .pending: domain = "Membership"; code = 7
            case .productUnavailable: domain = "Membership"; code = 8
            case .keychainUnavailable: domain = "Membership"; code = 9
            }
            return
        }
        let native = error as NSError
        // Even NSError.domain is untrusted. Do not accept arbitrary strings merely
        // because they look identifier-like: they could contain an account or token.
        let knownDomains: Set<String> = [
            NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
            "SKErrorDomain", "StoreKit.StoreKitError", "StoreKitError",
            "com.apple.devicecheck.error", "DeviceCheck.DCError",
            "ASDErrorDomain", "AMSErrorDomain", "AKAuthenticationErrorDomain"
        ]
        domain = knownDomains.contains(native.domain) ? native.domain : "OtherError"
        code = native.code
        // Never read localizedDescription, failure reason, userInfo, URLs, request
        // bodies, JWS, keys, tokens or account identifiers for diagnostics.
    }

    func summary(storefront: String?, currencies: [String]) -> String {
        func safeCode(_ value: String?) -> String? {
            guard let value, value.utf8.count == 3,
                  value.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
            return value
        }
        let currency = Set(currencies.compactMap(safeCode)).sorted().joined(separator: ",")
        return "\(stage.rawValue) · \(domain)/\(code) · store=\(safeCode(storefront) ?? "unknown") · currency=\(currency.isEmpty ? "unknown" : currency)"
    }
}

/// Preserve the original error for quota/retry/security decisions while transporting
/// only a sanitized description to the membership screen. Innermost stage wins.
struct MembershipDiagnosticFailure: Error {
    let cause: any Error
    let diagnostic: MembershipDiagnostic

    static func wrapping(_ error: any Error, at stage: MembershipDiagnosticStage) -> Self {
        if let existing = error as? Self { return existing }
        return Self(cause: error, diagnostic: MembershipDiagnostic(stage: stage, error: error))
    }

    static func original(_ error: any Error) -> any Error {
        (error as? Self)?.cause ?? error
    }
}

/// Kept with this feature so it can be reviewed without changing existing localisation files.
enum MembershipText {
    static func value(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }
}

enum MembershipSchedulingAccess {
    /// A missing/failed membership sync is not a revocation. Callers supply only a
    /// previously server-verified snapshot, or nil while rollout is disabled/unknown.
    static func effectiveSettings(_ saved: CommuteAlarmSettings,
                                  entitlements: MembershipEntitlements?) -> CommuteAlarmSettings {
        guard let entitlements else { return saved }
        var effective = saved
        if !entitlements.calendar { effective.calendarSettings.isEnabled = false }
        if !entitlements.temporaryClosures { effective.isDisasterSuspensionEnabled = false }
        return effective
    }
}

/// What the "使用臨時放假規則" switch may offer on this plan. It never decides which plan
/// includes the rule — that stays in `MembershipEntitlements.temporaryClosures` — and it
/// never clears a saved preference: saved premium rules remain recoverable.
///
/// Two entitlement sources are involved and they can disagree. The lock follows the
/// clock-validated `MembershipManager.entitlements` (what the plan screen shows), but
/// whether the rule is *applied* is whatever scheduling does with
/// `MembershipManager.schedulingEntitlements` — the raw server-confirmed snapshot, or
/// nil (saved settings pass through) when there is none. So the caller passes
/// `appliedEnabled` from `AlarmViewModel.effectiveSchedulingSettings`, and anything the
/// screen says about the rule being applied comes from that, never from the lock.
struct TemporaryClosureControlState: Equatable, Sendable {
    enum Access: Equatable, Sendable {
        /// The membership service is off, or the plan includes the rule.
        case available
        /// Scheduling has no server-confirmed plan (no snapshot yet, after membership
        /// data deletion, or App Attest failing), or it still holds a confirmed plan
        /// with the rule that the phone clock says has lapsed. Scheduling passes the
        /// saved rule through in both, so the screen must not call the plan locked.
        case unconfirmed
        /// A confirmed plan without the rule.
        case locked
    }

    let access: Access
    let savedEnabled: Bool
    let appliedEnabled: Bool
    /// Only a plan that could still buy the rule is sent to the plans screen. A lifetime
    /// owner is not: the plan mapping for lifetime is undecided, and that screen's
    /// subscription cards would read as saying the purchase includes it.
    let offersPlans: Bool

    static func resolve(membershipConfigured: Bool, entitlements: MembershipEntitlements,
                        schedulingEntitlements: MembershipEntitlements?,
                        savedEnabled: Bool, appliedEnabled: Bool) -> Self {
        let access: Access
        if !membershipConfigured || entitlements.temporaryClosures {
            access = .available
        } else if schedulingEntitlements?.temporaryClosures ?? true {
            access = .unconfirmed
        } else {
            access = .locked
        }
        return .init(access: access, savedEnabled: savedEnabled, appliedEnabled: appliedEnabled,
                     offersPlans: access == .locked && !entitlements.lifetimeActive)
    }

    /// Turning the rule on, and opening its preferences and live map.
    var allowsEditing: Bool { access == .available }
    /// Turning it off is always allowed: keeping a saved preference never means
    /// refusing to let the user stop push registration or closure-based skips.
    var allowsToggle: Bool { allowsEditing || savedEnabled }
    /// The saved preference is on, but scheduling drops it from the alarm and push.
    var keepsSavedRuleUnapplied: Bool { access != .available && savedEnabled && !appliedEnabled }
    /// The switch can't be turned on here, yet the saved rule is still being applied.
    var savedRuleStillApplied: Bool { access != .available && savedEnabled && appliedEnabled }
}
