import XCTest
@testable import RainyClock

@MainActor
final class DisasterRouteRegionTests: XCTestCase {
    private let home = DisasterRegion(county: "臺北市", district: "信義區")
    private let work = DisasterRegion(county: "新北市", district: "新店區")
    private let stale = DisasterRegion(county: "高雄市", district: "左營區")
    private var storage: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DisasterRouteRegionTests-\(UUID())"
        storage = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func location(_ district: String?, address: String = "Home") -> ResolvedMapLocation {
        .init(latitude: 25.033, longitude: 121.565, displayAddress: address,
              resolution: .exact, districtName: district)
    }

    private func save(_ settings: CommuteAlarmSettings) throws {
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
    }

    func testUpgradeReplacesManualRegionsAndMatchingUsesRouteRegions() throws {
        var saved = CommuteAlarmSettings()
        saved.homeAddress = "Home"
        saved.workAddress = "Work"
        saved.isDisasterSuspensionEnabled = true
        saved.homeResolvedLocation = location("台北市信義區")
        saved.workResolvedLocation = location(work.name, address: "Work")
        saved.homeSuspensionRegion = stale
        saved.workSuspensionRegion = stale
        try save(saved)
        let nextAlarm = Date().addingTimeInterval(86_400)
        let priorSummary = ScheduledAlarmSummary(normalAlarmDate: nextAlarm, scheduledAlarmDate: nextAlarm,
            weatherRefreshDate: nextAlarm.addingTimeInterval(-1_800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0)
        storage.set(try JSONEncoder().encode(priorSummary), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try JSONEncoder().encode(saved.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")

        let model = AlarmViewModel(settingsStorage: storage)
        XCTAssertEqual(model.settings.homeSuspensionRegion, home)
        XCTAssertEqual(model.settings.workSuspensionRegion, work)
        XCTAssertEqual(model.settings.scheduleFingerprint().disasterSettings?.home, home)
        XCTAssertTrue(model.isScheduleStale, "A registration made using obsolete manual districts must be reconciled")
        let persisted = try JSONDecoder().decode(CommuteAlarmSettings.self,
            from: XCTUnwrap(storage.data(forKey: "commuteAlarmSettings")))
        XCTAssertEqual(persisted.homeSuspensionRegion, home)
        XCTAssertEqual(persisted.workSuspensionRegion, work)

        let now = DisasterISO8601.date("2026-09-15T06:00:00+08:00")!
        func decision(in region: DisasterRegion) -> DisasterDecision {
            let notice = DisasterNotice(id: region.name, sentAt: now,
                description: "[停班停課通知]\(region.name):今天停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")
            return DisasterSuspensionEvaluator.decision(feed: .init(checkedAt: now, notices: [notice]),
                normalAlarmDate: now.addingTimeInterval(3_600), now: now,
                home: model.settings.homeSuspensionRegion, destination: model.settings.workSuspensionRegion,
                observesWork: true, observesSchool: false)
        }
        XCTAssertFalse(decision(in: stale).shouldSkip, "An obsolete manual district cannot cancel the new route's alarm")
        XCTAssertTrue(decision(in: home).shouldSkip)
        XCTAssertTrue(decision(in: work).shouldSkip)
    }

    func testUpgradeClearsManualRegionsWhenRouteCannotSupplyOne() throws {
        var saved = CommuteAlarmSettings()
        saved.homeAddress = "Home"
        saved.homeResolvedLocation = location(nil)
        saved.homeSuspensionRegion = stale
        saved.workAddress = " "
        saved.workResolvedLocation = location(work.name, address: "Work")
        saved.workSuspensionRegion = stale
        try save(saved)

        let model = AlarmViewModel(settingsStorage: storage)
        XCTAssertNil(model.homeAutomaticSuspensionRegion)
        XCTAssertNil(model.workAutomaticSuspensionRegion)
        XCTAssertNil(model.settings.homeSuspensionRegion)
        XCTAssertNil(model.settings.workSuspensionRegion)
    }

    func testSelectingAndEditingRouteUpdatesRegionsWithoutManualSelection() {
        let model = AlarmViewModel(settingsStorage: storage)
        model.setAddressFromSuggestion("Home", location: location(home.name), field: .home)
        model.setAddressFromSuggestion("Work", location: location(work.name, address: "Work"), field: .work)
        XCTAssertEqual(model.settings.homeSuspensionRegion, home)
        XCTAssertEqual(model.settings.workSuspensionRegion, work)

        model.settings.homeAddress = "Different home"
        XCTAssertNil(model.homeAutomaticSuspensionRegion)
        XCTAssertNil(model.settings.homeSuspensionRegion)
        XCTAssertEqual(model.settings.workSuspensionRegion, work)
        model.settings.workAddress = ""
        XCTAssertNil(model.settings.workSuspensionRegion)
    }

    func testAcceptedPreviewSuppliesRegionsAndAddressEditInvalidatesThem() async {
        // Resolved names differ from the typed text, so neither address is confirmed
        // silently and clearing the preview must drop the unconfirmed regions.
        let preview = DistrictRoutePreview(home: location(home.name, address: "Home Road 1"),
                                           work: location(work.name, address: "Work Road 2"))
        let model = AlarmViewModel(routePreviewService: preview, settingsStorage: storage)
        model.settings.homeAddress = "Home"
        model.settings.workAddress = "Work"
        await model.previewRoute()
        XCTAssertEqual(model.settings.homeSuspensionRegion, home)
        XCTAssertEqual(model.settings.workSuspensionRegion, work)
        model.settings.homeAddress = "New draft"
        XCTAssertNil(model.homeAutomaticSuspensionRegion)
        XCTAssertNil(model.settings.homeSuspensionRegion)
        model.clearRoutePreview()
        XCTAssertNil(model.workAutomaticSuspensionRegion)
        XCTAssertNil(model.settings.workSuspensionRegion)
    }

    func testSameAddressNewMapSelectionOverridesOldPreviewDistrict() async {
        let preview = DistrictRoutePreview(home: location(home.name), work: location(work.name, address: "Work"))
        let model = AlarmViewModel(routePreviewService: preview, settingsStorage: storage)
        model.setAddressFromSuggestion("Home", location: location(home.name), field: .home)
        model.setAddressFromSuggestion("Work", location: location(work.name, address: "Work"), field: .work)
        await model.previewRoute()

        model.setAddressFromSuggestion("Home", location: location(stale.name), field: .home)
        XCTAssertEqual(model.homeAutomaticSuspensionRegion, stale)
        XCTAssertEqual(model.settings.homeSuspensionRegion, stale)
        model.setAddressFromSuggestion("Home", location: location(nil), field: .home)
        XCTAssertNil(model.homeAutomaticSuspensionRegion, "An old preview must not fill in the district for a different map point")
        XCTAssertNil(model.settings.homeSuspensionRegion)
    }

    func testLatePreviewCannotOverwriteNewMapPointWithSameAddressText() async {
        let oldHome = location(home.name)
        let destination = location(work.name, address: "Work")
        let service = GatedDistrictRoutePreview(value: .init(homeCoordinate: oldHome.coordinate,
            workCoordinate: destination.coordinate, homeLocation: oldHome, workLocation: destination, route: nil))
        let model = AlarmViewModel(routePreviewService: service, settingsStorage: storage)
        model.setAddressFromSuggestion("Home", location: oldHome, field: .home)
        model.setAddressFromSuggestion("Work", location: destination, field: .work)
        let pending = Task { await model.previewRoute() }
        await service.waitUntilStarted()
        let replacement = ResolvedMapLocation(latitude: 22.68, longitude: 120.29,
            displayAddress: "Home", resolution: .exact, districtName: stale.name)
        model.setAddressFromSuggestion("Home", location: replacement, field: .home)
        service.complete()
        await pending.value
        XCTAssertEqual(model.settings.homeResolvedLocation, replacement)
        XCTAssertEqual(model.settings.homeSuspensionRegion, stale)
        XCTAssertEqual(model.homeAutomaticSuspensionRegion, stale)
    }
}

@MainActor
private struct DistrictRoutePreview: RoutePreviewService {
    let home: ResolvedMapLocation
    let work: ResolvedMapLocation
    func previewRoute(from homeAddress: String, homeLocation: ResolvedMapLocation?,
                      to workAddress: String, workLocation: ResolvedMapLocation?,
                      mode: CommuteAlarmSettings.CommuteMode) async throws -> RoutePreview {
        .init(homeCoordinate: home.coordinate, workCoordinate: work.coordinate,
              homeLocation: home, workLocation: work, route: nil)
    }
}

@MainActor
private final class GatedDistrictRoutePreview: RoutePreviewService {
    private let value: RoutePreview
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(value: RoutePreview) { self.value = value }

    func previewRoute(from homeAddress: String, homeLocation: ResolvedMapLocation?,
                      to workAddress: String, workLocation: ResolvedMapLocation?,
                      mode: CommuteAlarmSettings.CommuteMode) async throws -> RoutePreview {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return value
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }
}
