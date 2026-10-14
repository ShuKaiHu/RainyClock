import XCTest
import StoreKit
import StoreKitTest
@testable import RainyClock

/// These tests exercise Apple's local StoreKit service. They deliberately do
/// not send Xcode-signed transactions to a network membership environment.
@MainActor
final class MembershipStoreKitTests: XCTestCase {
    private func session() async throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RainyClockMembership", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        _ = try await waitForEntitlements("cleared StoreKit session") { $0.isEmpty }
        return session
    }

    private func entitlements() async -> [StoreKit.Transaction] {
        var result: [StoreKit.Transaction] = []
        for await value in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = value { result.append(transaction) }
        }
        return result
    }

    /// SKTestSession mutations finish before StoreKit's currentEntitlements cache
    /// necessarily receives the corresponding transaction update. Observe the
    /// public result rather than treating a synchronous test-control call as a UI
    /// delivery barrier. This remains bounded and fails with the actual receipt IDs.
    private func waitForEntitlements(
        _ description: String,
        matching predicate: ([StoreKit.Transaction]) -> Bool
    ) async throws -> [StoreKit.Transaction] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var latest: [StoreKit.Transaction] = []
        repeat {
            latest = await entitlements()
            if predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(description); received \(latest.map { "\($0.productID):\($0.id)" })")
        return latest
    }

    private func waitForMembership(
        _ description: String,
        products: [MembershipPlan: Product],
        matching predicate: (MembershipEntitlements) -> Bool
    ) async throws -> MembershipEntitlements {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var latest = MembershipEntitlements.free
        repeat {
            latest = await MembershipStoreKitEntitlements.current(products: products)
            if predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for \(description); received \(latest)")
        return latest
    }

    func testVerifiedRenewalCancellationKeepsMonthlyAccessUntilExpiry() async throws {
        let session = try await session()
        defer { session.clearTransactions() }
        let loaded = try await Product.products(for: MembershipPlan.allCases.map(\.rawValue))
        let products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product -> (MembershipPlan, Product)? in
            guard let plan = MembershipPlan(rawValue: product.id) else { return nil }
            return (plan, product)
        })
        let monthly = try XCTUnwrap(products[.monthly])
        _ = try await session.buyProduct(identifier: monthly.id)
        let purchased = try await waitForMembership("active monthly auto-renewal", products: products) {
            $0.currentSubscriptionPlan == .monthly && $0.subscriptionAutoRenews == true
        }
        XCTAssertTrue(purchased.owns(.monthly))
        XCTAssertFalse(purchased.owns(.yearly))
        XCTAssertTrue(purchased.temporaryClosures, "the monthly subscription includes the day-off rule")
        let transactions = await entitlements()
        let transaction = try XCTUnwrap(transactions.first { $0.productID == monthly.id })
        let expiry = try XCTUnwrap(purchased.subscriptionExpiresAt)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        let cancelled = try await waitForMembership("cancelled renewal retaining monthly access", products: products) {
            $0.currentSubscriptionPlan == .monthly && $0.subscriptionAutoRenews == false
        }
        XCTAssertTrue(cancelled.subscriptionActive)
        XCTAssertTrue(cancelled.calendar)
        XCTAssertEqual(cancelled.subscriptionExpiresAt, expiry)
        // A missing product/status response must not guess that renewal is off.
        let statusUnavailable = await MembershipStoreKitEntitlements.current(products: [:])
        XCTAssertEqual(statusUnavailable.currentSubscriptionPlan, .monthly)
        XCTAssertNil(statusUnavailable.subscriptionAutoRenews)
        try session.enableAutoRenewForTransaction(identifier: UInt(transaction.id))
        _ = try await waitForMembership("resumed auto-renewal", products: products) {
            $0.currentSubscriptionPlan == .monthly && $0.subscriptionAutoRenews == true
        }
        try session.expireSubscription(productIdentifier: monthly.id)
        let expired = try await waitForMembership("expired monthly plan", products: products) {
            !$0.subscriptionActive && $0.currentSubscriptionPlan == nil
        }
        XCTAssertFalse(expired.owns(.monthly))
        XCTAssertFalse(expired.calendar)
        XCTAssertFalse(expired.temporaryClosures)
    }

    func testLocalProductsPurchaseRestoreRenewExpireAndRefund() async throws {
        let session = try await session()
        defer { session.clearTransactions() }
        let products = try await Product.products(for: MembershipPlan.allCases.map(\.rawValue))
        XCTAssertEqual(Set(products.map(\.id)), Set(MembershipPlan.offeredPlans.map(\.rawValue)))
        let monthly = try XCTUnwrap(products.first { $0.id == MembershipPlan.monthly.rawValue })
        let lifetime = try XCTUnwrap(products.first { $0.id == MembershipPlan.lifetime.rawValue })
        let productsByPlan = Dictionary(uniqueKeysWithValues: products.compactMap { product -> (MembershipPlan, Product)? in
            guard let plan = MembershipPlan(rawValue: product.id) else { return nil }
            return (plan, product)
        })
        XCTAssertEqual(monthly.type, .autoRenewable)
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(lifetime.type, .nonConsumable)
        XCTAssertEqual(monthly.price, 1)
        XCTAssertEqual(lifetime.price, 15)
        XCTAssertFalse(monthly.displayPrice.isEmpty)
        let token = UUID()
        guard case .success(.verified(let purchase)) = try await monthly.purchase(options: [.appAccountToken(token)]) else {
            return XCTFail("Expected a verified local purchase")
        }
        XCTAssertEqual(purchase.appAccountToken, token)
        await purchase.finish()
        _ = try await session.buyProduct(identifier: lifetime.id)
        // AppStore.sync restores StoreKit benefits; it cannot restore app files.
        try await AppStore.sync()
        let restored = try await waitForEntitlements("monthly and lifetime restoration") {
            Set($0.map(\.productID)) == [monthly.id, lifetime.id]
        }
        XCTAssertEqual(Set(restored.map(\.productID)), [monthly.id, lifetime.id])
        let upgraded = try await waitForMembership("lifetime taking precedence over an active subscription", products: productsByPlan) {
            $0.preferredPlan == .lifetime && $0.subscriptionActive && $0.subscriptionAutoRenews == true
        }
        XCTAssertTrue(upgraded.calendar)
        XCTAssertTrue(upgraded.temporaryClosures)
        XCTAssertTrue(upgraded.removeBanner)
        XCTAssertTrue(upgraded.dailyAI)
        XCTAssertFalse(upgraded.canPurchase(.monthly))
        // A non-consumable does not cancel an independently auto-renewing subscription.
        XCTAssertEqual(upgraded.currentSubscriptionPlan, .monthly)
        try session.forceRenewalOfSubscription(productIdentifier: monthly.id)
        let renewed = try await waitForEntitlements("renewed monthly transaction") {
            $0.contains { $0.productID == monthly.id && $0.id != purchase.id }
        }
        XCTAssertTrue(renewed.contains { $0.productID == monthly.id && $0.id != purchase.id })
        try session.expireSubscription(productIdentifier: monthly.id)
        let expired = try await waitForEntitlements("subscription expiration retaining lifetime") {
            Set($0.map(\.productID)) == [lifetime.id]
        }
        XCTAssertEqual(Set(expired.map(\.productID)), [lifetime.id])
        let lifetimeOnly = try await waitForMembership("permanent calendar access after subscription expiry", products: productsByPlan) {
            $0.lifetimeActive && !$0.subscriptionActive
        }
        XCTAssertTrue(lifetimeOnly.calendar)
        XCTAssertTrue(lifetimeOnly.temporaryClosures, "the one-time purchase alone includes the day-off rule")
        XCTAssertTrue(lifetimeOnly.removeBanner)
        XCTAssertTrue(lifetimeOnly.dailyAI)
        XCTAssertEqual(lifetimeOnly.preferredPlan, .lifetime)
        XCTAssertFalse(lifetimeOnly.canPurchase(.monthly))
        let lifetimePurchase = try XCTUnwrap(expired.first { $0.productID == lifetime.id })
        try session.refundTransaction(identifier: UInt(lifetimePurchase.id))
        let refunded = try await waitForEntitlements("lifetime refund") {
            !$0.contains { $0.productID == lifetime.id }
        }
        XCTAssertFalse(refunded.contains { $0.productID == lifetime.id })
        let free = try await waitForMembership("lifetime refund removing paid rights", products: productsByPlan) {
            !$0.lifetimeActive && !$0.subscriptionActive
        }
        XCTAssertFalse(free.calendar)
        XCTAssertFalse(free.temporaryClosures)
        XCTAssertFalse(free.removeBanner)
        XCTAssertFalse(free.dailyAI)
        XCTAssertTrue(free.canPurchase(.monthly))
    }

    func testLegacyPriceProbeReadsLocalStoreKitWithoutPurchasing() async throws {
        _ = try await session()
        let ids = Set(MembershipPlan.offeredPlans.map(\.rawValue))
        let products = try await Product.products(for: ids)
        let quotes = try await MembershipLegacyPriceProbe().load(productIDs: ids)
        XCTAssertEqual(Set(quotes.map(\.productID)), ids)
        for product in products {
            let quote = try XCTUnwrap(quotes.first { $0.productID == product.id })
            XCTAssertEqual(quote.currencyCode, product.priceFormatStyle.currencyCode)
            XCTAssertEqual(quote.displayPrice, product.displayPrice)
        }
        let current = await entitlements()
        XCTAssertTrue(current.isEmpty, "A price inspection must never purchase or grant access")
    }

    func testOverlappingPriceRefreshesLoadLocalStoreKitWithoutChangingMembership() async throws {
        let session = try await session()
        defer { session.clearTransactions() }
        let manager = MembershipManager()
        let originalSnapshot = manager.snapshot
        async let first: Void = manager.refreshPrices()
        async let second: Void = manager.refreshPrices()
        _ = await (first, second)
        XCTAssertEqual(Set(manager.products.keys), Set(MembershipPlan.offeredPlans))
        XCTAssertEqual(manager.products[.monthly]?.price, 1)
        XCTAssertEqual(manager.products[.lifetime]?.price, 15)
        XCTAssertNil(manager.productMessage)
        XCTAssertFalse(manager.isLoadingProducts)
        XCTAssertFalse(manager.isBusy)
        XCTAssertNil(manager.manualOperationFailure)
        XCTAssertEqual(manager.snapshot, originalSnapshot)
        // A finished shared load must not prevent a subsequent foreground reload.
        await manager.refreshPrices()
        XCTAssertEqual(Set(manager.products.keys), Set(MembershipPlan.offeredPlans))
        XCTAssertFalse(manager.isLoadingProducts)
        XCTAssertEqual(manager.snapshot, originalSnapshot)
    }

    func testLifetimeRefundFallsBackToActiveSubscriptionWithoutCancellingRenewal() async throws {
        let session = try await session()
        defer { session.clearTransactions() }
        let loaded = try await Product.products(for: MembershipPlan.offeredPlans.map(\.rawValue))
        let products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product -> (MembershipPlan, Product)? in
            guard let plan = MembershipPlan(rawValue: product.id) else { return nil }
            return (plan, product)
        })
        _ = try await session.buyProduct(identifier: MembershipPlan.monthly.rawValue)
        let purchase = try await session.buyProduct(identifier: MembershipPlan.lifetime.rawValue)
        _ = try await waitForMembership("both purchases active", products: products) {
            $0.preferredPlan == .lifetime && $0.subscriptionAutoRenews == true
        }
        try session.refundTransaction(identifier: UInt(purchase.id))
        let fallback = try await waitForMembership("lifetime refund retaining monthly rights", products: products) {
            !$0.lifetimeActive && $0.preferredPlan == .monthly && $0.subscriptionAutoRenews == true
        }
        XCTAssertTrue(fallback.calendar)
        XCTAssertTrue(fallback.temporaryClosures)
        XCTAssertTrue(fallback.removeBanner)
        XCTAssertTrue(fallback.dailyAI)
        XCTAssertTrue(fallback.canPurchase(.lifetime))
        XCTAssertFalse(fallback.canPurchase(.monthly))
    }

    func testAskToBuyDoesNotUnlockBeforeApproval() async throws {
        let session = try await session()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let products = try await Product.products(for: [MembershipPlan.lifetime.rawValue])
        let product = try XCTUnwrap(products.first)
        guard case .pending = try await product.purchase() else { return XCTFail("Expected pending purchase") }
        let pending = await entitlements()
        XCTAssertTrue(pending.isEmpty)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        let approved = try await waitForEntitlements("Ask to Buy approval") {
            $0.contains { $0.productID == product.id }
        }
        XCTAssertTrue(approved.contains { $0.productID == product.id })
    }
}
