import XCTest
@testable import RainyClock

final class TomorrowAlarmStatusTests: XCTestCase {
    private var calendar: Calendar { DisasterNoticeParser.taipeiCalendar }
    private func date(_ day: Int, _ hour: Int = 18, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    private func settings() -> CommuteAlarmSettings {
        var value = CommuteAlarmSettings()
        value.homeAddress = "Home"; value.workAddress = "Work"
        value.alarmTime = date(15, 7, 30)
        value.selectedWeekdays = Set(1...7)
        value.rainLeadTimeMinutes = 30
        value.rainProbabilityThreshold = 0.5
        return value
    }
    private func record(_ settings: CommuteAlarmSettings, now: Date, probability: Double = 0.8) -> TomorrowWeatherRecord {
        let request = TomorrowWeatherRequest(settings: settings, now: now, calendar: calendar)
        return .init(request: request, snapshot: .init(checkedAt: now, forecastAt: request.forecastDate,
            segments: [.init(name: "Home", condition: .rain, precipitationProbability: probability)]))
    }
    private func status(_ settings: CommuteAlarmSettings, now: Date, holidays: HolidayCalendar = .init(),
                        weather: TomorrowWeatherRecord? = nil, summary: ScheduledAlarmSummary? = nil,
                        feed: DisasterFeed? = nil, failed: Bool = false, routeReady: Bool = true) -> TomorrowAlarmStatus {
        .resolve(settings: settings, holidays: holidays, weatherRecord: weather, weatherRefreshFailed: failed,
            routeIsReady: routeReady, summary: summary,
            registeredFingerprint: summary == nil ? nil : settings.scheduleFingerprint(calendar: calendar),
            disasterFeed: feed, disasterSourceFailed: false, now: now, calendar: calendar)
    }
    private func summary(normal: Date, ring: Date) -> ScheduledAlarmSummary {
        .init(normalAlarmDate: normal, scheduledAlarmDate: ring, weatherRefreshDate: normal.addingTimeInterval(-1_800),
            exceedsRainThreshold: ring < normal, leadTimeMinutes: ring < normal ? 30 : 0,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: ring < normal ? 0.8 : 0.1)
    }

    func testTomorrowWeekendAndNamedHolidayRemainVisibleWithWeather() {
        var value = settings()
        value.calendarSettings = .init(isEnabled: true, source: .taiwan)
        let now = date(11)
        let weather = record(value, now: now)
        let weekend = status(value, now: now, holidays: .init(days: ["2026-09-12": .init(isOff: true, name: "")]), weather: weather)
        XCTAssertEqual(weekend.day, date(12, 0))
        XCTAssertEqual(weekend.reason, .weekend)
        XCTAssertNil(weekend.expectedRingDate)
        XCTAssertEqual(weekend.weather, weather.snapshot)
        let holiday = status(value, now: now, holidays: .init(days: ["2026-09-12": .init(isOff: true, name: "Named holiday")]))
        XCTAssertEqual(holiday.reason, .holiday)
        XCTAssertEqual(holiday.holidayName, "Named holiday")
    }

    func testUnitedStatesHolidayStatusUsesSelectedSourceInsteadOfTaiwanCache() {
        var value = settings()
        value.calendarSettings = .init(isEnabled: true, source: .unitedStates)
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 18))!
        let taiwanCache = HolidayCalendar(days: ["2026-07-04": .init(isOff: false, name: "Taiwan-only note")])
        let result = status(value, now: now, holidays: taiwanCache)
        XCTAssertNil(result.expectedRingDate)
        XCTAssertEqual(result.reason, .holiday, "A named federal holiday on Saturday must not become a generic weekend")
        XCTAssertEqual(result.holidayName, "Independence Day")
    }

    func testUnselectedWeekdayAndManualRulesDoNotJumpToNextEligibleDate() {
        var value = settings()
        value.selectedWeekdays = [2]
        let now = date(15)
        let weekday = status(value, now: now)
        XCTAssertEqual(weekday.normalAlarmDate, date(16, 7, 30))
        XCTAssertEqual(weekday.reason, .unselectedWeekday)
        XCTAssertNil(weekday.expectedRingDate)
        value.calendarSettings = .init(isEnabled: true, source: .taiwan, overrides: ["2026-09-16": .ring])
        XCTAssertEqual(status(value, now: now).reason, .manual)
        XCTAssertEqual(status(value, now: now).expectedRingDate, date(16, 7, 30))
        value.calendarSettings.overrides["2026-09-16"] = .silent
        XCTAssertEqual(status(value, now: now).reason, .manual)
        XCTAssertNil(status(value, now: now).expectedRingDate)
        value.calendarSettings.isEnabled = false
        XCTAssertEqual(status(value, now: now).reason, .unselectedWeekday)
    }

    func testCrossMidnightForecastUsesExactRequestedPointAndRejectsWrongHour() {
        var value = settings()
        value.alarmTime = date(15, 0, 15)
        let now = date(15, 20)
        var weather = record(value, now: now)
        XCTAssertEqual(weather.request.forecastDate, date(15, 23, 45))
        let result = status(value, now: now, weather: weather)
        XCTAssertEqual(result.day, date(16, 0))
        XCTAssertEqual(result.expectedRingDate, date(15, 23, 45))
        XCTAssertEqual(result.reason, .rain)
        XCTAssertEqual(result.leadTimeMinutes, 30)
        weather.snapshot.forecastAt = date(15, 7)
        XCTAssertNil(status(value, now: now, weather: weather).weather)
        XCTAssertEqual(status(value, now: now, weather: weather).expectedRingDate, date(16, 0, 15))
    }

    func testForecastProvenanceRejectsChangedRouteCoordinatesModeAndTomorrowDate() {
        let value = settings()
        let now = date(15)
        let weather = record(value, now: now)
        var changed = value
        changed.homeAddress = "Different home"
        XCTAssertNil(status(changed, now: now, weather: weather).weather)
        changed = value
        changed.homeResolvedLocation = .init(latitude: 25, longitude: 121, displayAddress: "Home", resolution: .exact)
        XCTAssertNil(status(changed, now: now, weather: weather).weather)
        changed = value
        changed.commuteMode = .walking
        XCTAssertNil(status(changed, now: now, weather: weather).weather)
        XCTAssertNil(status(value, now: date(16), weather: weather).weather)
    }

    func testStaleWeatherKeepsOriginalTimestampWithoutClaimingFreshRain() {
        let value = settings()
        let now = date(15)
        var weather = record(value, now: now)
        weather.snapshot.checkedAt = now.addingTimeInterval(-3_600)
        let result = status(value, now: now, weather: weather, failed: true)
        XCTAssertEqual(result.weather?.checkedAt, weather.snapshot.checkedAt)
        XCTAssertTrue(result.weatherIsStale)
        XCTAssertTrue(result.weatherRefreshFailed)
        XCTAssertEqual(result.expectedRingDate, date(16, 7, 30))
        XCTAssertEqual(result.reason, .normal)
    }

    func testExactTomorrowRegistrationIsPreservedWhileForecastPendingButTodaysIsNotReused() {
        let value = settings()
        let now = date(15)
        let tomorrow = summary(normal: date(16, 7, 30), ring: date(16, 7))
        let pending = status(value, now: now, summary: tomorrow)
        XCTAssertEqual(pending.expectedRingDate, date(16, 7))
        XCTAssertEqual(pending.reason, .rain)
        XCTAssertNil(pending.weather)
        XCTAssertFalse(pending.isScheduleVerified)
        let today = summary(normal: date(15, 7, 30), ring: date(15, 7))
        let result = status(value, now: now, summary: today)
        XCTAssertEqual(result.expectedRingDate, date(16, 7, 30))
        XCTAssertNil(result.registeredRingDate)
        XCTAssertNil(result.weather)
        XCTAssertFalse(result.isScheduleVerified)
    }

    func testFreshTomorrowForecastDoesNotClaimDifferentRegistrationSucceeded() {
        let value = settings()
        let now = date(15)
        let registered = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        let result = status(value, now: now, weather: record(value, now: now), summary: registered)
        XCTAssertEqual(result.expectedRingDate, date(16, 7))
        XCTAssertEqual(result.registeredRingDate, date(16, 7, 30))
        XCTAssertFalse(result.isScheduleVerified)
        XCTAssertEqual(status(value, now: now, routeReady: false).reason, .routeIncomplete)
        XCTAssertNil(status(value, now: now, routeReady: false).expectedRingDate)
    }

    func testDisasterPreviewDoesNotClaimCommittedCancellationAndManualRingWins() {
        var value = settings()
        let now = date(15)
        value.isDisasterSuspensionEnabled = true
        value.homeSuspensionRegion = .init(county: "臺北市", district: "信義區")
        let feed = DisasterFeed(checkedAt: now, notices: [.init(id: "notice", sentAt: now,
            description: "[停班停課通知]臺北市:明天停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")])
        var registered = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        registered.calendarPlan = .init(occurrences: [.init(normalDate: date(16, 7, 30), ringDate: date(16, 7, 30))],
            coveredUntil: date(20, 0), timeZoneID: calendar.timeZone.identifier)
        let result = status(value, now: now, summary: registered, feed: feed)
        XCTAssertEqual(result.reason, .disaster)
        XCTAssertNil(result.expectedRingDate)
        XCTAssertEqual(result.registeredRingDate, date(16, 7, 30))
        XCTAssertFalse(result.isScheduleVerified)
        XCTAssertEqual(result.disasterNoticeIDs, ["notice"])
        value.calendarSettings = .init(isEnabled: true, source: .taiwan, overrides: ["2026-09-16": .ring])
        XCTAssertEqual(status(value, now: now, feed: feed).reason, .manual)
        XCTAssertEqual(status(value, now: now, feed: feed).expectedRingDate, date(16, 7, 30))
    }

    func testExpiredDatedCoverageCannotVerifyTomorrow() {
        let value = settings()
        let now = date(15)
        var registered = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        registered.calendarPlan = .init(occurrences: [], coveredUntil: date(16, 0), timeZoneID: calendar.timeZone.identifier)
        XCTAssertFalse(status(value, now: now, summary: registered).isScheduleVerified)
        XCTAssertNil(status(value, now: now, summary: registered).registeredRingDate)
    }
}

@MainActor
final class TomorrowWeatherRefreshTests: XCTestCase {
    private var storage: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "TomorrowWeatherTests-\(UUID())"
        storage = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        storage.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func model(service: TomorrowWeatherStub, scheduler: TomorrowSchedulerSpy) -> AlarmViewModel {
        let model = AlarmViewModel(routeWeatherService: service, notificationScheduler: scheduler,
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        model.settings.homeAddress = "Home"
        model.settings.workAddress = "Work"
        return model
    }
    func testSkippedTomorrowFetchesWeatherAndNeverWritesScheduleOrRouteWeather() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now)
        let scheduler = TomorrowSchedulerSpy()
        let model = model(service: service, scheduler: scheduler)
        model.settings.selectedWeekdays = []
        let request = TomorrowWeatherRequest(settings: model.settings, now: now)
        await model.refreshTomorrowWeatherIfNeeded(now: now)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.date, request.forecastDate)
        XCTAssertNotNil(model.tomorrowStatus(now: now).weather)
        XCTAssertNil(model.tomorrowStatus(now: now).expectedRingDate)
        XCTAssertNil(model.routeWeatherSnapshot)
        XCTAssertNil(model.scheduledAlarmSummary)
        XCTAssertNil(storage.data(forKey: "scheduledAlarmFingerprint"))
        XCTAssertEqual(scheduler.calls, 0)
        await model.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(120))
        let count = await service.requests.count
        XCTAssertEqual(count, 1, "A fresh matching display forecast is cached")
    }
    func testFailurePreservesGoodSnapshotAndRetryIsThrottled() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now)
        let model = model(service: service, scheduler: TomorrowSchedulerSpy())
        await model.refreshTomorrowWeatherIfNeeded(now: now)
        let original = model.tomorrowStatus(now: now).weather
        let persisted = storage.data(forKey: TomorrowWeatherRecord.cacheKey)
        XCTAssertNotNil(persisted)
        await service.setFailure(true)
        await model.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(2), force: true)
        XCTAssertEqual(model.tomorrowStatus(now: now).weather, original)
        XCTAssertEqual(storage.data(forKey: TomorrowWeatherRecord.cacheKey), persisted)
        XCTAssertTrue(model.tomorrowStatus(now: now).weatherRefreshFailed)
        await model.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(20))
        var count = await service.requests.count
        XCTAssertEqual(count, 2)
        await service.setFailure(false)
        await model.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(70))
        count = await service.requests.count
        XCTAssertEqual(count, 3)
        XCTAssertFalse(model.tomorrowStatus(now: now).weatherRefreshFailed)
    }
    func testAddressEditRejectsOldInFlightForecast() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now, gated: true)
        let model = model(service: service, scheduler: TomorrowSchedulerSpy())
        let pending = Task { await model.refreshTomorrowWeatherIfNeeded(now: now) }
        await service.waitUntilStarted()
        model.settings.homeAddress = "New home"
        await service.release()
        await pending.value
        XCTAssertNil(model.tomorrowStatus(now: now).weather)
        XCTAssertFalse(model.tomorrowStatus(now: now).weatherRefreshFailed)
        XCTAssertFalse(model.isRefreshingTomorrowWeather)
        XCTAssertNil(storage.data(forKey: TomorrowWeatherRecord.cacheKey), "A superseded request must not populate the persistent cache")
        await model.refreshTomorrowWeatherIfNeeded(now: now)
        let requests = await service.requests
        XCTAssertEqual(requests.last?.home, "New home")
        XCTAssertNotNil(model.tomorrowStatus(now: now).weather)
    }
    func testCancellationDoesNotPublishDataOrFailureAndAllowsNextRetry() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now, gated: true)
        let model = model(service: service, scheduler: TomorrowSchedulerSpy())
        let pending = Task { await model.refreshTomorrowWeatherIfNeeded(now: now) }
        await service.waitUntilStarted()
        pending.cancel()
        await service.release()
        await pending.value
        XCTAssertNil(model.tomorrowStatus(now: now).weather)
        XCTAssertFalse(model.tomorrowStatus(now: now).weatherRefreshFailed)
        XCTAssertFalse(model.isRefreshingTomorrowWeather)
        XCTAssertNil(storage.data(forKey: TomorrowWeatherRecord.cacheKey), "Cancellation must not leave a forecast to restore on the next launch")
        await model.refreshTomorrowWeatherIfNeeded(now: now)
        XCTAssertNotNil(model.tomorrowStatus(now: now).weather)
    }
    func testWrongForecastHourIsAnUpdateFailureNotSuccessfulDryWeather() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now, forecastOffset: 3_600)
        let scheduler = TomorrowSchedulerSpy()
        let model = model(service: service, scheduler: scheduler)
        await model.refreshTomorrowWeatherIfNeeded(now: now)
        XCTAssertNil(model.tomorrowStatus(now: now).weather)
        XCTAssertTrue(model.tomorrowStatus(now: now).weatherRefreshFailed)
        XCTAssertNil(storage.data(forKey: TomorrowWeatherRecord.cacheKey))
        XCTAssertEqual(scheduler.calls, 0)
    }

    func testFreshPersistedForecastRestoresSynchronouslyAndSkipsNetworkOnRelaunch() async {
        let now = Date()
        let original = model(service: TomorrowWeatherStub(checkedAt: now), scheduler: TomorrowSchedulerSpy())
        await original.refreshTomorrowWeatherIfNeeded(now: now)
        let snapshot = original.tomorrowStatus(now: now).weather
        XCTAssertNotNil(snapshot)

        let offlineService = TomorrowWeatherStub(checkedAt: now)
        await offlineService.setFailure(true)
        let scheduler = TomorrowSchedulerSpy()
        let restored = AlarmViewModel(routeWeatherService: offlineService, notificationScheduler: scheduler,
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        XCTAssertEqual(restored.tomorrowStatus(now: now).weather, snapshot,
                       "The first render must have the forecast before any async refresh")
        XCTAssertFalse(restored.tomorrowStatus(now: now).weatherIsStale)
        XCTAssertFalse(restored.isRefreshingTomorrowWeather)
        await restored.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(120))
        let requests = await offlineService.requests
        XCTAssertTrue(requests.isEmpty, "A matching forecast younger than 30 minutes needs no network request")
        XCTAssertEqual(scheduler.calls, 0)
        XCTAssertNil(restored.routeWeatherSnapshot)
        XCTAssertNil(restored.scheduledAlarmSummary)
    }

    func testStalePersistedForecastDisplaysImmediatelyThenRefreshes() async {
        let now = Date()
        let initial = model(service: TomorrowWeatherStub(checkedAt: now), scheduler: TomorrowSchedulerSpy())
        let request = TomorrowWeatherRequest(settings: initial.settings, now: now)
        let stale = TomorrowWeatherRecord(request: request, snapshot: .init(
            checkedAt: now.addingTimeInterval(-3_600), forecastAt: request.forecastDate,
            segments: [.init(name: "Home", condition: .cloudy, precipitationProbability: 0.2)]))
        stale.save(to: storage, now: now)

        let service = TomorrowWeatherStub(checkedAt: now)
        let scheduler = TomorrowSchedulerSpy()
        let restored = AlarmViewModel(routeWeatherService: service, notificationScheduler: scheduler,
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        XCTAssertEqual(restored.tomorrowStatus(now: now).weather, stale.snapshot)
        XCTAssertTrue(restored.tomorrowStatus(now: now).weatherIsStale)
        await restored.refreshTomorrowWeatherIfNeeded(now: now)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(restored.tomorrowStatus(now: now).weather?.checkedAt, now)
        XCTAssertFalse(restored.tomorrowStatus(now: now).weatherIsStale)
        XCTAssertEqual(TomorrowWeatherRecord.load(from: storage, matching: request, now: now)?.snapshot,
                       restored.tomorrowStatus(now: now).weather)
        XCTAssertEqual(scheduler.calls, 0)
    }

    func testPersistentCachePreservesCrossMidnightForecastAndRejectsEveryChangedInput() {
        let now = Date()
        var settings = CommuteAlarmSettings()
        let calendar = AlarmCalendarSettings.calendar
        settings.homeAddress = "Home"; settings.workAddress = "Work"
        settings.alarmTime = calendar.date(bySettingHour: 0, minute: 15, second: 0, of: now)!
        settings.rainLeadTimeMinutes = 30
        settings.homeResolvedLocation = .init(latitude: 25, longitude: 121, displayAddress: "Home", resolution: .exact)
        settings.workResolvedLocation = .init(latitude: 25.1, longitude: 121.1, displayAddress: "Work", resolution: .exact)
        let request = TomorrowWeatherRequest(settings: settings, now: now)
        let record = TomorrowWeatherRecord(request: request, snapshot: .init(checkedAt: now,
            forecastAt: request.forecastDate, segments: [.init(name: "Home", condition: .rain, precipitationProbability: 0.8)]))
        XCTAssertTrue(calendar.isDate(request.forecastDate, inSameDayAs: now))
        XCTAssertFalse(calendar.isDate(request.normalAlarmDate, inSameDayAs: now))
        record.save(to: storage, now: now)
        XCTAssertEqual(TomorrowWeatherRecord.load(from: storage, matching: request, now: now), record)

        let changes: [(String, (inout TomorrowWeatherRequest) -> Void)] = [
            ("home address", { $0.homeAddress = "New home" }),
            ("work address", { $0.workAddress = "New work" }),
            ("home coordinates", { $0.homeLocation?.latitude += 0.01 }),
            ("work coordinates", { $0.workLocation?.longitude += 0.01 }),
            ("transport", { $0.mode = .walking }),
            ("normal alarm time", { $0.normalAlarmDate += 60 }),
            ("forecast time", { $0.forecastDate += 60 }),
            ("time zone", { $0.timeZoneID = "UTC" }),
            ("next day", { $0.normalAlarmDate += 86_400; $0.forecastDate += 86_400 })
        ]
        for (name, change) in changes {
            var changed = request
            change(&changed)
            XCTAssertNil(TomorrowWeatherRecord.load(from: storage, matching: changed, now: now), name)
        }
    }

    func testDamagedOrInvalidCacheDoesNotRestoreOrPreventLaunching() throws {
        let now = Date()
        let initial = model(service: TomorrowWeatherStub(checkedAt: now), scheduler: TomorrowSchedulerSpy())
        let request = TomorrowWeatherRequest(settings: initial.settings, now: now)
        let valid = TomorrowWeatherRecord(request: request, snapshot: .init(checkedAt: now,
            forecastAt: request.forecastDate, segments: [.init(name: "Home", condition: .clear, precipitationProbability: 0.1)]))
        var wrongHour = valid; wrongHour.snapshot.forecastAt += 3_600
        var futureCheck = valid; futureCheck.snapshot.checkedAt += 3_600
        var empty = valid; empty.snapshot.segments = []
        var invalidProbability = valid; invalidProbability.snapshot.segments[0].precipitationProbability = 1.1
        var damagedData = [Data("{broken".utf8), Data(repeating: 32, count: 256_001)]
        damagedData += try [wrongHour, futureCheck, empty, invalidProbability].map { try JSONEncoder().encode($0) }
        let scheduler = TomorrowSchedulerSpy()
        for data in damagedData {
            storage.set(data, forKey: TomorrowWeatherRecord.cacheKey)
            let restored = AlarmViewModel(routeWeatherService: TomorrowWeatherStub(checkedAt: now),
                notificationScheduler: scheduler, settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
            XCTAssertNil(restored.tomorrowStatus(now: now).weather)
            XCTAssertFalse(restored.tomorrowStatus(now: now).weatherRefreshFailed)
        }
        XCTAssertEqual(scheduler.calls, 0)
    }
}

private actor TomorrowWeatherStub: RouteWeatherService {
    struct Request { var home: String; var date: Date }
    private(set) var requests: [Request] = []
    private let checkedAt: Date
    private let forecastOffset: TimeInterval
    private var gated: Bool
    private var fails = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(checkedAt: Date, gated: Bool = false, forecastOffset: TimeInterval = 0) {
        self.checkedAt = checkedAt; self.gated = gated; self.forecastOffset = forecastOffset
    }
    func setFailure(_ value: Bool) { fails = value }
    func waitUntilStarted() async {
        if requests.isEmpty { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { gated = false; completion?.resume(); completion = nil }
    func fetchRouteWeather(from homeAddress: String, homeLocation: ResolvedMapLocation?,
                           to workAddress: String, workLocation: ResolvedMapLocation?,
                           mode: CommuteAlarmSettings.CommuteMode, around commuteTime: Date) async throws -> RouteWeatherSnapshot {
        requests.append(.init(home: homeAddress, date: commuteTime))
        startWaiter?.resume(); startWaiter = nil
        if gated { await withCheckedContinuation { completion = $0 } }
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(checkedAt: checkedAt, forecastAt: commuteTime.addingTimeInterval(forecastOffset),
            segments: [.init(name: "Home", condition: .rain, precipitationProbability: 0.8),
                       .init(name: "Work", condition: .cloudy, precipitationProbability: 0.2)])
    }
}

private final class TomorrowSchedulerSpy: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls = 0
    var calls: Int { lock.withLock { storedCalls } }
    func requestAuthorization() async throws -> Bool { lock.withLock { storedCalls += 1 }; return true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>, sound: CommuteAlarmSettings.AlarmSound,
                       soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        lock.withLock { storedCalls += 1 }
    }
    func cancelScheduledAlarms() async { lock.withLock { storedCalls += 1 } }
}
