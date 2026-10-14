import XCTest
@testable import RainyClock

@MainActor
final class AppUpdateGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdateGateTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private typealias Listing = AppUpdateGate.StoreListing
    private let store = URL(string: "https://apps.apple.com/tw/app/rainy-clock/id6780500386")!

    /// Lookup calls, counted from a `@Sendable` closure; the gate runs them on the main actor.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func gate(version: String = "1.8.0", build: Int = 40, now: @escaping () -> Date = Date.init,
                      lookup: @escaping @Sendable () async throws -> Listing) -> AppUpdateGate {
        AppUpdateGate(defaults: defaults, currentVersion: version, currentBuild: build, lookup: lookup, now: now)
    }

    func testSemanticVersionComparison() {
        XCTAssertTrue(AppUpdateGate.isVersion("1.8.2", newerThan: "1.8.1"))
        XCTAssertTrue(AppUpdateGate.isVersion("1.9", newerThan: "1.8.2"))
        XCTAssertTrue(AppUpdateGate.isVersion("2.0.0", newerThan: "1.10.3"))
        XCTAssertTrue(AppUpdateGate.isVersion("1.8.10", newerThan: "1.8.9"))
        XCTAssertFalse(AppUpdateGate.isVersion("1.8.0", newerThan: "1.8"))
        XCTAssertFalse(AppUpdateGate.isVersion("1.8.1", newerThan: "1.8.2"))
        XCTAssertFalse(AppUpdateGate.isVersion("1.8.2", newerThan: "1.8.2"))
        XCTAssertFalse(AppUpdateGate.isVersion("", newerThan: "1.8.2"))
        XCTAssertFalse(AppUpdateGate.isVersion("beta", newerThan: "1.8.2"))
    }

    func testNewerStoreVersionShowsAndTheCachedListingSurvivesARelaunchWithoutALookup() async {
        let store = store
        let first = gate { Listing(version: "1.8.1", trackViewURL: store) }
        XCTAssertNil(first.availableUpdate)
        await first.checkAppStoreIfDue()
        XCTAssertEqual(first.availableUpdate?.version, "1.8.1")
        XCTAssertEqual(first.storeURL, store)

        // A new process the same day: the cached listing shows at once, with no lookup.
        let calls = Counter()
        let second = gate { calls.value += 1; return Listing(version: "1.8.1", trackViewURL: store) }
        XCTAssertEqual(second.availableUpdate?.version, "1.8.1")
        await second.checkAppStoreIfDue()
        XCTAssertEqual(calls.value, 0)

        // The next day's answer replaces it; a listing without a page falls back to the app id.
        let later = gate(now: { Date().addingTimeInterval(AppUpdateGate.lookupInterval + 1) }) {
            Listing(version: "1.8.2", trackViewURL: nil)
        }
        await later.checkAppStoreIfDue()
        XCTAssertEqual(later.availableUpdate?.version, "1.8.2")
        XCTAssertEqual(later.storeURL, AppUpdateGate.fallbackStoreURL)

        // Once the running version catches up, the row goes away by itself.
        XCTAssertNil(self.gate(version: "1.8.2") { Listing(version: "1.8.2", trackViewURL: nil) }.availableUpdate)
    }

    func testSameOrOlderStoreVersionAndFailuresShowNothing() async {
        for version in ["1.8.0", "1.7.9", "1.8"] {
            let gate = AppUpdateGate(defaults: UserDefaults(suiteName: suiteName + version)!, currentVersion: "1.8.0",
                                     currentBuild: 40, lookup: { Listing(version: version, trackViewURL: nil) })
            await gate.checkAppStoreIfDue()
            XCTAssertNil(gate.availableUpdate, version)
        }
        let failing = gate { throw URLError(.notConnectedToInternet) }
        await failing.checkAppStoreIfDue()
        XCTAssertNil(failing.availableUpdate)
        XCTAssertFalse(failing.requiresUpdate)
    }

    func testLookupHappensAtMostOncePerDayEvenAfterAFailure() async {
        let calls = Counter()
        let gate = gate { calls.value += 1; throw URLError(.timedOut) }
        await gate.checkAppStoreIfDue()
        await gate.checkAppStoreIfDue()
        XCTAssertEqual(calls.value, 1)
        let tomorrow = self.gate(now: { Date().addingTimeInterval(AppUpdateGate.lookupInterval + 1) }) {
            calls.value += 1; return Listing(version: "1.8.1", trackViewURL: nil)
        }
        await tomorrow.checkAppStoreIfDue()
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(tomorrow.availableUpdate?.version, "1.8.1")
    }

    func testMinimumSupportedBuildBlocksOnlyOlderBuildsAndZeroLiftsTheBlock() {
        let gate = gate(build: 40) { Listing(version: "1.8.0", trackViewURL: nil) }
        XCTAssertFalse(gate.requiresUpdate)
        gate.record(minimumSupportedBuild: 40)
        XCTAssertFalse(gate.requiresUpdate)
        gate.record(minimumSupportedBuild: 41)
        XCTAssertTrue(gate.requiresUpdate)
        // Persisted: the next launch is blocked before any response arrives.
        XCTAssertTrue(self.gate(build: 40) { Listing(version: "1.8.0", trackViewURL: nil) }.requiresUpdate)
        XCTAssertFalse(self.gate(build: 41) { Listing(version: "1.8.0", trackViewURL: nil) }.requiresUpdate)
        gate.record(minimumSupportedBuild: -5)
        XCTAssertTrue(gate.requiresUpdate)
        gate.record(minimumSupportedBuild: 0)
        XCTAssertFalse(gate.requiresUpdate)
        XCTAssertFalse(self.gate(build: 40) { Listing(version: "1.8.0", trackViewURL: nil) }.requiresUpdate)
        // An unreadable own build is unknown, not old.
        XCTAssertFalse(self.gate(build: 0) { Listing(version: "1.8.0", trackViewURL: nil) }.requiresUpdate)
    }

    func testAppStoreLookupParsesVersionAndTrackURLAndRejectsEmptyResults() throws {
        let json = """
        {"resultCount":1,"results":[{"version":"1.8.1","trackViewUrl":"\(store.absoluteString)","bundleId":"com.shukaihu.RainyClock"}]}
        """
        let listing = try AppStoreLookup.parse(Data(json.utf8))
        XCTAssertEqual(listing, Listing(version: "1.8.1", trackViewURL: store))
        XCTAssertThrowsError(try AppStoreLookup.parse(Data("{\"resultCount\":0,\"results\":[]}".utf8)))
        XCTAssertThrowsError(try AppStoreLookup.parse(Data("<html>".utf8)))
    }

    func testMembershipResponsesCarryTheMinimumSupportedBuild() {
        XCTAssertEqual(MembershipClient.minimumSupportedBuild(in: Data("{\"minimumSupportedBuild\":41,\"token\":\"t\"}".utf8)), 41)
        XCTAssertEqual(MembershipClient.minimumSupportedBuild(in: Data("{\"minimumSupportedBuild\":0}".utf8)), 0)
        XCTAssertNil(MembershipClient.minimumSupportedBuild(in: Data("{\"minimumSupportedBuild\":-1}".utf8)))
        XCTAssertNil(MembershipClient.minimumSupportedBuild(in: Data("{\"minimumSupportedBuild\":\"41\"}".utf8)))
        XCTAssertNil(MembershipClient.minimumSupportedBuild(in: Data("{\"memberId\":\"m\"}".utf8)))
        XCTAssertNil(MembershipClient.minimumSupportedBuild(in: Data("[]".utf8)))
    }

    func testEveryMembershipRequestNamesTheRunningBuildAndVersion() throws {
        let routing = try MembershipConfiguration.routing(verifiedEnvironment: .production,
            baseURL: URL(string: "https://membership.example.com")!, legacySandbox: false)
        for path in ["challenge", "session", "status"] {
            let request = try MembershipClient.makeRequest(routing: routing, path: "/v1/membership/" + path,
                body: Data("{}".utf8), headers: ["X-RC-App-Build": "forged", "X-RC-App-Version": "forged"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-RC-App-Build"), AppBuildInfo.buildString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-RC-App-Version"), AppBuildInfo.version)
        }
        XCTAssertGreaterThan(AppBuildInfo.build, 0)
        XCTAssertTrue(AppUpdateGate.isVersion(AppBuildInfo.version, newerThan: "0"))
    }
}
