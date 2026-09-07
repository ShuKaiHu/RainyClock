import Security
import XCTest
@testable import RainyClock

/// The count has to survive what `UserDefaults` does not, and the move off
/// `UserDefaults` must not cost anyone the count they already had.
///
/// The keychain refuses an unsigned process (`errSecMissingEntitlement`), which
/// is what a `CODE_SIGNING_ALLOWED=NO` test run is. The tests that need the
/// keychain itself skip there rather than fail; the quota tests still run,
/// because falling back to the mirror is exactly what the app does in that case.
@MainActor
final class AIVoiceQuotaTests: XCTestCase {
    private let store = KeychainCounters(service: "com.shukaihu.RainyClock.tests.aiVoiceQuota")
    private var previousStore: KeychainCounters!
    private var keychainAvailable = false

    // The async overrides run on the class's actor; the synchronous ones are
    // nonisolated by inheritance and cannot touch main-actor state.
    override func setUp() async throws {
        try await super.setUp()
        previousStore = AIVoiceQuota.store
        store.removeAll()
        keychainAvailable = store.set(0, forKey: "probe") == errSecSuccess
        store.removeAll()
        AIVoiceQuota.store = store
        clearMirror()
    }

    override func tearDown() async throws {
        store.removeAll()
        AIVoiceQuota.store = previousStore
        clearMirror()
        try await super.tearDown()
    }

    private func clearMirror() {
        UserDefaults.standard.removeObject(forKey: "aiVoiceGenerationsUsed")
        UserDefaults.standard.removeObject(forKey: "aiVoiceEarnedCredits")
    }

    private func requireKeychain() throws {
        try XCTSkipUnless(keychainAvailable, "keychain unavailable to this (unsigned) test host")
    }

    // MARK: - Keychain store

    func testCountersRoundTripAndOverwrite() throws {
        try requireKeychain()
        XCTAssertNil(store.integer(forKey: "n"))
        XCTAssertEqual(store.set(2, forKey: "n"), errSecSuccess)
        XCTAssertEqual(store.integer(forKey: "n"), 2)
        XCTAssertEqual(store.set(7, forKey: "n"), errSecSuccess)
        XCTAssertEqual(store.integer(forKey: "n"), 7)
    }

    func testCountersAreKeyedIndependently() throws {
        try requireKeychain()
        store.set(1, forKey: "a")
        store.set(5, forKey: "b")
        XCTAssertEqual(store.integer(forKey: "a"), 1)
        XCTAssertEqual(store.integer(forKey: "b"), 5)
    }

    func testRemoveAllClearsOnlyThisService() throws {
        try requireKeychain()
        let other = KeychainCounters(service: "com.shukaihu.RainyClock.tests.other")
        defer { other.removeAll() }
        store.set(3, forKey: "n")
        other.set(4, forKey: "n")

        store.removeAll()

        XCTAssertNil(store.integer(forKey: "n"))
        XCTAssertEqual(other.integer(forKey: "n"), 4)
    }

    // MARK: - Quota

    func testFreshDeviceHasThreeFree() {
        XCTAssertEqual(AIVoiceQuota.freeRemaining, 3)
        XCTAssertEqual(AIVoiceQuota.remaining, 3)
        XCTAssertTrue(AIVoiceQuota.canGenerate)
    }

    func testConsumingSpendsFreeBeforeCredits() {
        AIVoiceQuota.grantCredit()
        AIVoiceQuota.consume()
        AIVoiceQuota.consume()
        AIVoiceQuota.consume()

        XCTAssertEqual(AIVoiceQuota.freeRemaining, 0)
        XCTAssertEqual(AIVoiceQuota.remaining, 1, "the credit is still there after the free three")

        AIVoiceQuota.consume()
        XCTAssertEqual(AIVoiceQuota.remaining, 0)
        XCTAssertFalse(AIVoiceQuota.canGenerate)

        AIVoiceQuota.consume()
        XCTAssertEqual(AIVoiceQuota.remaining, 0, "nothing goes negative")
    }

    func testCountIsWrittenToBothTheKeychainAndTheMirror() throws {
        AIVoiceQuota.consume()
        AIVoiceQuota.consume()

        XCTAssertEqual(UserDefaults.standard.integer(forKey: "aiVoiceGenerationsUsed"), 2)
        try requireKeychain()
        XCTAssertEqual(store.integer(forKey: "aiVoiceGenerationsUsed"), 2)
    }

    func testCountSurvivesAReinstall() throws {
        try requireKeychain()
        AIVoiceQuota.consume()
        AIVoiceQuota.consume()
        AIVoiceQuota.grantCredit()

        // A reinstall takes the container — and `UserDefaults` with it — and
        // leaves the keychain.
        clearMirror()

        XCTAssertEqual(AIVoiceQuota.freeRemaining, 1)
        XCTAssertEqual(AIVoiceQuota.remaining, 2)
    }

    func testCountLeftByAnEarlierBuildIsPickedUpFromTheMirror() throws {
        // What 1.6.8 wrote, with nothing in the keychain yet.
        UserDefaults.standard.set(2, forKey: "aiVoiceGenerationsUsed")
        UserDefaults.standard.set(1, forKey: "aiVoiceEarnedCredits")

        XCTAssertEqual(AIVoiceQuota.freeRemaining, 1)
        XCTAssertEqual(AIVoiceQuota.remaining, 2)

        try requireKeychain()
        // Carried into the keychain by the read, so the next reinstall keeps it.
        XCTAssertEqual(store.integer(forKey: "aiVoiceGenerationsUsed"), 2)
        XCTAssertEqual(store.integer(forKey: "aiVoiceEarnedCredits"), 1)

        // Once the keychain has a value, a lower mirror cannot override it.
        UserDefaults.standard.set(0, forKey: "aiVoiceGenerationsUsed")
        XCTAssertEqual(AIVoiceQuota.freeRemaining, 1)
    }
}
