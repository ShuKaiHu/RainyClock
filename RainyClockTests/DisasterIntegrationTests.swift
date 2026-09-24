import XCTest
@testable import RainyClock

@MainActor
final class DisasterIntegrationTests: XCTestCase {
    // Exercise closure behavior independently of the host app's StoreKit state.
    private static let closureEntitlements = MembershipEntitlements(
        removeBanner: true, calendar: true, temporaryClosures: true,
        dailyAI: true, subscriptionActive: true, lifetimeActive: false)

    private let region = DisasterRegion(county: "臺北市", district: "信義區")
    private var calendar: Calendar { DisasterNoticeParser.taipeiCalendar }
    private func date(_ day: Int, _ hour: Int = 7, _ minute: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    private func settings() -> CommuteAlarmSettings {
        var value = CommuteAlarmSettings()
        value.homeAddress = "Home"; value.workAddress = "Work"
        value.alarmTime = date(16)
        value.isDisasterSuspensionEnabled = true
        value.homeSuspensionRegion = region
        value.homeResolvedLocation = .init(latitude: 25.033, longitude: 121.565,
            displayAddress: "Home", resolution: .exact, districtName: region.name)
        value.selectedWeekdays = Set(1...7)
        return value
    }
    private func feed(now: Date, target: String = "明天") -> DisasterFeed {
        var result = DisasterFeed(checkedAt: now, notices: [.init(id: "dgpa-test", sentAt: now,
            description: "[停班停課通知]臺北市:\(target)停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")])
        result.revision = String(repeating: "a", count: 64)
        return result
    }

    func testOnlyAnnouncedDateIsSkippedAndLaterAlarmsRemain() {
        let now = date(15, 20)
        let settings = settings()
        let base = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: now, days: 10, calendar: calendar)
        let result = DisasterAlarmPlan.filtering(base, settings: settings, feed: feed(now: now), now: now)
        XCTAssertEqual(result.skips.map(\.normalDate), [date(16)])
        XCTAssertFalse(result.plan.occurrences.contains { $0.normalDate == date(16) })
        XCTAssertTrue(result.plan.occurrences.contains { $0.normalDate == date(17) })
        XCTAssertTrue(result.plan.occurrences.contains { $0.normalDate == date(23) })
        XCTAssertEqual(base.coveredUntil, result.plan.coveredUntil)
    }

    func testManualRingWinsOnlyWhileCalendarEnabled() {
        let now = date(15, 20)
        var settings = settings()
        settings.calendarSettings = .init(isEnabled: true, source: .weekly, overrides: ["2026-09-16": .ring])
        let base = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: now, days: 3, calendar: calendar)
        XCTAssertTrue(DisasterAlarmPlan.filtering(base, settings: settings, feed: feed(now: now), now: now).skips.isEmpty)
        settings.calendarSettings.isEnabled = false
        XCTAssertEqual(DisasterAlarmPlan.filtering(base, settings: settings, feed: feed(now: now), now: now).skips.count, 1)
    }

    func testRainCrossingMidnightUsesNormalAlarmDate() {
        let now = date(15, 20)
        var settings = settings()
        settings.alarmTime = date(16, 0, 10); settings.rainLeadTimeMinutes = 30
        let base = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: true, now: now, days: 3, calendar: calendar)
        let result = DisasterAlarmPlan.filtering(base, settings: settings, feed: feed(now: now), now: now)
        XCTAssertEqual(result.skips.first?.normalDate, date(16, 0, 10))
        XCTAssertEqual(result.plan.occurrences.first?.normalDate, date(17, 0, 10))
    }

    func testMissingFeedAndDisabledFeatureNeverRemoveAnOccurrence() {
        let now = date(15, 20)
        var settings = settings()
        let base = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: now, days: 3, calendar: calendar)
        XCTAssertEqual(DisasterAlarmPlan.filtering(base, settings: settings, feed: nil, now: now).plan, base)
        settings.isDisasterSuspensionEnabled = false
        XCTAssertEqual(DisasterAlarmPlan.filtering(base, settings: settings, feed: feed(now: now), now: now).plan, base)
    }

    func testLegacyMigrationLeavesFeatureOffAndFingerprintUnchanged() throws {
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.isDisasterSuspensionEnabled)
        XCTAssertNil(settings.scheduleFingerprint().disasterSettings)
        var changed = settings
        changed.homeSuspensionRegion = region
        XCTAssertEqual(changed.scheduleFingerprint(), settings.scheduleFingerprint())
        changed.isDisasterSuspensionEnabled = true
        XCTAssertNotEqual(changed.scheduleFingerprint(), settings.scheduleFingerprint())
    }

    func testPreviewUsesCommittedSkipEvenWhenCalendarIsOff() {
        let now = date(15, 18)
        let summary = ScheduledAlarmSummary(normalAlarmDate: date(17), scheduledAlarmDate: date(17),
            weatherRefreshDate: date(17, 7), exceedsRainThreshold: false, leadTimeMinutes: 0,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0,
            disasterSkips: [.init(normalDate: date(16), noticeIDs: ["notice"], appliedAt: now)])
        let previews = EveningPreviewPlanner.plan(summary: summary, selectedWeekdays: Set(1...7),
            previewTime: date(15, 21), checkedAt: now, now: now, canRefreshInBackground: true, calendar: calendar)
        XCTAssertTrue(previews.contains { if case .dayOff(let day) = $0.kind { return day == date(16) }; return false })
    }

    func testFetchAppliesOnlyAfterSchedulingAndFailurePreservesSummary() async throws {
        let suite = "DisasterIntegration-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let now = Date()
        let next = calendar.date(byAdding: .day, value: 1, to: now)!
        var settings = settings()
        settings.alarmTime = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: next)!
        try storage.set(JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(.init(checkedAt: now, notices: [])))
        let scheduler = DisasterSchedulerSpy()
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(reporter.receipts.isEmpty, "Scheduling without a fetched revision must not acknowledge an announcement")
        let before = try XCTUnwrap(model.scheduledAlarmSummary)
        XCTAssertNil(model.nextAppliedDisasterSkip)
        await provider.set(.success(feed(now: Date())))
        scheduler.fail = true
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(model.scheduledAlarmSummary, before)
        XCTAssertNil(model.nextAppliedDisasterSkip)
        XCTAssertTrue(model.disasterScheduleNeedsAttention)
        XCTAssertTrue(reporter.receipts.isEmpty, "Fetching successfully is not a successful alarm update")
        scheduler.fail = false
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(model.nextAppliedDisasterSkip?.noticeIDs, ["dgpa-test"])
        XCTAssertFalse(model.disasterScheduleNeedsAttention)
        XCTAssertEqual(reporter.receipts.last?.result, .applied)
        XCTAssertEqual(reporter.receipts.last?.revision, String(repeating: "a", count: 64))
        let receiptCount = reporter.receipts.count
        let scheduledCount = scheduler.calendarCalls
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(scheduler.calendarCalls, scheduledCount, "Identical announcements should not rebuild the schedule")
        XCTAssertEqual(reporter.receipts.count, receiptCount + 1, "A confirmed unchanged plan may acknowledge a fresh check")
        let beforeFailure = reporter.receipts.count
        await provider.set(.failure(URLError(.notConnectedToInternet)))
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertTrue(model.disasterRefreshFailed)
        XCTAssertEqual(reporter.receipts.count, beforeFailure, "Restoring after a failed fetch must not acknowledge the old feed")
        XCTAssertNil(model.nextAppliedDisasterSkip, "If reachable, a failed check restores the normal alarm")
        XCTAssertTrue(model.scheduledAlarmSummary?.calendarPlan?.occurrences.contains { calendar.isDate($0.normalDate, inSameDayAs: next) } == true)
        model.settings.isDisasterSuspensionEnabled = false
        await model.applyCalendarSettings()
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
        XCTAssertNil(model.scheduledAlarmSummary?.disasterSkips)
    }

    func testNoAlarmReceiptIsDistinctFromAppliedAndFailedFetchCannotRepeatIt() async throws {
        let suite = "DisasterReceiptNoAlarm-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(feed(now: Date())))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(reporter.receipts.map(\.result), [.noAlarm])
        XCTAssertNil(model.scheduledAlarmSummary)
        await provider.set(.failure(URLError(.notConnectedToInternet)))
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(reporter.receipts.count, 1)
        model.settings.isDisasterSuspensionEnabled = false
        await provider.set(.success(feed(now: Date())))
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(reporter.receipts.count, 1, "Disabled features do not upload acknowledgement data")
    }

    func testMissingRevisionOrStaleFeedCannotProduceReceipt() async throws {
        let suite = "DisasterReceiptValidation-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(feed(now: Date().addingTimeInterval(-16 * 60))))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertTrue(reporter.receipts.isEmpty)
        var legacy = feed(now: Date())
        legacy.revision = nil
        await provider.set(.success(legacy))
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertTrue(reporter.receipts.isEmpty)
    }

    func testConcurrentPushWaitsForNewFetchAndAcknowledgesNewestRevision() async throws {
        let suite = "DisasterReceiptConcurrent-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let gate = DisasterTestGate()
        let firstFeed = feed(now: Date())
        var secondFeed = firstFeed
        secondFeed.revision = String(repeating: "b", count: 64)
        secondFeed.checkedAt = firstFeed.checkedAt.addingTimeInterval(0.01)
        let provider = GatedFeedStub(first: firstFeed, second: secondFeed, gate: gate)
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        let first = Task { await model.refreshDisasterSuspensions(force: true) }
        await gate.waitUntilEntered()
        let started = expectation(description: "Second push entered the shared refresh")
        let second = Task {
            started.fulfill()
            return await model.refreshDisasterSuspensions(force: true)
        }
        await fulfillment(of: [started], timeout: 2)
        await gate.open()
        _ = await first.value
        _ = await second.value
        let calls = await provider.calls
        XCTAssertEqual(calls, 2, "A second push must fetch fresh data before completing")
        XCTAssertEqual(model.disasterFeed?.revision, secondFeed.revision)
        XCTAssertEqual(reporter.receipts.map(\.revision), [secondFeed.revision!])
    }

    func testSettingsChangedDuringRegistrationCannotAcknowledgeStalePlan() async throws {
        let suite = "DisasterReceiptDrift-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let scheduler = DisasterSchedulerSpy()
        let provider = FeedStub(value: .success(feed(now: Date())))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        await model.evaluateRouteAndScheduleAlarm()
        let gate = DisasterTestGate()
        scheduler.beforeCalendarCompletion = { await gate.hold() }
        let refresh = Task { await model.refreshDisasterSuspensions(force: true) }
        await gate.waitUntilEntered()
        model.settings.alarmTime = model.settings.alarmTime.addingTimeInterval(60)
        await gate.open()
        _ = await refresh.value
        XCTAssertTrue(model.isScheduleStale)
        XCTAssertTrue(reporter.receipts.isEmpty, "The old settings were registered, not the current ones")
        scheduler.beforeCalendarCompletion = nil
        scheduler.fail = true
        await model.applyCalendarSettings()
        XCTAssertTrue(reporter.receipts.isEmpty)
        XCTAssertTrue(model.disasterScheduleNeedsAttention)
    }

    func testDisabledFeatureRetriesFailedRestoreAfterRelaunchWithoutFetching() async throws {
        let suite = "DisasterRestore-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        var settings = settings()
        settings.isDisasterSuspensionEnabled = false
        try storage.set(JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        var previous = settings
        previous.isDisasterSuspensionEnabled = true
        try storage.set(JSONEncoder().encode(previous.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let date = Date().addingTimeInterval(24 * 3_600)
        let summary = ScheduledAlarmSummary(normalAlarmDate: date, scheduledAlarmDate: date,
            weatherRefreshDate: date.addingTimeInterval(-1800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0,
            disasterSkips: [.init(normalDate: date, noticeIDs: ["old"], appliedAt: Date())])
        try storage.set(JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(Date(), forKey: "lastWeatherEvaluationAt")
        let provider = FeedStub(value: .failure(URLError(.notConnectedToInternet)))
        let scheduler = DisasterSchedulerSpy()
        scheduler.fail = true
        let first = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage, disasterFeedProvider: provider,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        _ = await first.refreshDisasterSuspensions()
        XCTAssertTrue(first.disasterScheduleNeedsAttention)
        XCTAssertNotNil(first.nextAppliedDisasterSkip)
        scheduler.fail = false
        let relaunched = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage, disasterFeedProvider: provider,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        XCTAssertTrue(relaunched.disasterScheduleNeedsAttention)
        await relaunched.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertNil(relaunched.nextAppliedDisasterSkip)
        XCTAssertFalse(relaunched.disasterScheduleNeedsAttention)
        XCTAssertFalse(relaunched.disasterRefreshFailed, "Disabled restoration must not query the failed provider")
        XCTAssertFalse(relaunched.isScheduleStale)
    }

    func test170ReleaseExcludesClosureWithoutErasingSavedRulesOrFetching() async throws {
        XCTAssertFalse(AppEnvironment.supportsTemporaryClosures)
        let suite = "DeferredClosures-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let saved = settings()
        try storage.set(JSONEncoder().encode(saved), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(feed(now: Date())))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter, membershipEntitlements: { nil })
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
        XCTAssertFalse(model.effectiveSchedulingSettings.isDisasterSuspensionEnabled)
        XCTAssertNil(model.effectiveSchedulingSettings.scheduleFingerprint().disasterSettings)
        XCTAssertNil(model.disasterFeed)
        XCTAssertTrue(reporter.receipts.isEmpty)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        let persisted = try JSONDecoder().decode(CommuteAlarmSettings.self,
            from: XCTUnwrap(storage.data(forKey: "commuteAlarmSettings")))
        XCTAssertTrue(persisted.isDisasterSuspensionEnabled)
    }

    func test170ReleaseRetriesOldClosureScheduleWithoutCancellingExistingAlarm() async throws {
        let suite = "DeferredClosuresUpgrade-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let saved = settings()
        try storage.set(JSONEncoder().encode(saved), forKey: "commuteAlarmSettings")
        try storage.set(JSONEncoder().encode(saved.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let date = Date().addingTimeInterval(86_400)
        let old = ScheduledAlarmSummary(normalAlarmDate: date, scheduledAlarmDate: date,
            weatherRefreshDate: date.addingTimeInterval(-1800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0,
            disasterSkips: [.init(normalDate: date, noticeIDs: ["old"], appliedAt: Date())])
        try storage.set(JSONEncoder().encode(old), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(Date(), forKey: "lastWeatherEvaluationAt")
        let provider = FeedStub(value: .failure(URLError(.notConnectedToInternet)))
        let scheduler = DisasterSchedulerSpy()
        scheduler.fail = true
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            disasterFeedProvider: provider, membershipEntitlements: { nil })
        let restored = model.scheduledAlarmSummary
        _ = await model.refreshDisasterSuspensions()
        XCTAssertEqual(model.scheduledAlarmSummary, restored)
        XCTAssertTrue(model.isScheduleStale)
        XCTAssertEqual(scheduler.cancellations, 0)
        scheduler.fail = false
        await model.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertNil(model.scheduledAlarmSummary?.disasterSkips)
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
        XCTAssertFalse(model.isScheduleStale)
        XCTAssertEqual(scheduler.cancellations, 0)
        XCTAssertGreaterThan(scheduler.weeklyCalls, 0)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    func testDeferringClosuresPreservesAnActiveCalendarOnlySchedule() async throws {
        let suite = "DeferredClosuresCalendarOnly-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        var saved = settings()
        saved.selectedWeekdays = []
        saved.calendarSettings.isEnabled = true
        let date = Date().addingTimeInterval(86_400)
        saved.calendarSettings.overrides[AlarmCalendarSettings.key(for: date)] = .ring
        try storage.set(JSONEncoder().encode(saved), forKey: "commuteAlarmSettings")
        try storage.set(JSONEncoder().encode(saved.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let old = ScheduledAlarmSummary(normalAlarmDate: date, scheduledAlarmDate: date,
            weatherRefreshDate: date.addingTimeInterval(-1800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0)
        try storage.set(JSONEncoder().encode(old), forKey: "scheduledAlarmSummaryDisplay")
        let scheduler = DisasterSchedulerSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            membershipEntitlements: { nil })
        await model.applyCalendarSettings()
        XCTAssertEqual(scheduler.calendarCalls, 1)
        XCTAssertEqual(scheduler.cancellations, 0)
        XCTAssertFalse(model.isScheduleStale)
        XCTAssertTrue(model.scheduledAlarmSummary?.calendarPlan?.occurrences.isEmpty == false)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
    }
}

@MainActor
private final class DisasterReceiptSpy: DisasterSyncReporting {
    var receipts: [DisasterSyncReceipt] = []
    func report(_ receipt: DisasterSyncReceipt) async { receipts.append(receipt) }
}

private actor FeedStub: DisasterFeedProviding {
    var value: Result<DisasterFeed, Error>
    init(value: Result<DisasterFeed, Error>) { self.value = value }
    func set(_ value: Result<DisasterFeed, Error>) { self.value = value }
    private(set) var calls = 0
    func fetch() async throws -> DisasterFeed { calls += 1; return try value.get() }
}

private actor DisasterTestGate {
    private var entered = false
    private var entrant: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        entrant?.resume(); entrant = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entrant = $0 }
    }
    func open() { release?.resume(); release = nil }
}

private actor GatedFeedStub: DisasterFeedProviding {
    let first: DisasterFeed
    let second: DisasterFeed
    let gate: DisasterTestGate
    private(set) var calls = 0
    init(first: DisasterFeed, second: DisasterFeed, gate: DisasterTestGate) {
        self.first = first; self.second = second; self.gate = gate
    }
    func fetch() async throws -> DisasterFeed {
        calls += 1
        if calls == 1 { await gate.hold(); return first }
        return second
    }
}

private final class DisasterSchedulerSpy: NotificationScheduling, @unchecked Sendable {
    var fail = false
    var calendarCalls = 0
    var weeklyCalls = 0
    var cancellations = 0
    var beforeCalendarCompletion: (@Sendable () async -> Void)?
    func requestAuthorization() async throws -> Bool { true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>, sound: CommuteAlarmSettings.AlarmSound,
                       soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        weeklyCalls += 1
        if fail { throw URLError(.cannotWriteToFile) }
    }
    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        calendarCalls += 1
        if fail { throw URLError(.cannotWriteToFile) }
        await beforeCalendarCompletion?()
    }
    func cancelScheduledAlarms() async { cancellations += 1 }
}
