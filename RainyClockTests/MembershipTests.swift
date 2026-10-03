import XCTest
import CryptoKit
import DeviceCheck
import StoreKit
@testable import RainyClock

@MainActor
final class MembershipProductCatalogTests: XCTestCase {
    private let us = MembershipCatalogStorefront(id: "143441", countryCode: "USA", currencyCode: "USD")
    private let tw = MembershipCatalogStorefront(id: "143470", countryCode: "TWN", currencyCode: "TWD")

    func testStableStorefrontKeepsAppleSuppliedPrice() async throws {
        var fetches = 0
        let catalog = try await MembershipProductCatalog.load(storefront: { self.tw }, products: {
            fetches += 1
            return [(displayPrice: "NT$10.00", currency: "TWD")]
        }, currency: { $0.currency })
        XCTAssertEqual(catalog.storefront, tw)
        XCTAssertEqual(catalog.products.first?.displayPrice, "NT$10.00")
        XCTAssertFalse(catalog.currencyMismatch)
        XCTAssertEqual(fetches, 1)
    }

    func testStorefrontSwitchDiscardsUSCatalogAndFetchesTaiwanAgain() async throws {
        var reads = [us, tw, tw, tw]
        var fetches = 0
        let catalog = try await MembershipProductCatalog.load(storefront: { reads.removeFirst() }, products: {
            fetches += 1
            return [fetches == 1 ? "USD" : "TWD"]
        }, currency: { $0 })
        XCTAssertEqual(catalog.storefront, tw)
        XCTAssertEqual(catalog.products, ["TWD"])
        XCTAssertEqual(fetches, 2)
    }

    func testCurrencyMismatchRetriesEvenWhenStorefrontDidNotChange() async throws {
        var fetches = 0
        let catalog = try await MembershipProductCatalog.load(storefront: { self.tw }, products: {
            fetches += 1
            return [fetches == 1 ? "USD" : "TWD"]
        }, currency: { $0 })
        XCTAssertEqual(catalog.products, ["TWD"])
        XCTAssertFalse(catalog.currencyMismatch)
        XCTAssertEqual(fetches, 2)
    }

    func testMixedProductCurrenciesAreNeverPublished() async {
        var fetches = 0
        do {
            _ = try await MembershipProductCatalog.load(storefront: { self.tw }, products: {
                fetches += 1
                return ["TWD", "USD"]
            }, currency: { $0 })
            XCTFail("Conflicting product currencies must not be published")
        } catch { XCTAssertEqual(error as? MembershipError, .productUnavailable) }
        XCTAssertEqual(fetches, 2)
    }

    /// TestFlight on iOS 27.0: Storefront reports Taiwan, products still come back
    /// in USD, and Apple's payment sheet charges NT$. Hiding them blocked purchases.
    func testPersistentSingleCurrencyMismatchPublishesAppleProductsAfterOneRetry() async throws {
        var fetches = 0
        let catalog = try await MembershipProductCatalog.load(storefront: { self.tw }, products: {
            fetches += 1
            return ["USD", "USD"]
        }, currency: { $0 })
        XCTAssertEqual(catalog.storefront, tw)
        XCTAssertEqual(catalog.products, ["USD", "USD"])
        XCTAssertTrue(catalog.currencyMismatch)
        XCTAssertEqual(fetches, 2)
    }

    func testStaleCatalogAfterStorefrontSwitchIsMarkedForTheNewStorefront() async throws {
        var reads = [us, tw, tw, tw]
        let catalog = try await MembershipProductCatalog.load(storefront: { reads.removeFirst() },
            products: { ["USD"] }, currency: { $0 })
        XCTAssertEqual(catalog.storefront, tw)
        XCTAssertTrue(catalog.currencyMismatch)
    }

    func testMismatchFromEarlierAttemptIsNotPublishedAfterStorefrontChanges() async {
        var reads = [tw, tw, tw, us]
        var fetches = 0
        do {
            _ = try await MembershipProductCatalog.load(storefront: { reads.removeFirst() }, products: {
                fetches += 1
                return ["USD"]
            }, currency: { $0 })
            XCTFail("Only the last attempt's stable storefront may be published")
        } catch { XCTAssertEqual(error as? MembershipError, .productUnavailable) }
        XCTAssertEqual(fetches, 2)
    }

    func testListedPricesCoverOnlyTheStorefrontsWherePlansAreSold() {
        XCTAssertEqual(MembershipListedPrice.text(for: .monthly, storefrontCountryCode: "TWN"), "NT$10")
        // The 2026-09-29 decision, applied on App Store Connect from 2026-10-03.
        XCTAssertEqual(MembershipListedPrice.text(for: .lifetime, storefrontCountryCode: "TWN"), "NT$150")
        XCTAssertEqual(MembershipListedPrice.text(for: .monthly, storefrontCountryCode: "USA"), "$1.00")
        XCTAssertEqual(MembershipListedPrice.text(for: .lifetime, storefrontCountryCode: "USA"), "$15.00")
        XCTAssertNil(MembershipListedPrice.text(for: .yearly, storefrontCountryCode: "TWN"))
        XCTAssertNil(MembershipListedPrice.text(for: .monthly, storefrontCountryCode: "JPN"))
    }

    func testRepeatedStorefrontChangesStopAfterOneRetry() async {
        var reads = [us, tw, tw, us]
        var fetches = 0
        do {
            _ = try await MembershipProductCatalog.load(storefront: { reads.removeFirst() }, products: {
                fetches += 1
                return ["USD"]
            }, currency: { $0 })
            XCTFail("An unstable storefront must not publish a catalog")
        } catch { XCTAssertEqual(error as? MembershipError, .productUnavailable) }
        XCTAssertEqual(fetches, 2)
    }

    func testMissingStorefrontDoesNotCountAsStable() async {
        do {
            _ = try await MembershipProductCatalog.load(storefront: { nil }, products: { ["USD"] }, currency: { $0 })
            XCTFail("Two missing storefronts do not verify the catalog")
        } catch { XCTAssertEqual(error as? MembershipError, .productUnavailable) }
    }

    func testChangedStorefrontIDIsDetectedEvenWithSameCountryAndCurrency() async throws {
        let replacement = MembershipCatalogStorefront(id: "different-store", countryCode: "USA", currencyCode: "USD")
        var reads = [us, replacement, replacement, replacement]
        var fetches = 0
        let catalog = try await MembershipProductCatalog.load(storefront: { reads.removeFirst() }, products: {
            fetches += 1
            return ["USD"]
        }, currency: { $0 })
        XCTAssertEqual(catalog.storefront.id, replacement.id)
        XCTAssertEqual(fetches, 2)
    }

    func testUnknownCurrencyDoesNotInventOneFromCountryOrLanguage() async throws {
        let store = MembershipCatalogStorefront(id: us.id, countryCode: us.countryCode, currencyCode: nil)
        let catalog = try await MembershipProductCatalog.load(storefront: { store }, products: { ["USD"] }, currency: { $0 })
        XCTAssertEqual(catalog.products, ["USD"])
        XCTAssertNil(catalog.storefront.currencyCode)
        XCTAssertFalse(catalog.currencyMismatch)
    }

    func testFetchErrorIsPropagatedWithoutRepeatedNetworkRequests() async {
        var fetches = 0
        do {
            _ = try await MembershipProductCatalog.load(storefront: { self.tw }, products: { () -> [String] in
                fetches += 1
                throw URLError(.notConnectedToInternet)
            }, currency: { $0 })
            XCTFail("Network failure should not produce prices")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(fetches, 1)
    }

    func testCancelledLoadCannotPublishItsResult() async {
        let task = Task { @MainActor in
            try await MembershipProductCatalog.load(storefront: { self.tw }, products: {
                withUnsafeCurrentTask { $0?.cancel() }
                return ["TWD"]
            }, currency: { $0 })
        }
        do {
            _ = try await task.value
            XCTFail("Superseded requests must not publish products")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class MembershipDiagnosticTests: XCTestCase {
    func testNativeDiagnosticsExcludeDescriptionsUserInfoAndUntrustedDomains() {
        let sensitive = "account@example.com eyJ.private-token https://example.com/?token=private-id"
        let error = NSError(domain: sensitive, code: 42, userInfo: [
            NSLocalizedDescriptionKey: sensitive, NSLocalizedFailureReasonErrorKey: sensitive,
            NSURLErrorFailingURLStringErrorKey: sensitive,
            NSUnderlyingErrorKey: NSError(domain: sensitive, code: 99)
        ])
        let diagnostic = MembershipDiagnostic(stage: .appleRefresh, error: error)
        let summary = diagnostic.summary(storefront: sensitive, currencies: [sensitive])
        XCTAssertEqual(summary, "apple-refresh · OtherError/42 · store=unknown · currency=unknown")
        for forbidden in ["account", "example.com", "eyJ", "private", "token", "https"] {
            XCTAssertFalse(summary.contains(forbidden))
        }
    }

    func testKnownSystemDomainAndCodeAreRetainedWithoutNativeMessage() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "secret-token-and-apple-account"])
        let diagnostic = MembershipDiagnostic(stage: .challengeNetwork, error: error)
        XCTAssertEqual(diagnostic.domain, NSURLErrorDomain)
        XCTAssertEqual(diagnostic.code, -1001)
        XCTAssertEqual(diagnostic.summary(storefront: "TWN", currencies: ["USD", "USD", "TWD"]),
            "challenge-network · NSURLErrorDomain/-1001 · store=TWN · currency=TWD,USD")
    }

    func testServerErrorPayloadCannotBecomeDiagnosticText() {
        let error = MembershipError.server("https://server/?token=secret JWS.apple-account", 401)
        let diagnostic = MembershipDiagnostic(stage: .session, error: error)
        XCTAssertNil(diagnostic.serverCode)
        XCTAssertEqual(diagnostic.summary(storefront: nil, currencies: []),
            "session · MembershipHTTP/401 · store=unknown · currency=unknown")
    }

    /// 2026-10-03: a phone's bootstrap failed on every launch with `session · MembershipHTTP/401`
    /// and nothing said which of the server's dozen 401 codes it was. A code that looks like
    /// one of the server's identifiers is shown; anything else is dropped.
    func testServerErrorCodeAppearsInDiagnosticOnlyWhenItLooksLikeAnIdentifier() {
        let known = MembershipDiagnostic(stage: .session, error: MembershipError.server("invalid_assertion", 401))
        XCTAssertEqual(known.serverCode, "invalid_assertion")
        XCTAssertEqual(known.summary(storefront: "TWN", currencies: ["TWD"]),
            "session · MembershipHTTP/401 · invalid_assertion · store=TWN · currency=TWD")
        XCTAssertEqual(MembershipDiagnostic(stage: .refresh, error: MembershipError.server("quota_exhausted_v2", 402)).serverCode,
                       "quota_exhausted_v2")
        // Hex digests and bare numbers are the server's identifiers (device key hashes, member
        // ids, reward ids, Apple transaction ids), never its codes: every code has a letter past f.
        for rejected in ["", "Invalid_Assertion", "invalid-assertion", "invalid assertion", "code.with.dots",
                         "a@b", "jws=eyJhbGciOi", String(repeating: "a", count: 65), "token:secret", "錯誤",
                         String(repeating: "0123456789abcdef", count: 4), "704477283", "deadbeef_0", "1_2_3"] {
            let diagnostic = MembershipDiagnostic(stage: .session, error: MembershipError.server(rejected, 401))
            XCTAssertNil(diagnostic.serverCode, rejected)
            XCTAssertEqual(diagnostic.summary(storefront: nil, currencies: []),
                "session · MembershipHTTP/401 · store=unknown · currency=unknown", rejected)
        }
        XCTAssertNil(MembershipDiagnostic(stage: .products, error: MembershipError.unavailable).serverCode)
        XCTAssertNil(MembershipDiagnostic(stage: .challengeNetwork, error: URLError(.timedOut)).serverCode)
    }

    func testStorefrontAndCurrencyDiagnosticsRejectUnexpectedValues() {
        let diagnostic = MembershipDiagnostic(stage: .products, error: MembershipError.unavailable)
        for invalid in ["", "US", "twn", "TWN\n", "ＴＷＮ", "TWN-account", "abc@example.com"] {
            XCTAssertEqual(diagnostic.summary(storefront: invalid, currencies: [invalid]),
                "products · Membership/2 · store=unknown · currency=unknown")
        }
    }

    func testInnermostStageAndOriginalServerErrorSurviveDiagnosticTransport() {
        let original = MembershipError.server("generation_failed", 503)
        let inner = MembershipDiagnosticFailure.wrapping(original, at: .requestNetwork)
        let outer = MembershipDiagnosticFailure.wrapping(inner, at: .refresh)
        XCTAssertEqual(outer.diagnostic.stage, .requestNetwork)
        XCTAssertEqual(MembershipDiagnosticFailure.original(outer) as? MembershipError, original)
        XCTAssertEqual(MembershipDiagnosticFailure.original(original) as? MembershipError, original)
    }

    func testDiagnosticTransportDoesNotBroadenAppAttestKeyRotation() {
        let invalidKey = NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "private-key"])
        let wrapped = MembershipDiagnosticFailure.wrapping(invalidKey, at: .appAttestAssertion)
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(wrapped))
        XCTAssertEqual(wrapped.diagnostic.domain, DCErrorDomain)
        for error: any Error in [URLError(.timedOut), MembershipError.unverified,
                                 MembershipError.server("app_transaction_refresh_required", 401)] {
            XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(
                MembershipDiagnosticFailure.wrapping(error, at: .session)))
        }
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(MembershipDiagnosticFailure.wrapping(
            MembershipError.server("key_not_registered", 401), at: .session)))
    }

    /// Keychain items survive deleting the app; the Secure Enclave key does not, and
    /// Apple then reports the stored key ID as invalidInput (seen on 1.7.0 (35), iOS 27).
    func testKeyFromAnEarlierInstallIsRotated() {
        for code in [DCError.Code.invalidInput, .invalidKey] {
            for stage in [MembershipDiagnosticStage.appAttestAssertion, .appAttestRegistration] {
                let wrapped = MembershipDiagnosticFailure.wrapping(
                    NSError(domain: DCErrorDomain, code: code.rawValue), at: stage)
                XCTAssertTrue(MembershipDeviceProof.isUnusableLocalKey(wrapped))
                XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(wrapped))
            }
        }
    }

    func testUnknownSystemFailureRotatesOnlyAStoredKeysAssertion() {
        let failure = NSError(domain: DCErrorDomain, code: DCError.Code.unknownSystemFailure.rawValue)
        let assertion = MembershipDiagnosticFailure.wrapping(failure, at: .appAttestAssertion)
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(assertion))
        XCTAssertFalse(MembershipDeviceProof.isUnusableLocalKey(assertion))
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(
            MembershipDiagnosticFailure.wrapping(failure, at: .appAttestRegistration)))
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(failure))
    }

    func testAppAttestServiceFailuresKeepTheKey() {
        for code in [DCError.Code.serverUnavailable, .featureUnsupported] {
            for stage in [MembershipDiagnosticStage.appAttestAssertion, .appAttestRegistration, .appAttestKey] {
                let wrapped = MembershipDiagnosticFailure.wrapping(
                    NSError(domain: DCErrorDomain, code: code.rawValue), at: stage)
                XCTAssertFalse(MembershipDeviceProof.isUnusableLocalKey(wrapped))
                XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(wrapped))
            }
        }
        XCTAssertFalse(MembershipDeviceProof.isUnusableLocalKey(MembershipError.server("key_not_registered", 401)))
    }
}

@MainActor
final class MembershipIdentitySynchronizationTests: XCTestCase {
    @MainActor private final class Flow {
        var calls: [String] = []
        var sharedProof: String? = "verified-shared"
        var freshProof: String? = "verified-fresh"
        var sharedError: (any Error)?
        var refreshError: (any Error)?
        var reuseError: (any Error)?
        var bootstrapErrors: [any Error] = []
        var deleted = false
        var reusable = true

        func run(interactive: Bool = true, restore: Bool = false) async throws {
            try await MembershipIdentitySynchronization.run(
                allowInteractiveRefresh: interactive, restoresDeletedMembership: restore,
                shared: { self.calls.append("shared"); if let error = self.sharedError { throw error }; return self.sharedProof },
                refresh: { self.calls.append("refresh"); if let error = self.refreshError { throw error }; return self.freshProof },
                isDeleted: { self.deleted }, canReuseSession: { self.reusable },
                reuseSession: { self.calls.append("server-sync"); if let error = self.reuseError { throw error } },
                clearSession: { self.calls.append("clear-session"); self.reusable = false },
                bootstrap: { proof in
                    self.calls.append("bootstrap:" + proof)
                    if !self.bootstrapErrors.isEmpty { throw self.bootstrapErrors.removeFirst() }
                })
        }
    }

    func testVerifiedBoundSessionUsesServerWithoutInteractiveAppleRefresh() async throws {
        let flow = Flow()
        try await flow.run()
        XCTAssertEqual(flow.calls, ["shared", "server-sync"])
    }

    func testNineResultPollsEachIssueOnlyTheirOriginalAuthenticatedRequest() async throws {
        var calls: [String] = []
        for _ in 0..<9 {
            try await MembershipIdentitySynchronization.run(
                allowInteractiveRefresh: true, restoresDeletedMembership: false,
                shared: { calls.append("shared"); return "verified" },
                refresh: { calls.append("refresh"); return "fresh" },
                isDeleted: { false }, canReuseSession: { true },
                reuseSession: { calls.append("original-result-request") },
                clearSession: { calls.append("clear-session") },
                bootstrap: { _ in calls.append("bootstrap") })
        }
        XCTAssertEqual(calls, Array(repeating: ["shared", "original-result-request"], count: 9).flatMap { $0 })
    }

    func testInvalidSessionRetriesOriginalRequestOnceWithoutChangingBodyOrRequestID() async throws {
        let body = Data(#"{"requestId":"same-generation","input":{"text":"test"}}"#.utf8)
        var bodies: [Data] = []
        var bootstraps = 0
        var cleared = 0
        var refreshes = 0
        try await MembershipIdentitySynchronization.run(
            allowInteractiveRefresh: true, restoresDeletedMembership: false,
            shared: { "verified" }, refresh: { refreshes += 1; return "fresh" },
            isDeleted: { false }, canReuseSession: { true },
            reuseSession: {
                bodies.append(body)
                throw MembershipError.server("invalid_session", 401)
            },
            clearSession: { cleared += 1 },
            bootstrap: { _ in bootstraps += 1; bodies.append(body) })
        XCTAssertEqual(bodies, [body, body])
        XCTAssertEqual(bootstraps, 1)
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(refreshes, 0)
    }

    /// 2026-10-03: inside a session's 24 hours the rejected key is first seen by the status
    /// call, not by a bootstrap. An explicit sync then clears the session and bootstraps
    /// once, where the key is rotated; the server still attests the new key from scratch.
    func testRejectedAssertionOnAReusedSessionClearsItAndBootstrapsOnce() async throws {
        var bootstraps = 0
        var cleared = 0
        var refreshes = 0
        try await MembershipIdentitySynchronization.run(
            allowInteractiveRefresh: true, restoresDeletedMembership: false,
            shared: { "verified" }, refresh: { refreshes += 1; return "fresh" },
            isDeleted: { false }, canReuseSession: { true },
            reuseSession: { throw MembershipDiagnosticFailure.wrapping(MembershipError.server("invalid_assertion", 401), at: .request) },
            clearSession: { cleared += 1 },
            bootstrap: { _ in bootstraps += 1 })
        XCTAssertEqual(bootstraps, 1)
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(refreshes, 0)
    }

    func testOriginalRequestFailureAfterRebootstrapCannotRetryAgain() async {
        var requests = 0
        var bootstraps = 0
        do {
            try await MembershipIdentitySynchronization.run(
                allowInteractiveRefresh: true, restoresDeletedMembership: false,
                shared: { "verified" }, refresh: { "fresh" },
                isDeleted: { false }, canReuseSession: { true },
                reuseSession: { requests += 1; throw MembershipError.server("invalid_session", 401) },
                clearSession: {},
                bootstrap: { _ in
                    bootstraps += 1; requests += 1
                    throw MembershipError.server("invalid_session", 401)
                })
            XCTFail("Must stop after one rebootstrap")
        } catch { }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(bootstraps, 1)
    }

    func testMissingOrExpiredSessionBootstrapsSharedProofWithoutPrompt() async throws {
        let flow = Flow(); flow.reusable = false
        try await flow.run()
        XCTAssertEqual(flow.calls, ["shared", "bootstrap:verified-shared"])
    }

    func testOnlyStaleBootstrapProofMayRefreshAndRetryOnce() async throws {
        let flow = Flow(); flow.reusable = false
        flow.bootstrapErrors = [MembershipDiagnosticFailure.wrapping(
            MembershipError.server("app_transaction_refresh_required", 401), at: .session)]
        try await flow.run()
        XCTAssertEqual(flow.calls, ["shared", "bootstrap:verified-shared", "refresh", "bootstrap:verified-fresh"])
    }

    func testRepeatedStaleProofCannotLoopAuthentication() async {
        let flow = Flow(); flow.reusable = false
        flow.bootstrapErrors = Array(repeating: MembershipError.server("app_transaction_refresh_required", 401), count: 2)
        do { try await flow.run(); XCTFail("Second stale proof must fail") } catch { }
        XCTAssertEqual(flow.calls.filter { $0 == "refresh" }.count, 1)
        XCTAssertEqual(flow.calls.filter { $0.hasPrefix("bootstrap:") }.count, 2)
    }

    func testServerInvalidSessionClearsOnlySessionAndBootstrapsOnce() async throws {
        let flow = Flow()
        flow.reuseError = MembershipDiagnosticFailure.wrapping(MembershipError.server("invalid_session", 401), at: .challenge)
        try await flow.run()
        XCTAssertEqual(flow.calls, ["shared", "server-sync", "clear-session", "bootstrap:verified-shared"])
    }

    func testSessionBoundToAKeyFromAnEarlierInstallBootstrapsOnce() async throws {
        for code in [DCError.Code.invalidInput, .invalidKey] {
            let flow = Flow()
            flow.reuseError = MembershipDiagnosticFailure.wrapping(
                NSError(domain: DCErrorDomain, code: code.rawValue), at: .appAttestAssertion)
            try await flow.run()
            XCTAssertEqual(flow.calls, ["shared", "server-sync", "clear-session", "bootstrap:verified-shared"])
        }
    }

    func testNonInteractiveUnusableKeyRecoveryNeverOpensAppleSignIn() async {
        let flow = Flow()
        flow.reuseError = MembershipDiagnosticFailure.wrapping(
            NSError(domain: DCErrorDomain, code: DCError.Code.invalidInput.rawValue), at: .appAttestAssertion)
        flow.bootstrapErrors = [MembershipError.server("app_transaction_refresh_required", 401)]
        do { try await flow.run(interactive: false); XCTFail("A stale proof needs an explicit refresh") } catch { }
        XCTAssertFalse(flow.calls.contains("refresh"))
        XCTAssertEqual(flow.calls.filter { $0.hasPrefix("bootstrap:") }.count, 1)
    }

    func testUnusableKeyAgainAfterRebootstrapCannotLoop() async {
        let flow = Flow()
        let unusable = MembershipDiagnosticFailure.wrapping(
            NSError(domain: DCErrorDomain, code: DCError.Code.invalidInput.rawValue), at: .appAttestAssertion)
        flow.reuseError = unusable
        flow.bootstrapErrors = [unusable]
        do { try await flow.run(); XCTFail("Must stop after one rebootstrap") } catch { }
        XCTAssertEqual(flow.calls.filter { $0.hasPrefix("bootstrap:") }.count, 1)
        XCTAssertFalse(flow.calls.contains("refresh"))
    }

    func testOtherServerAndNetworkFailuresNeverFallbackToBootstrap() async {
        let appAttest = { (code: DCError.Code) -> any Error in
            MembershipDiagnosticFailure.wrapping(NSError(domain: DCErrorDomain, code: code.rawValue), at: .appAttestAssertion)
        }
        let errors: [any Error] = [MembershipError.server("invalid_session", 403),
            MembershipError.server("member_deleted", 401), MembershipError.server("assertion_replayed", 401),
            MembershipError.server("key_not_registered", 401), MembershipError.server("unavailable", 503),
            URLError(.timedOut), MembershipError.sessionExpired,
            appAttest(.serverUnavailable), appAttest(.unknownSystemFailure), appAttest(.featureUnsupported)]
        for error in errors {
            let flow = Flow(); flow.reuseError = error
            do { try await flow.run(); XCTFail("Must fail closed") } catch { }
            XCTAssertEqual(flow.calls, ["shared", "server-sync"])
        }
    }

    func testReplayAndUnverifiedBootstrapFailuresCannotRefreshOrReuseOldSession() async {
        for error in [MembershipError.server("apple_proof_replayed_on_other_device", 401),
                      .server("invalid_session", 401), .server("app_transaction_refresh_required", 503), .unverified] {
            let flow = Flow(); flow.reusable = false; flow.bootstrapErrors = [error]
            do { try await flow.run(); XCTFail("Must fail closed") } catch { }
            XCTAssertEqual(flow.calls, ["shared", "bootstrap:verified-shared"])
        }
    }

    func testSharedReadOrVerificationFailureAllowsOneExplicitFreshProof() async throws {
        for stage in [MembershipDiagnosticStage.appleShared, .appleProof] {
            let flow = Flow()
            flow.sharedError = MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: stage)
            try await flow.run()
            XCTAssertEqual(flow.calls, ["shared", "refresh", "server-sync"])
        }
    }

    func testFailedFreshProofNeverFallsBackToPreviouslyValidSession() async {
        let flow = Flow()
        flow.sharedError = MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleProof)
        flow.refreshError = MembershipDiagnosticFailure.wrapping(StoreKitError.userCancelled, at: .appleRefresh)
        do { try await flow.run(); XCTFail("Cancelled Apple verification cannot use cache") }
        catch {
            XCTAssertEqual((error as? MembershipDiagnosticFailure)?.diagnostic.stage, .appleRefresh)
        }
        XCTAssertEqual(flow.calls, ["shared", "refresh"])
    }

    func testRoutingAndIdentityFailuresNeverTriggerInteractiveRecovery() async {
        for stage in [MembershipDiagnosticStage.appleRouting, .keychain, .session] {
            let flow = Flow()
            flow.sharedError = MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: stage)
            do { try await flow.run(); XCTFail("Must fail closed") } catch { }
            XCTAssertEqual(flow.calls, ["shared"])
        }
    }

    func testSupersededSharedOrFreshGenerationAbortsBeforeServerWork() async {
        let shared = Flow(); shared.sharedProof = nil
        do { try await shared.run(); XCTFail("Superseded identity must abort") } catch { }
        XCTAssertEqual(shared.calls, ["shared"])
        let refreshed = Flow()
        refreshed.sharedError = MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleShared)
        refreshed.freshProof = nil
        do { try await refreshed.run(); XCTFail("Superseded refresh must abort") } catch { }
        XCTAssertEqual(refreshed.calls, ["shared", "refresh"])
    }

    func testDeletedMembershipNeedsExplicitRecreationAndFreshProof() async throws {
        let implicit = Flow(); implicit.deleted = true
        do { try await implicit.run(); XCTFail("AI/reward actions cannot recreate a deleted membership") } catch { }
        XCTAssertEqual(implicit.calls, ["shared"])
        let explicit = Flow(); explicit.deleted = true
        try await explicit.run(restore: true)
        XCTAssertEqual(explicit.calls, ["shared", "refresh", "bootstrap:verified-fresh"])
    }

    func testBackgroundWorkNeverOpensAppleAuthentication() async {
        let deleted = Flow(); deleted.deleted = true
        do { try await deleted.run(interactive: false, restore: true); XCTFail("Cannot recreate in background") } catch { }
        XCTAssertEqual(deleted.calls, ["shared"])
        let stale = Flow(); stale.reusable = false
        stale.bootstrapErrors = [MembershipError.server("app_transaction_refresh_required", 401)]
        do { try await stale.run(interactive: false); XCTFail("Must await explicit action") } catch { }
        XCTAssertEqual(stale.calls, ["shared", "bootstrap:verified-shared"])
        let unavailable = Flow()
        unavailable.sharedError = MembershipDiagnosticFailure.wrapping(MembershipError.unverified, at: .appleShared)
        do { try await unavailable.run(interactive: false); XCTFail("Must await explicit action") } catch { }
        XCTAssertEqual(unavailable.calls, ["shared"])
    }

    func testAccountEnvironmentAndMemberBindingsAllRequiredWithoutNewSessionFields() {
        let state = MembershipSnapshot(memberId: "member-a", environment: "Sandbox", entitlements: .free,
            quota: .init(serviceDate: nil, nextResetAt: 0, timeZone: "Asia/Taipei", dailyRemaining: 0,
                         freeRemaining: 1, rewardCredits: 0, reserved: 0, migrationPending: false),
            policy: .init(version: "test", approved: true))
        let session = MembershipSession(token: "test-token", expiresAt: Date().timeIntervalSince1970 * 1_000 + 120_000,
                                        memberId: state.memberId, state: state)
        func accepts(account: String? = "apple-a", stored: String? = "apple-a", environment: MembershipAppleEnvironment = .sandbox,
                     snapshot: MembershipSnapshot? = nil, suppliedSession: MembershipSession? = nil, deleted: Bool = false) -> Bool {
            MembershipSessionBinding.canReuse(currentAccount: account, persistedAccount: stored, environment: environment,
                snapshot: snapshot ?? state, session: suppliedSession ?? session, deleted: deleted)
        }
        XCTAssertTrue(accepts()) // Build-31 schema has all necessary bindings already.
        XCTAssertFalse(accepts(account: "apple-b"))
        XCTAssertFalse(accepts(stored: nil))
        XCTAssertFalse(accepts(environment: .production))
        XCTAssertFalse(accepts(deleted: true))
        var changed = state; changed.memberId = "member-b"
        XCTAssertFalse(accepts(snapshot: changed))
        var expired = session; expired.expiresAt = 0
        XCTAssertFalse(accepts(suppliedSession: expired))
        var wrong = session; wrong.state.environment = "Production"
        XCTAssertFalse(accepts(suppliedSession: wrong))
        XCTAssertFalse(MembershipSessionBinding.canReuse(currentAccount: "apple-a", persistedAccount: "apple-a",
            environment: .sandbox, snapshot: nil, session: session, deleted: false))
        XCTAssertEqual(state.memberId, "member-a") // Refusing reuse never clears last verified rights.
    }

    func testLateBootstrapCannotPersistAfterAccountEnvironmentOrEpochChange() throws {
        let epoch = UUID()
        let route = try MembershipConfiguration.routing(verifiedEnvironment: .sandbox,
            baseURL: URL(string: "https://membership.example.com")!, legacySandbox: false)
        let production = try MembershipConfiguration.routing(verifiedEnvironment: .production,
            baseURL: route.baseURL, legacySandbox: false)
        func accepts(generation: UUID = epoch, account: String? = "apple-a", routing: MembershipRouting? = nil) -> Bool {
            MembershipSessionBinding.canPersist(capturedGeneration: epoch, currentGeneration: generation,
                capturedAccount: "apple-a", currentAccount: account, capturedRouting: route, currentRouting: routing ?? route)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(account: "apple-b"))
        XCTAssertFalse(accepts(account: nil))
        XCTAssertFalse(accepts(routing: production))
        XCTAssertFalse(accepts(generation: UUID())) // Also rejects A → B → A late responses.
    }

    func testTimeZoneUpdatesRespectPendingServerBoundaryAndReturnToOriginalZone() {
        var quota = MembershipQuota(serviceDate: nil, nextResetAt: 0, timeZone: "Asia/Taipei", dailyRemaining: 0,
            freeRemaining: 1, rewardCredits: 0, reserved: 0, migrationPending: false)
        XCTAssertFalse(MembershipSessionBinding.needsTimeZoneUpdate(quota, currentTimeZone: "Asia/Taipei"))
        XCTAssertTrue(MembershipSessionBinding.needsTimeZoneUpdate(quota, currentTimeZone: "America/New_York"))
        quota.pendingTimeZone = "America/New_York"
        XCTAssertFalse(MembershipSessionBinding.needsTimeZoneUpdate(quota, currentTimeZone: "America/New_York"))
        XCTAssertTrue(MembershipSessionBinding.needsTimeZoneUpdate(quota, currentTimeZone: "Asia/Taipei"))
    }

    func testAppleAuthenticationCancellationIsNotDescribedAsNetworkFailure() {
        let error = MembershipDiagnosticFailure.wrapping(StoreKitError.userCancelled, at: .appleRefresh)
        let message = MembershipFailureMessage.description(for: error)
        XCTAssertTrue(message.contains("Apple"))
        XCTAssertFalse(message.contains("connect"))
        XCTAssertFalse(message.contains("連線"))
        XCTAssertEqual(error.diagnostic.stage, .appleRefresh)
        XCTAssertEqual(error.diagnostic.domain, "StoreKit.StoreKitError")
    }
}

final class MembershipConfigurationTests: XCTestCase {
    func testNormalLaunchKeepsUnconfiguredMembershipDisabled() {
        XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: "", arguments: [], environment: [:]))
        XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: nil, arguments: [],
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"]))
        XCTAssertEqual(MembershipConfiguration.keychainService(arguments: [],
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"]),
            "com.shukaihu.RainyClock.membership.v1")
    }

    func testServiceOriginRejectsAmbiguousOrUnsafeEndpoints() {
        let invalid = ["", "http://sandbox.example.com", "https://", "//sandbox.example.com",
                       "https://user@sandbox.example.com", "https://user:password@sandbox.example.com",
                       "https://sandbox.example.com/v1", "https://sandbox.example.com?key=value",
                       "https://sandbox.example.com#fragment", "https://sandbox.example.com:8080",
                       " https://sandbox.example.com", "https://sandbox.example.com\n",
                       "https://-invalid.example.com", "https://sandbox..example.com", "https://localhost"]
        for raw in invalid {
            XCTAssertNil(MembershipConfiguration.validatedServiceURL(raw), raw)
        }
    }

    func testServiceOriginNormalizesEquivalentHTTPSURLs() {
        XCTAssertEqual(MembershipConfiguration.validatedServiceURL("HTTPS://Sandbox.Example.com:443/")?.absoluteString,
                       "https://sandbox.example.com")
    }

    func testNormalDeviceAdvertisingAndXCTestGatesArePreserved() {
        XCTAssertTrue(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false, arguments: [], verifiedAppleEnvironment: .production))
        XCTAssertTrue(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false,
            arguments: ["-membership-storekit-test"], verifiedAppleEnvironment: .production))
        XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: true, arguments: []))
    }

    #if DEBUG
    func testInstalledSandboxBuildSurvivesHomeScreenRelaunch() {
        let url = MembershipConfiguration.resolvedServiceURL(bundleValue: "", arguments: [],
            environment: [:], sandboxBuild: true)
        XCTAssertEqual(url?.absoluteString,
            "https://rainyclock-membership-sandbox-510427696731.asia-east1.run.app")
        XCTAssertTrue(MembershipConfiguration.sandboxTesting(arguments: [], sandboxBuild: true))
        XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false,
            arguments: [], sandboxBuild: true))

        // Keep the existing Sandbox session/attestation key when upgrading from
        // the old launch-only test build; never mix it with the regular app.
        let installedKeychain = MembershipConfiguration.keychainService(arguments: [],
            environment: [:], sandboxBuild: true)
        let launchKeychain = MembershipConfiguration.keychainService(arguments: ["-membership-sandbox-test"],
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": url!.absoluteString], sandboxBuild: false)
        XCTAssertEqual(installedKeychain, launchKeychain)
        XCTAssertNotEqual(installedKeychain, MembershipConfiguration.keychainService(arguments: [],
            environment: [:], sandboxBuild: false))
    }

    func testInstalledSandboxBuildCannotBeRoutedToProductionByLaunchEnvironment() {
        let installed = MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: ["-membership-sandbox-test"],
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://other.example.com"], sandboxBuild: true)
        XCTAssertEqual(installed, MembershipConfiguration.resolvedServiceURL(bundleValue: nil,
            arguments: [], environment: [:], sandboxBuild: true))
    }

    func testLocalStoreKitStillCannotConnectFromInstalledSandboxBuild() {
        XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: ["-membership-storekit-test"], environment: [:], sandboxBuild: true))
        XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false,
            arguments: ["-membership-storekit-test", "-showLevelPlayTestSuite"], sandboxBuild: true))
    }

    func testSandboxLaunchBlocksDeviceAdvertisingWithoutRequiringAServiceURL() {
        XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false,
            arguments: ["-membership-sandbox-test"]))
        XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false,
            arguments: ["-membership-sandbox-test", "-showLevelPlayTestSuite"]))
    }

    func testSandboxRequiresExplicitOptInAndUsesOnlyLaunchEndpoint() {
        let environment = ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"]
        XCTAssertEqual(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: [], environment: environment)?.host, "production.example.com")
        XCTAssertEqual(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: ["-membership-sandbox-test"], environment: environment)?.host, "sandbox.example.com")
    }

    func testInvalidSandboxOverrideCannotFallBackToProduction() {
        for raw in [nil, "", "http://sandbox.example.com", "https://sandbox.example.com/path"] {
            let environment = raw.map { ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": $0] } ?? [:]
            XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
                arguments: ["-membership-sandbox-test"], environment: environment))
        }
    }

    func testLocalStoreKitCannotAccidentallyConnectToBackend() {
        XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: ["-membership-storekit-test", "-membership-sandbox-test"],
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"]))
    }

    func testSandboxKeychainIsIsolatedByCanonicalServiceOrigin() {
        let arguments = ["-membership-sandbox-test"]
        let first = MembershipConfiguration.keychainService(arguments: arguments,
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"])
        let equivalent = MembershipConfiguration.keychainService(arguments: arguments,
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "HTTPS://Sandbox.Example.com:443/"])
        let other = MembershipConfiguration.keychainService(arguments: arguments,
            environment: ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://other.example.com"])
        XCTAssertNotEqual(first, "com.shukaihu.RainyClock.membership.v1")
        XCTAssertEqual(first, equivalent)
        XCTAssertNotEqual(first, other)
    }
    #else
    func testReleaseIgnoresSandboxAndLocalStoreKitLaunchOverrides() {
        let arguments = ["-membership-sandbox-test", "-membership-storekit-test"]
        let environment = ["RAINYCLOCK_MEMBERSHIP_SANDBOX_URL": "https://sandbox.example.com"]
        XCTAssertNil(MembershipConfiguration.resolvedServiceURL(bundleValue: "", arguments: arguments,
                                                               environment: environment))
        XCTAssertEqual(MembershipConfiguration.resolvedServiceURL(bundleValue: "https://production.example.com",
            arguments: arguments, environment: environment)?.host, "production.example.com")
        XCTAssertEqual(MembershipConfiguration.keychainService(arguments: arguments, environment: environment),
                       "com.shukaihu.RainyClock.membership.v1")
        XCTAssertTrue(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false, arguments: arguments, verifiedAppleEnvironment: .production))
    }
    #endif
}

final class MembershipEnvironmentRoutingTests: XCTestCase {
    private let origin = URL(string: "https://membership.example.com")!

    func testProductionAndTestFlightNeverSharePersistentCredentials() throws {
        let production = try MembershipConfiguration.routing(verifiedEnvironment: .production, baseURL: origin, legacySandbox: false)
        let sandbox = try MembershipConfiguration.routing(verifiedEnvironment: .sandbox, baseURL: origin, legacySandbox: false)
        XCTAssertEqual(production.baseURL, sandbox.baseURL)
        XCTAssertNotEqual(production.keychainService, sandbox.keychainService)
        let otherService = try MembershipConfiguration.routing(verifiedEnvironment: .production,
            baseURL: URL(string: "https://other.example.com")!, legacySandbox: false)
        XCTAssertNotEqual(production.keychainService, otherService.keychainService)
    }

    func testLegacyDebugSandboxKeepsItsKeysButRejectsProductionProof() throws {
        let legacy = "com.shukaihu.RainyClock.membership.v1.sandbox.old.example.com"
        let routing = try MembershipConfiguration.routing(verifiedEnvironment: .sandbox, baseURL: origin,
            legacySandbox: true, legacyKeychainService: legacy)
        XCTAssertEqual(routing.keychainService, legacy)
        XCTAssertThrowsError(try MembershipConfiguration.routing(verifiedEnvironment: .production, baseURL: origin,
            legacySandbox: true, legacyKeychainService: legacy))
    }

    func testEveryAPIIncludingChallengeCarriesImmutableEnvironmentRoutingHint() throws {
        for environment in [MembershipAppleEnvironment.production, .sandbox] {
            let routing = try MembershipConfiguration.routing(verifiedEnvironment: environment, baseURL: origin, legacySandbox: false)
            for path in ["challenge", "session", "status", "purchases", "generations", "generations/result", "delete"] {
                let request = try MembershipClient.makeRequest(routing: routing, path: "/v1/membership/" + path,
                    body: Data("{}".utf8), headers: ["X-RC-Apple-Environment": "forged"])
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-RC-Apple-Environment"), environment.rawValue)
                XCTAssertEqual(request.url?.host, "membership.example.com")
            }
        }
    }

    func testUnknownAndLocalAppleEnvironmentsCannotBeNetworkRoutingHints() {
        for raw in ["Xcode", "LocalTesting", "", "sandbox", "staging"] {
            XCTAssertNil(MembershipAppleEnvironment(rawValue: raw))
        }
    }

    func testTestFlightAndUnverifiedLaunchCannotStartProductionAdvertising() {
        for environment in [MembershipAppleEnvironment.sandbox, nil] {
            XCTAssertFalse(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false, arguments: [],
                sandboxBuild: false, verifiedAppleEnvironment: environment))
        }
        XCTAssertTrue(AppEnvironment.allowsDeviceAdvertising(isRunningTests: false, arguments: [],
            sandboxBuild: false, verifiedAppleEnvironment: .production))
    }

    func testClientRejectsCrossEnvironmentBootstrapBeforeDeviceOrNetworkWork() async throws {
        let routing = try MembershipConfiguration.routing(verifiedEnvironment: .production, baseURL: origin, legacySandbox: false)
        let client = MembershipClient(routing: routing)
        do {
            _ = try await client.bootstrap(.init(environment: .sandbox, signedAppTransaction: "unused",
                appTransactionID: "unused", deviceVerificationID: "unused", signedTransactions: []))
            XCTFail("Cross-environment proof must never begin App Attest or networking")
        } catch {
            XCTAssertEqual(error as? MembershipError, .unverified)
        }
    }

    func testClientRejectsCachedSandboxSessionInProductionScope() async throws {
        let keychain = MembershipKeychain(service: "RainyClockEnvironmentTests." + UUID().uuidString)
        defer { keychain.remove("session") }
        let state = MembershipSnapshot(memberId: "test-member", environment: "Sandbox", entitlements: .free,
            quota: .init(serviceDate: nil, nextResetAt: 0, timeZone: nil, dailyRemaining: 0,
                         freeRemaining: 1, rewardCredits: 0, reserved: 0, migrationPending: false),
            policy: .init(version: "test", approved: true))
        try keychain.write(MembershipSession(token: "not-a-real-token", expiresAt: Date().timeIntervalSince1970 * 1_000 + 120_000,
                                            memberId: state.memberId, state: state), key: "session")
        let client = MembershipClient(routing: MembershipRouting(baseURL: origin, appleEnvironment: .production,
                                                                 keychainService: keychain.service))
        do {
            _ = try await client.request(path: "/v1/membership/status")
            XCTFail("A Sandbox cache must not reach Production, even in the wrong Keychain scope")
        } catch {
            XCTAssertEqual(error as? MembershipError, .sessionExpired)
        }
    }

    func testDeletionTombstoneSurvivesIdentityCacheRemovalAndIsAccountScoped() throws {
        let keychain = MembershipKeychain(service: "RainyClockDeletionTests." + UUID().uuidString)
        defer {
            keychain.remove("dataDeleted")
            keychain.remove("deletedAccountIdentity")
            keychain.remove("accountIdentity")
        }
        try keychain.write("apple-account-A", key: "deletedAccountIdentity")
        try keychain.write(true, key: "dataDeleted")
        XCTAssertTrue(keychain.membershipWasDeleted(for: "apple-account-A"))
        XCTAssertFalse(keychain.membershipWasDeleted(for: "apple-account-B"))
        keychain.remove("deletedAccountIdentity")
        // Legacy deletions had neither identity marker. They must require an
        // explicit user action before any automatic registration can resume.
        XCTAssertTrue(keychain.membershipWasDeleted(for: "apple-account-A"))
        try keychain.write(false, key: "dataDeleted")
        XCTAssertFalse(keychain.membershipWasDeleted(for: "apple-account-A"))
    }

    func testRegisteringAnotherAccountDoesNotEraseDeletionConsent() throws {
        let keychain = MembershipKeychain(service: "RainyClockDeletionSwitchTests." + UUID().uuidString)
        defer {
            try? keychain.clearMembershipDeletion(for: "account-A")
            try? keychain.clearMembershipDeletion(for: "account-B")
            keychain.remove("dataDeleted")
        }
        try keychain.markMembershipDeleted(for: "account-A")
        try keychain.clearMembershipDeletion(for: "account-B")
        XCTAssertTrue(keychain.membershipWasDeleted(for: "account-A"))
        XCTAssertFalse(keychain.membershipWasDeleted(for: "account-B"))
        try keychain.markMembershipDeleted(for: "account-B")
        try keychain.clearMembershipDeletion(for: "account-A")
        XCTAssertFalse(keychain.membershipWasDeleted(for: "account-A"))
        XCTAssertTrue(keychain.membershipWasDeleted(for: "account-B"))
    }
}

final class MembershipTests: XCTestCase {
    func testSubscriptionExpiryKeepsLifetimeBenefitsOnly() {
        let time = Date(timeIntervalSince1970: 1_000)
        let both = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: true, subscriptionExpiresAt: 1_000_000)
        XCTAssertEqual(both.valid(at: time.addingTimeInterval(-1)), both)
        let expired = both.valid(at: time)
        XCTAssertTrue(expired.removeBanner)
        XCTAssertTrue(expired.dailyAI)
        XCTAssertTrue(expired.lifetimeActive)
        XCTAssertFalse(expired.subscriptionActive)
        XCTAssertTrue(expired.calendar)
        XCTAssertEqual(expired.preferredPlan, .lifetime)
        XCTAssertFalse(expired.canPurchase(.monthly))
        XCTAssertTrue(expired.temporaryClosures, "the one-time purchase includes the day-off rule (2026-09-28)")
    }

    func testLifetimeTakesPriorityWithoutHidingOrCancellingAnExistingSubscription() {
        let both = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: true, subscriptionExpiresAt: 10_000,
            subscriptionProductId: MembershipPlan.monthly.rawValue, subscriptionAutoRenews: true)
        XCTAssertEqual(both.preferredPlan, .lifetime)
        XCTAssertEqual(both.currentSubscriptionPlan, .monthly)
        XCTAssertEqual(both.subscriptionAutoRenews, true)
        XCTAssertTrue(both.owns(.monthly))
        XCTAssertTrue(both.owns(.lifetime))
        XCTAssertFalse(both.canPurchase(.monthly))
        XCTAssertFalse(both.canPurchase(.yearly))
        XCTAssertFalse(both.canPurchase(.lifetime))
    }

    func testLifetimeOwnerCannotPurchaseASubscriptionAfterItExpires() {
        let lifetime = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: false, lifetimeActive: true)
        XCTAssertEqual(lifetime.preferredPlan, .lifetime)
        XCTAssertNil(lifetime.currentSubscriptionPlan)
        XCTAssertFalse(lifetime.canPurchase(.monthly))
        XCTAssertFalse(lifetime.canPurchase(.yearly))
        XCTAssertTrue(lifetime.valid(at: Date.distantFuture).calendar)
        XCTAssertTrue(lifetime.valid(at: Date.distantFuture).temporaryClosures)
    }

    func testSubscriberCanUpgradeToLifetimeWhileFreeCanChooseEitherOfferedPlan() {
        let subscribed = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 10_000,
            subscriptionProductId: MembershipPlan.monthly.rawValue, subscriptionAutoRenews: false)
        XCTAssertEqual(subscribed.preferredPlan, .monthly)
        XCTAssertTrue(subscribed.canPurchase(.lifetime))
        XCTAssertFalse(subscribed.canPurchase(.monthly))
        XCTAssertNil(MembershipEntitlements.free.preferredPlan)
        XCTAssertTrue(MembershipEntitlements.free.canPurchase(.lifetime))
        XCTAssertTrue(MembershipEntitlements.free.canPurchase(.monthly))
        XCTAssertFalse(MembershipEntitlements.free.canPurchase(.yearly))
    }

    func testExpiredSubscriptionDoesNotGrantLifetime() {
        let value = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 1)
        let expired = value.valid(at: Date(timeIntervalSince1970: 2))
        XCTAssertFalse(expired.removeBanner)
        XCTAssertFalse(expired.dailyAI)
        XCTAssertFalse(expired.lifetimeActive)
    }

    func testCancelledRenewalKeepsCurrentPlanUntilExpiration() {
        let entitlement = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 10_000,
            subscriptionProductId: MembershipPlan.monthly.rawValue, subscriptionAutoRenews: false)
        let active = entitlement.valid(at: Date(timeIntervalSince1970: 9))
        XCTAssertTrue(active.calendar)
        XCTAssertTrue(active.owns(.monthly))
        XCTAssertFalse(active.owns(.yearly))
        XCTAssertFalse(active.owns(.lifetime))
        XCTAssertEqual(active.subscriptionAutoRenews, false)
        let expired = entitlement.valid(at: Date(timeIntervalSince1970: 10))
        XCTAssertNil(expired.currentSubscriptionPlan)
        XCTAssertFalse(expired.owns(.monthly))
        XCTAssertFalse(expired.calendar)
    }

    func testPendingRenewalPlanDoesNotBecomeCurrentBeforeItsTransaction() {
        var entitlement = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: true, subscriptionExpiresAt: 10_000,
            subscriptionProductId: MembershipPlan.monthly.rawValue, subscriptionAutoRenews: true,
            subscriptionRenewalProductId: MembershipPlan.yearly.rawValue)
        XCTAssertEqual(entitlement.currentSubscriptionPlan, .monthly)
        XCTAssertEqual(entitlement.pendingSubscriptionPlan, .yearly)
        XCTAssertTrue(entitlement.owns(.monthly))
        XCTAssertFalse(entitlement.owns(.yearly))
        XCTAssertTrue(entitlement.owns(.lifetime))
        entitlement.subscriptionAutoRenews = false
        XCTAssertNil(entitlement.pendingSubscriptionPlan)
        entitlement.subscriptionAutoRenews = nil
        XCTAssertNil(entitlement.pendingSubscriptionPlan)
    }

    func testUnknownRenewalAndUnrecognizedProductDoNotInventPlanOrCancellation() {
        var entitlement = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 10_000)
        XCTAssertNil(entitlement.currentSubscriptionPlan)
        XCTAssertNil(entitlement.subscriptionAutoRenews)
        entitlement.subscriptionProductId = MembershipPlan.lifetime.rawValue
        XCTAssertNil(entitlement.currentSubscriptionPlan)
        entitlement.subscriptionProductId = "unknown.product"
        XCTAssertNil(entitlement.currentSubscriptionPlan)
        entitlement.subscriptionProductId = MembershipPlan.monthly.rawValue
        entitlement.subscriptionAutoRenews = true
        entitlement.subscriptionRenewalProductId = MembershipPlan.monthly.rawValue
        XCTAssertNil(entitlement.pendingSubscriptionPlan)
    }

    func testRequestProofBindsBodyPathMethodAndChallenge() {
        let challenge = MembershipChallenge(id: "id", challenge: "nonce-text", expiresAt: 1_000)
        let body = Data("{\"a\":1}".utf8)
        let original = MembershipRequestBinding.hash(purpose: "request", challenge: challenge, method: "POST", path: "/v1/membership/status", body: body)
        XCTAssertEqual(original, MembershipRequestBinding.hash(purpose: "request", challenge: challenge, method: "post", path: "/v1/membership/status", body: body))
        XCTAssertNotEqual(original, MembershipRequestBinding.hash(purpose: "request", challenge: challenge, method: "POST", path: "/v1/membership/delete", body: body))
        XCTAssertNotEqual(original, MembershipRequestBinding.hash(purpose: "request", challenge: challenge, method: "GET", path: "/v1/membership/status", body: body))
        XCTAssertNotEqual(original, MembershipRequestBinding.hash(purpose: "request", challenge: challenge, method: "POST", path: "/v1/membership/status", body: Data("{\"a\":2}".utf8)))
        XCTAssertNotEqual(original, MembershipRequestBinding.hash(purpose: "bootstrap", challenge: challenge, method: "POST", path: "/v1/membership/status", body: body))
        let next = MembershipChallenge(id: "other-id", challenge: "nonce-text", expiresAt: 1_000)
        XCTAssertNotEqual(original, MembershipRequestBinding.hash(purpose: "request", challenge: next, method: "POST", path: "/v1/membership/status", body: body))
    }

    func testWireHashUsesLiteralBase64URLChallengeAndNoTrailingNewline() {
        let challenge = MembershipChallenge(id: "fixed", challenge: "YV9iLWM", expiresAt: 0)
        let value = MembershipRequestBinding.hash(purpose: "bootstrap", challenge: challenge,
            method: "POST", path: "/v1/membership/session", body: Data())
        let expected = "RainyClockMembershipV1\nbootstrap\nfixed\nYV9iLWM\nPOST\n/v1/membership/session\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(value, Data(SHA256.hash(data: Data(expected.utf8))))
    }

    func testMemberStatusDecodesBackendMillisecondsAndLocalQuota() throws {
        let body = Data(#"{"memberId":"m-1","appAccountToken":"DA89FCC7-AE1D-42CF-A6E2-7914278FCF3E","verifiedAt":1800000000000,"entitlements":{"removeBanner":true,"calendar":true,"temporaryClosures":true,"dailyAI":true,"subscriptionActive":true,"lifetimeActive":false,"subscriptionExpiresAt":1800001000000},"quota":{"nextResetAt":1800010000000,"timeZone":"Asia/Taipei","dailyRemaining":1,"freeRemaining":0,"rewardCredits":2,"reserved":0,"migrationPending":false},"policy":{"version":"v1","approved":true}}"#.utf8)
        let value = try JSONDecoder().decode(MembershipSnapshot.self, from: body)
        XCTAssertEqual(value.memberId, "m-1")
        XCTAssertEqual(value.quota.rewardCredits, 2)
        XCTAssertEqual(value.quota.timeZone, "Asia/Taipei")
        XCTAssertEqual(value.entitlements.subscriptionExpiresAt, 1_800_001_000_000)
        XCTAssertNil(value.entitlements.subscriptionProductId)
        XCTAssertNil(value.entitlements.subscriptionAutoRenews)
        XCTAssertNil(value.entitlements.subscriptionRenewalProductId)
    }

    func testRenewalMetadataDecodesAndRoundTripsWithoutLosingFalse() throws {
        let body = Data(#"{"removeBanner":true,"calendar":true,"temporaryClosures":true,"dailyAI":true,"subscriptionActive":true,"lifetimeActive":false,"subscriptionExpiresAt":1800001000000,"subscriptionProductId":"com.shukaihu.RainyClock.plus.monthly","subscriptionAutoRenews":false,"subscriptionRenewalProductId":"com.shukaihu.RainyClock.plus.yearly"}"#.utf8)
        let value = try JSONDecoder().decode(MembershipEntitlements.self, from: body)
        XCTAssertEqual(value.currentSubscriptionPlan, .monthly)
        XCTAssertEqual(value.subscriptionAutoRenews, false)
        XCTAssertNil(value.pendingSubscriptionPlan)
        XCTAssertEqual(value.subscriptionRenewalProductId, MembershipPlan.yearly.rawValue)
        XCTAssertEqual(try JSONDecoder().decode(MembershipEntitlements.self, from: JSONEncoder().encode(value)), value)
    }

    func testSubscriptionAndLifetimeProductIDsAreSeparate() {
        XCTAssertEqual(Set(MembershipPlan.allCases.map(\.rawValue)).count, 3)
        XCTAssertTrue(MembershipPlan.monthly.isSubscription)
        XCTAssertTrue(MembershipPlan.yearly.isSubscription)
        XCTAssertFalse(MembershipPlan.lifetime.isSubscription)
    }

    func testOfferedCatalogRetainsRecognitionOfRetiredYearlyPurchases() {
        XCTAssertEqual(MembershipPlan.offeredPlans, [.monthly, .lifetime])
        XCTAssertFalse(MembershipPlan.yearly.isOffered)
        let existing = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 10_000,
            subscriptionProductId: MembershipPlan.yearly.rawValue, subscriptionAutoRenews: false)
        XCTAssertEqual(existing.currentSubscriptionPlan, .yearly)
        XCTAssertTrue(existing.owns(.yearly))
        XCTAssertTrue(existing.valid(at: Date(timeIntervalSince1970: 9)).calendar)
        XCTAssertFalse(existing.valid(at: Date(timeIntervalSince1970: 10)).calendar)
    }

    func testGenerationJournalSeparatesMembersAndRecoversSameRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MembershipGenerationJournal(directory: directory)
        let input = MembershipGenerationInput(text: "Good morning", persona: "steady", language: "en-US")
        let pending = MembershipPendingGeneration(requestId: UUID().uuidString, memberId: "member-1", input: input, createdAt: Date())
        try journal.save(pending)
        XCTAssertEqual(try journal.pending(memberId: "member-1", input: input), pending)
        XCTAssertNil(try journal.pending(memberId: "member-2", input: input))
        let changed = MembershipGenerationInput(text: "Different words", persona: "steady", language: "en-US")
        XCTAssertNil(try journal.pending(memberId: "member-1", input: changed))
        try journal.remove(pending)
        XCTAssertNil(try journal.pending(memberId: "member-1", input: input))
    }

    func testOldCompletionCannotRemoveNewGenerationRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MembershipGenerationJournal(directory: directory)
        let input = MembershipGenerationInput(text: "Good morning", persona: "steady", language: "en-US")
        let old = MembershipPendingGeneration(requestId: "old-request", memberId: "same-member", input: input, createdAt: Date())
        let new = MembershipPendingGeneration(requestId: "new-request", memberId: "same-member", input: input, createdAt: Date())
        try journal.save(old)
        try journal.save(new)
        try journal.remove(old)
        XCTAssertEqual(try journal.pending(memberId: "same-member", input: input), new)
    }

    func testCorruptJournalDoesNotSilentlyAllocateAnotherRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MembershipGenerationJournal(directory: directory)
        let input = MembershipGenerationInput(text: "Good morning", persona: "steady", language: "en-US")
        try journal.save(.init(requestId: "request-1", memberId: "m", input: input, createdAt: Date()))
        let path = try journal.url(memberId: "m", input: input)
        try Data("corrupt".utf8).write(to: path)
        XCTAssertThrowsError(try journal.pending(memberId: "m", input: input))
    }

    func testMembershipDeletionOnlyRemovesThatMembersPendingText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MembershipGenerationJournal(directory: directory)
        let input = MembershipGenerationInput(text: "Good morning", persona: "steady", language: "en-US")
        let first = MembershipPendingGeneration(requestId: "first-request", memberId: "first-member", input: input, createdAt: Date())
        let second = MembershipPendingGeneration(requestId: "second-request", memberId: "second-member", input: input, createdAt: Date())
        try journal.save(first)
        try journal.save(second)
        try journal.removeMember(first.memberId)
        XCTAssertNil(try journal.pending(memberId: first.memberId, input: input))
        XCTAssertEqual(try journal.pending(memberId: second.memberId, input: input), second)
    }

    func testOnlyAnUnusableAppAttestKeyAllowsOneRotation() {
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)))
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(NSError(domain: DCErrorDomain, code: DCError.Code.invalidInput.rawValue)))
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(MembershipError.server("key_not_registered", 401)))
        // 2026-10-03: the server knew the key but rejected what it signed, on every launch,
        // after the phone moved between TestFlight and App Store installs. A rotated key is
        // attested from scratch, so rotating here only costs one attestation.
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(MembershipError.server("invalid_assertion", 401)))
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(
            MembershipDiagnosticFailure.wrapping(MembershipError.server("invalid_assertion", 401), at: .session)))
        XCTAssertTrue(MembershipDeviceProof.requiresKeyRotation(MembershipError.server("attestation_key_rotation_required", 401)))
        // A rejected attestation of a NEW key, or a replay, must not spin up key after key.
        for code in ["invalid_attestation", "attestation_environment_mismatch", "device_key_already_registered",
                     "assertion_replayed", "apple_proof_replayed_on_other_device", "invalid_apple_proof"] {
            XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(MembershipError.server(code, 401)), code)
        }
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(URLError(.timedOut)))
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(NSError(domain: DCErrorDomain, code: DCError.Code.serverUnavailable.rawValue)))
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(MembershipError.unverified))
        XCTAssertFalse(MembershipDeviceProof.requiresKeyRotation(MembershipError.server("app_transaction_refresh_required", 401)))
    }
}

@MainActor
final class MembershipSchedulingTests: XCTestCase {
    private var suite = ""
    private var storage: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "MembershipSchedulingTests-\(UUID().uuidString)"
        storage = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func savedSettings() -> CommuteAlarmSettings {
        var settings = CommuteAlarmSettings()
        settings.homeAddress = "Home"
        settings.workAddress = "Work"
        settings.selectedWeekdays = Set(1...7)
        settings.isEveningPreviewEnabled = false
        settings.calendarSettings.isEnabled = true
        settings.calendarSettings.overrides["2027-01-01"] = .silent
        settings.isDisasterSuspensionEnabled = true
        return settings
    }

    private func seed(_ settings: CommuteAlarmSettings, next: Date = Date().addingTimeInterval(86_400)) throws -> ScheduledAlarmSummary {
        let summary = ScheduledAlarmSummary(normalAlarmDate: next, scheduledAlarmDate: next,
            weatherRefreshDate: next.addingTimeInterval(-1_800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0)
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        storage.set(try JSONEncoder().encode(settings.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        storage.set(try JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        return summary
    }

    func testDisabledRolloutKeepsSavedRules() {
        let saved = savedSettings()
        XCTAssertEqual(MembershipSchedulingAccess.effectiveSettings(saved, entitlements: nil, membershipConfigured: false), saved)
    }

    /// A missing sync is not a revocation of the calendar, but the closure rule only takes
    /// rings away: with nothing confirmed (not restored yet in this launch, never synced,
    /// membership data deleted) the alarm rings (adversarial review, 2026-10-01).
    func testUnknownMembershipKeepsTheCalendarButNotTheClosureRule() {
        let saved = savedSettings()
        let effective = MembershipSchedulingAccess.effectiveSettings(saved, entitlements: nil, membershipConfigured: true)
        XCTAssertEqual(effective.calendarSettings, saved.calendarSettings)
        XCTAssertFalse(effective.isDisasterSuspensionEnabled)
        XCTAssertTrue(saved.isDisasterSuspensionEnabled, "the saved preference is kept for when a plan is confirmed")
        var unmasked = effective
        unmasked.isDisasterSuspensionEnabled = true
        XCTAssertEqual(unmasked, saved, "nothing but the closure rule is held back")
    }

    func testFreeAccessMasksCopyWithoutErasingCalendarOrClosurePreferences() {
        let saved = savedSettings()
        let effective = MembershipSchedulingAccess.effectiveSettings(saved, entitlements: .free)
        XCTAssertFalse(effective.calendarSettings.isEnabled)
        XCTAssertFalse(effective.isDisasterSuspensionEnabled)
        XCTAssertEqual(effective.calendarSettings.overrides, saved.calendarSettings.overrides)
        XCTAssertTrue(saved.calendarSettings.isEnabled)
        XCTAssertTrue(saved.isDisasterSuspensionEnabled)
        XCTAssertEqual(effective.selectedWeekdays, saved.selectedWeekdays)
        XCTAssertEqual(effective.alarmTime, saved.alarmTime)
    }

    func testLifetimeCalendarAndClosuresStillApplyAfterSubscriptionExpiry() {
        let saved = savedSettings()
        let both = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: true, subscriptionExpiresAt: 1)
        let effective = MembershipSchedulingAccess.effectiveSettings(saved,
            entitlements: both.valid(at: Date(timeIntervalSince1970: 2)))
        XCTAssertTrue(effective.calendarSettings.isEnabled)
        XCTAssertEqual(effective.calendarSettings, saved.calendarSettings)
        // 2026-09-28: the one-time purchase includes the day-off rule, so a lapsed
        // subscription on top of it takes nothing away.
        XCTAssertTrue(effective.isDisasterSuspensionEnabled)
    }

    func testAnExpiredSubscriptionAloneDropsTheClosureRule() {
        let saved = savedSettings()
        let subscription = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 1)
        let effective = MembershipSchedulingAccess.effectiveSettings(saved,
            entitlements: subscription.valid(at: Date(timeIntervalSince1970: 2)))
        XCTAssertFalse(effective.calendarSettings.isEnabled)
        XCTAssertFalse(effective.isDisasterSuspensionEnabled)
        XCTAssertTrue(saved.isDisasterSuspensionEnabled, "the saved preference is kept for when access returns")
    }

    func testConfirmedRevocationKeepsArmedAlarmUntilSuccessfulBasicReplacement() async throws {
        let saved = savedSettings()
        _ = try seed(saved)
        let scheduler = MembershipScheduleSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, previewScheduler: MembershipPreviewStub(),
            settingsStorage: storage, membershipEntitlements: { .free })
        let previous = model.scheduledAlarmSummary
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertEqual(scheduler.cancellations, 0)
        XCTAssertEqual(model.settings.calendarSettings.overrides, saved.calendarSettings.overrides)
        scheduler.rejectReplacement = true
        await model.applyCalendarSettings()
        XCTAssertEqual(model.scheduledAlarmSummary, previous)
        XCTAssertEqual(scheduler.cancellations, 0)
        scheduler.rejectReplacement = false
        await model.applyCalendarSettings()
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
        XCTAssertFalse(model.isScheduleStale)
        XCTAssertEqual(scheduler.calendarCalls, 0)
        XCTAssertEqual(scheduler.cancellations, 0)
        XCTAssertTrue(model.settings.calendarSettings.isEnabled)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
        let stored = try JSONDecoder().decode(CommuteAlarmSettings.self, from: XCTUnwrap(storage.data(forKey: "commuteAlarmSettings")))
        XCTAssertEqual(stored.calendarSettings, saved.calendarSettings)
        XCTAssertTrue(stored.isDisasterSuspensionEnabled)
    }

    func testCalendarOnlyPlanIsNotDeletedWhenEntitlementExpires() async throws {
        var saved = savedSettings()
        saved.selectedWeekdays = []
        saved.calendarSettings.overrides["2027-01-02"] = .ring
        _ = try seed(saved)
        let scheduler = MembershipScheduleSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, previewScheduler: MembershipPreviewStub(),
            settingsStorage: storage, membershipEntitlements: { .free })
        let previous = model.scheduledAlarmSummary
        await model.applyCalendarSettings()
        XCTAssertEqual(model.scheduledAlarmSummary, previous)
        XCTAssertEqual(scheduler.weeklyCalls, 0)
        XCTAssertEqual(scheduler.cancellations, 0)
    }

    func testConfirmedExpiryDoesNotReplaceAnImminentAlarmThroughEitherEntryPoint() async throws {
        var saved = savedSettings()
        saved.rainLeadTimeMinutes = 30
        _ = try seed(saved, next: Date().addingTimeInterval(5 * 60))
        let scheduler = MembershipScheduleSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, previewScheduler: MembershipPreviewStub(),
            settingsStorage: storage, membershipEntitlements: { .free })
        let previous = model.scheduledAlarmSummary
        await model.evaluateRouteAndScheduleAlarm()
        await model.applyCalendarSettings()
        XCTAssertEqual(model.scheduledAlarmSummary, previous)
        XCTAssertEqual(scheduler.authorizations, 0)
        XCTAssertEqual(scheduler.weeklyCalls, 0)
        XCTAssertEqual(scheduler.calendarCalls, 0)
        XCTAssertEqual(scheduler.cancellations, 0)
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertTrue(model.settings.calendarSettings.isEnabled)
    }
}

@MainActor
private final class MembershipScheduleSpy: NotificationScheduling {
    var cancellations = 0
    var weeklyCalls = 0
    var calendarCalls = 0
    var authorizations = 0
    var rejectReplacement = false
    func requestAuthorization() async throws -> Bool { authorizations += 1; return true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>,
                       sound: CommuteAlarmSettings.AlarmSound, soundFileNameOverride: String?,
                       snoozeMinutes: Int?, title: String, body: String) async throws {
        weeklyCalls += 1
        if rejectReplacement { throw MembershipError.unavailable }
    }
    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        calendarCalls += 1
    }
    func cancelScheduledAlarms() async { cancellations += 1 }
}

private struct MembershipPreviewStub: EveningPreviewScheduling {
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

/// The closure switch's lock is decided apart from the calendar lock and never
/// rewrites the saved preference or the plan mapping. What it says about the rule
/// being applied must agree with `MembershipSchedulingAccess.effectiveSettings` fed
/// the scheduling entitlements, which can differ from the ones the lock reads.
final class TemporaryClosureControlStateTests: XCTestCase {
    private static let calendarOnly = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: false,
        dailyAI: true, subscriptionActive: false, lifetimeActive: true)
    private static let withClosures = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: true,
        dailyAI: true, subscriptionActive: true, lifetimeActive: false, subscriptionExpiresAt: 10_000,
        subscriptionProductId: MembershipPlan.monthly.rawValue)

    /// Mirrors `SettingsTabView.closureControl`: the lock reads the clock-validated
    /// entitlements (`.free` without a snapshot), scheduling the raw snapshot or nil.
    private func resolve(configured: Bool = true, snapshot: MembershipEntitlements?, now: Date = Date(timeIntervalSince1970: 1),
                         saved: Bool) -> (state: TemporaryClosureControlState, applied: Bool) {
        var settings = CommuteAlarmSettings()
        settings.isDisasterSuspensionEnabled = saved
        let scheduling = configured ? snapshot : nil
        let applied = MembershipSchedulingAccess.effectiveSettings(settings, entitlements: scheduling,
                                                                   membershipConfigured: configured).isDisasterSuspensionEnabled
        let state = TemporaryClosureControlState.resolve(membershipConfigured: configured,
            entitlements: snapshot?.valid(at: now) ?? .free, schedulingEntitlements: scheduling,
            savedEnabled: saved, appliedEnabled: applied)
        return (state, applied)
    }

    private func assertCaptionMatchesScheduling(_ result: (state: TemporaryClosureControlState, applied: Bool),
                                                file: StaticString = #filePath, line: UInt = #line) {
        let state = result.state
        if state.keepsSavedRuleUnapplied { XCTAssertFalse(result.applied, file: file, line: line) }
        if state.savedRuleStillApplied { XCTAssertTrue(result.applied, file: file, line: line) }
        XCTAssertFalse(state.keepsSavedRuleUnapplied && state.savedRuleStillApplied, file: file, line: line)
    }

    func testUnconfiguredMembershipLocksNothing() {
        for saved in [false, true] {
            let result = resolve(configured: false, snapshot: nil, saved: saved)
            XCTAssertEqual(result.state.access, .available)
            XCTAssertTrue(result.state.allowsEditing)
            XCTAssertFalse(result.state.keepsSavedRuleUnapplied)
            XCTAssertFalse(result.state.savedRuleStillApplied)
            assertCaptionMatchesScheduling(result)
        }
    }

    func testEntitlementWithTheRuleIsAvailable() {
        for saved in [false, true] {
            let result = resolve(snapshot: Self.withClosures, saved: saved)
            XCTAssertEqual(result.state.access, .available)
            XCTAssertEqual(result.applied, saved)
            assertCaptionMatchesScheduling(result)
        }
    }

    func testCalendarAccessAloneDoesNotUnlockTheClosureRule() {
        let state = resolve(snapshot: Self.calendarOnly, saved: false).state
        XCTAssertEqual(state.access, .locked)
        XCTAssertFalse(state.allowsEditing)
        XCTAssertFalse(state.allowsToggle)
        XCTAssertFalse(state.keepsSavedRuleUnapplied)
    }

    func testFreePlanIsLockedAndOffersPlans() {
        let state = resolve(snapshot: .free, saved: false).state
        XCTAssertEqual(state.access, .locked)
        XCTAssertTrue(state.offersPlans)
    }

    /// Both paid plans include the rule, so a locked lifetime owner holds a stale or
    /// not-yet-redeployed server snapshot: no plans screen, and (in the view) the
    /// unconfirmed-plan line rather than the line naming the plans.
    func testLifetimeOwnerIsNotSentToThePlansScreen() {
        let state = resolve(snapshot: Self.calendarOnly, saved: true).state
        XCTAssertEqual(state.access, .locked)
        XCTAssertFalse(state.offersPlans)
    }

    func testSavedRuleOnALockedPlanIsKeptAndReportedAsNotApplied() {
        let result = resolve(snapshot: Self.calendarOnly, saved: true)
        XCTAssertEqual(result.state.access, .locked)
        XCTAssertFalse(result.applied)
        XCTAssertTrue(result.state.keepsSavedRuleUnapplied)
        XCTAssertFalse(result.state.savedRuleStillApplied)
        XCTAssertTrue(result.state.savedEnabled)
        assertCaptionMatchesScheduling(result)
    }

    func testALockedSwitchThatIsOnCanStillBeTurnedOff() {
        XCTAssertTrue(resolve(snapshot: Self.calendarOnly, saved: true).state.allowsToggle)
        XCTAssertTrue(resolve(snapshot: nil, saved: true).state.allowsToggle)
        XCTAssertFalse(resolve(snapshot: nil, saved: false).state.allowsToggle)
    }

    /// Offline past the expiry: the UI's clock-validated view has lapsed, but scheduling
    /// still holds the server-confirmed plan and keeps applying the rule.
    func testAClockExpiredSubscriptionIsUnconfirmedAndStillApplied() {
        let result = resolve(snapshot: Self.withClosures, now: Date(timeIntervalSince1970: 11), saved: true)
        XCTAssertEqual(result.state.access, .unconfirmed)
        XCTAssertTrue(result.applied)
        XCTAssertFalse(result.state.keepsSavedRuleUnapplied)
        XCTAssertTrue(result.state.savedRuleStillApplied)
        XCTAssertFalse(result.state.allowsEditing)
        XCTAssertFalse(result.state.offersPlans)
        assertCaptionMatchesScheduling(result)
    }

    /// Configured service with no snapshot (not restored yet, before the first sync, after
    /// membership data deletion): the plan is unconfirmed, not locked, but scheduling does not
    /// apply the rule — it only takes rings away (adversarial review, 2026-10-01).
    func testAMissingSnapshotIsUnconfirmedAndNotApplied() {
        let result = resolve(snapshot: nil, saved: true)
        XCTAssertEqual(result.state.access, .unconfirmed)
        XCTAssertFalse(result.applied)
        XCTAssertTrue(result.state.keepsSavedRuleUnapplied)
        XCTAssertFalse(result.state.savedRuleStillApplied)
        XCTAssertTrue(result.state.allowsToggle, "the saved rule can still be turned off")
        XCTAssertFalse(result.state.offersPlans)
        assertCaptionMatchesScheduling(result)
    }

    func testAServerConfirmedLapseIsLockedAndNotApplied() {
        let lapsed = Self.withClosures.valid(at: Date(timeIntervalSince1970: 11))
        let result = resolve(snapshot: lapsed, now: Date(timeIntervalSince1970: 11), saved: true)
        XCTAssertEqual(result.state.access, .locked)
        XCTAssertFalse(result.applied)
        XCTAssertTrue(result.state.keepsSavedRuleUnapplied)
        assertCaptionMatchesScheduling(result)
    }
}

/// The plan restore scheduling waits on (`MembershipManager.restoreSchedulingEntitlements`),
/// with the App Transaction read replaced by a gate the test opens. Adversarial review,
/// 2026-10-01: the join, the retry after a failure and the waiter's deadline had no test.
@MainActor
final class SharedRestoreTests: XCTestCase {
    @MainActor private final class Reads { var count = 0 }

    private actor Gate {
        private var held = false
        private var holder: CheckedContinuation<Void, Never>?
        private var watchers: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            held = true
            watchers.forEach { $0.resume() }
            watchers = []
            await withCheckedContinuation { holder = $0 }
        }
        func waitUntilHeld() async {
            if held { return }
            await withCheckedContinuation { watchers.append($0) }
        }
        func open() { holder?.resume(); holder = nil }
    }

    /// A second caller while the restore runs (two first activations, or `start()` after a
    /// launch's restore began) joins it: one read, and it waits for that read to end.
    func testCallersWhileARestoreRunsShareOneReadAndWaitForIt() async {
        let reads = Reads()
        let gate = Gate()
        let restore = SharedRestore { reads.count += 1; await gate.hold() }
        let first = Task { await restore.run(waitingAtMost: nil) }
        await gate.waitUntilHeld()
        final class Done: @unchecked Sendable { var value = false }
        let secondDone = Done()
        let second = Task { await restore.run(waitingAtMost: nil); secondDone.value = true }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(restore.isRunning)
        XCTAssertFalse(secondDone.value, "The joiner waits for the read it joined")

        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(reads.count, 1)
        XCTAssertFalse(restore.isRunning)
    }

    /// A read that failed restores nothing, so the next caller reads again.
    func testTheNextCallerReadsAgainOnceARestoreHasEnded() async {
        let reads = Reads()
        let restore = SharedRestore { reads.count += 1 }
        await restore.run(waitingAtMost: nil)
        XCTAssertFalse(restore.isRunning)
        await restore.run(waitingAtMost: .seconds(5))
        XCTAssertEqual(reads.count, 2)
    }

    /// Scheduling stops waiting at its deadline, or at once when cancelled (a background task's
    /// expiry); the restore goes on for whoever else waits, and ends on its own.
    func testAWaiterStopsWaitingWithoutEndingTheRestore() async {
        let reads = Reads()
        let gate = Gate()
        let restore = SharedRestore { reads.count += 1; await gate.hold() }

        let started = Date()
        await restore.run(waitingAtMost: .milliseconds(100))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Past its deadline the caller moves on")
        XCTAssertTrue(restore.isRunning, "The restore itself goes on")

        let cancelled = Task { await restore.run(waitingAtMost: nil) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancelledAt = Date()
        cancelled.cancel()
        await cancelled.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2, "A cancelled caller stops waiting at once")
        XCTAssertTrue(restore.isRunning)

        let joined = Task { await restore.run(waitingAtMost: nil) }
        await gate.open()
        await joined.value
        XCTAssertEqual(reads.count, 1, "Every waiter shared the one read")
        XCTAssertFalse(restore.isRunning)
    }
}
