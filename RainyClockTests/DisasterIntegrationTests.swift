import Combine
import UIKit
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

    /// Adversarial review, 2026-10-01: a closure announced at 12:00 was skipped, then every
    /// re-plan from 06:00 the next morning — once the notice was 18 h old — put 07:30 back.
    func testNoonClosureStaysSkippedWhenReplannedTheNextMorning() {
        let settings = settings()
        let announced = date(15, 12, 0)
        var feed = DisasterFeed(checkedAt: announced, notices: [.init(id: "noon", sentAt: announced,
            description: "[停班停課通知]臺北市:明天停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")])
        for now in [date(15, 12, 5), date(16, 6, 30)] {
            feed.checkedAt = now.addingTimeInterval(-60)
            let base = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: now, days: 3, calendar: calendar)
            let result = DisasterAlarmPlan.filtering(base, settings: settings, feed: feed, now: now)
            XCTAssertEqual(result.skips.map(\.normalDate), [date(16)], "\(now)")
            XCTAssertEqual(result.skips.first?.noticeIDs, ["noon"], "\(now)")
            XCTAssertFalse(result.plan.occurrences.contains { $0.normalDate == date(16) }, "\(now)")
            XCTAssertTrue(result.plan.occurrences.contains { $0.normalDate == date(17) }, "\(now)")
        }
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
        XCTAssertTrue(previews.contains { if case .closure(let day, _) = $0.kind { return day == date(16) }; return false })
    }

    /// Adversarial review 2026-10-01: a morning skipped for a verified closure was previewed as
    /// "off according to your calendar" — the wrong cause, and no source. DAYOFF-SPEC §7 and
    /// the store copy promise the source and its own update time wherever a closure is reported;
    /// the preview uses the same two lines the alarm card shows under a closure.
    func testAClosurePreviewNamesTheClosureAndItsSourceNotTheCalendar() throws {
        let now = date(15, 18)
        let sourceUpdated = date(15, 17, 5)
        let summary = ScheduledAlarmSummary(normalAlarmDate: date(17), scheduledAlarmDate: date(17),
            weatherRefreshDate: date(17, 7), exceedsRainThreshold: false, leadTimeMinutes: 0,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0,
            disasterSkips: [.init(normalDate: date(16), noticeIDs: ["notice"], appliedAt: now)])
        // The calendar is off: nothing but the closure silences 9/16.
        let previews = EveningPreviewPlanner.plan(summary: summary, selectedWeekdays: Set(1...7),
            previewTime: date(15, 21), checkedAt: now, now: now, canRefreshInBackground: true, calendar: calendar,
            closureSourceUpdatedAt: sourceUpdated)
        let closure = try XCTUnwrap(previews.first { $0.identifier == "commute-rain-preview-20260916" })
        XCTAssertEqual(closure.kind, .closure(normalAlarmDate: date(16), sourceUpdatedAt: sourceUpdated))
        let body = EveningPreviewText.body(for: closure)
        XCTAssertFalse(body.contains(String(localized: "evening_preview_day_off")), body)
        XCTAssertEqual(body, [String(localized: "evening_preview_closure"),
                              String.localizedStringWithFormat(String(localized: "disaster_source_updated"),
                                                               EveningPreviewText.sourceTime(sourceUpdated, format: closure.timeFormat)),
                              String(localized: "disaster_source")].joined(separator: "\n"))
        // Month and day, no year (adversarial review, 2026-10-01): the source time is always this
        // week's, and a banner line spent on "2026" pushes the licence credit past the cut-off.
        XCTAssertFalse(body.contains("2026"), body)
        XCTAssertTrue(body.contains(sourceUpdated.formatted(.dateTime.month(.defaultDigits).day())), body)
        XCTAssertTrue(body.contains(closure.timeFormat.time(sourceUpdated)), body)

        // A feed without its own update time still credits the source; the time is left out, never faked.
        let undated = EveningPreview(identifier: closure.identifier, fireDate: closure.fireDate,
            kind: .closure(normalAlarmDate: date(16), sourceUpdatedAt: nil), canRefreshInBackground: true)
        XCTAssertEqual(EveningPreviewText.body(for: undated),
                       String(localized: "evening_preview_closure") + "\n" + String(localized: "disaster_source"))

        // Both languages carry the new sentence, and neither blames the calendar.
        let bundle = Bundle(for: AlarmViewModel.self)
        for language in ["en", "zh-Hant"] {
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                 forLocalization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
            let sentence = try XCTUnwrap(table["evening_preview_closure"], language)
            XCTAssertFalse(sentence.isEmpty, language)
            XCTAssertFalse(sentence.lowercased().contains("calendar") || sentence.contains("行事曆") || sentence.contains("月曆"),
                           "\(language): \(sentence)")
        }
    }

    /// A push that lands while a fetch is in flight — the app was opened, then locked on
    /// a slow network — must still be fetched before a later open's join completes. The
    /// alert push does not wake the app, so nothing else will ask. (Adversarial review of
    /// the throttle fix: the join path never reached the marker check.)
    func testPushDuringAnInFlightFetchTriggersOneMoreFetch() async throws {
        let suite = "DisasterPushInFlight-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let gate = DisasterTestGate()
        let firstFeed = feed(now: Date())
        var secondFeed = feed(now: Date().addingTimeInterval(1))
        secondFeed.revision = String(repeating: "b", count: 64)
        let provider = GatedFeedStub(first: firstFeed, second: secondFeed, gate: gate)
        final class PushBox { var receivedAt: Date? }
        let push = PushBox()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true,
            dayOffPushReceivedAt: { push.receivedAt })
        let opened = Task { await model.refreshDisasterSuspensions() }
        await gate.waitUntilEntered()
        push.receivedAt = Date()
        let joined = expectation(description: "The reopen joined the in-flight refresh")
        let reopened = Task {
            joined.fulfill()
            return await model.refreshDisasterSuspensions()
        }
        await fulfillment(of: [joined], timeout: 2)
        await gate.open()
        _ = await opened.value
        _ = await reopened.value
        var calls = await provider.calls
        XCTAssertEqual(calls, 2, "The push postdates the in-flight fetch, so one more fetch must follow")
        XCTAssertEqual(model.disasterFeed?.revision, secondFeed.revision)
        _ = await model.refreshDisasterSuspensions()
        calls = await provider.calls
        XCTAssertEqual(calls, 2, "Once fetched after the push, the throttle holds again")
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
        let provider = FeedStub(value: .success(feed(now: Date().addingTimeInterval(-61 * 60))))
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

    /// The service polls every 30 minutes, so the feed a phone downloads is
    /// routinely that old and still has to acknowledge.
    func testFeedFromThePreviousPollStillProducesReceipt() async throws {
        let suite = "DisasterReceiptHalfHour-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(feed(now: Date().addingTimeInterval(-31 * 60))))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(reporter.receipts.map(\.result), [.noAlarm])
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

    /// The day-off alert push does not wake the app, and its text says "open the app to
    /// confirm". Found on device: a fetch failed at 23:50, the push arrived at 23:51, the
    /// user opened the app at 23:53 — inside the five-minute throttle — and the app kept
    /// showing the failure instead of applying the closure.
    func testPushSinceLastAttemptBypassesRefreshThrottle() async throws {
        let suite = "DisasterPushThrottle-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try storage.set(JSONEncoder().encode(settings()), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .failure(URLError(.badServerResponse)))
        final class PushBox { var receivedAt: Date? }
        let push = PushBox()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true,
            dayOffPushReceivedAt: { push.receivedAt })
        _ = await model.refreshDisasterSuspensions()
        XCTAssertTrue(model.disasterRefreshFailed)
        var calls = await provider.calls
        XCTAssertEqual(calls, 1)

        push.receivedAt = try XCTUnwrap(model.disasterLastAttemptAt).addingTimeInterval(-1)
        _ = await model.refreshDisasterSuspensions()
        calls = await provider.calls
        XCTAssertEqual(calls, 1, "A push older than the last attempt was already covered by it")

        await provider.set(.success(feed(now: Date())))
        push.receivedAt = Date()
        _ = await model.refreshDisasterSuspensions()
        calls = await provider.calls
        XCTAssertEqual(calls, 2, "Opening the app after a push must fetch despite the throttle")
        XCTAssertFalse(model.disasterRefreshFailed)

        _ = await model.refreshDisasterSuspensions()
        calls = await provider.calls
        XCTAssertEqual(calls, 2, "Without a newer push the throttle still holds")
    }

    /// The model the closure switch drives, with the evening previews off so nothing but
    /// the switch can ask for notification permission.
    private func closureSwitchModel(storage: UserDefaults, permission: EveningPreviewScheduling,
                                    usesNotificationAlarms: Bool, savedOn: Bool = false,
                                    scheduler: DisasterSchedulerSpy = DisasterSchedulerSpy(),
                                    entitlements: MembershipEntitlements? = DisasterIntegrationTests.closureEntitlements,
                                    reminder: @escaping @MainActor (Date, Bool) async -> Void = { _, _ in }) throws -> AlarmViewModel {
        var saved = settings()
        saved.isDisasterSuspensionEnabled = savedOn
        saved.isEveningPreviewEnabled = false
        try storage.set(JSONEncoder().encode(saved), forKey: "commuteAlarmSettings")
        return AlarmViewModel(notificationScheduler: scheduler, previewScheduler: permission,
            settingsStorage: storage, autoRefreshDebounce: .seconds(60),
            disasterFeedProvider: FeedStub(value: .success(.init(checkedAt: Date(), notices: []))),
            disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { entitlements }, membershipConfigured: { true }, restoreMembershipEntitlements: {},
            updateDisasterPushRegistration: { _ in }, replaceCoverageReminder: reminder, supportsTemporaryClosures: true,
            usesNotificationAlarms: usesNotificationAlarms)
    }

    /// The closure announcements are visible pushes. On iOS 26 the alarm's permission is
    /// AlarmKit's, so with the evening previews off nothing ever asked for notification
    /// permission and every announcement was dropped unseen. Turning the rule on asks,
    /// once; a refusal leaves the rule on. (Adversarial review, 2026-10-01.)
    func testTurningClosuresOnAsksForNotificationPermissionOnceOnAlarmKit() async throws {
        let suite = "DisasterPermissionAlarmKit-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let permission = ClosurePermissionSpy(grants: false)
        let model = try closureSwitchModel(storage: storage, permission: permission, usesNotificationAlarms: false)
        let asked = expectation(description: "Turning the rule on asked for notification permission")
        permission.onRequest(asked)
        model.settings.isDisasterSuspensionEnabled = true
        await fulfillment(of: [asked], timeout: 2)
        XCTAssertEqual(permission.requests, 1)
        // The spy answers before the model's task resumes from the prompt: let that task finish
        // before judging what a refusal did.
        let settled = expectation(description: "The prompt's task has finished")
        settled.isInverted = true
        await fulfillment(of: [settled], timeout: 0.3)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled, "A refusal must not turn the rule back off")
        XCTAssertTrue(model.effectiveSchedulingSettings.isDisasterSuspensionEnabled)
        let status = await model.notificationAuthorizationStatus()
        XCTAssertTrue(model.closureAnnouncementsAreBlocked(notifications: status),
                      "Refused, the switch says announcements cannot appear")

        let askedAgain = expectation(description: "An answered prompt is not shown again")
        askedAgain.isInverted = true
        permission.onRequest(askedAgain)
        model.settings.isDisasterSuspensionEnabled = false
        model.settings.isDisasterSuspensionEnabled = true
        await fulfillment(of: [askedAgain], timeout: 0.5)
        XCTAssertEqual(permission.requests, 1)
    }

    /// On iOS 17–25 the alarm is itself a notification and asks when it is scheduled, in
    /// its own context; the closure switch leaves that prompt to it.
    func testTurningClosuresOnLeavesNotificationAlarmsToAskForPermission() async throws {
        let suite = "DisasterPermissionNotifications-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let permission = ClosurePermissionSpy(grants: true)
        let model = try closureSwitchModel(storage: storage, permission: permission, usesNotificationAlarms: true)
        let asked = expectation(description: "The closure switch asked on the notification-alarm path")
        asked.isInverted = true
        permission.onRequest(asked)
        model.settings.isDisasterSuspensionEnabled = true
        await fulfillment(of: [asked], timeout: 0.5)
        XCTAssertEqual(permission.requests, 0)
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
    }

    /// The prompt belongs to the switch, in front of the person who turned it on: never to a
    /// background task, a push or a closure refresh, which have no screen to show it on, even
    /// with the rule saved on and permission undecided.
    func testNothingButTheSwitchAsksForNotificationPermission() async throws {
        let suite = "DisasterPermissionUnattended-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let permission = ClosurePermissionSpy(grants: true)
        let model = try closureSwitchModel(storage: storage, permission: permission, usesNotificationAlarms: false, savedOn: true)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(model.hasScheduledAlarm)
        _ = await model.refreshScheduledAlarmUnattended()
        _ = await model.refreshDisasterSuspensions(force: true)
        await model.loadMembershipEntitlements()
        await model.membershipPlanDidChange()
        XCTAssertEqual(permission.requests, 0)
    }

    /// The same gate push registration uses: a plan that does not include the rule, or no
    /// confirmed plan at all, applies no closure and so asks for nothing.
    func testTurningClosuresOnWithoutAPlanThatIncludesThemAsksForNothing() async throws {
        let without = MembershipEntitlements(removeBanner: true, calendar: true, temporaryClosures: false,
            dailyAI: true, subscriptionActive: true, lifetimeActive: false)
        for plan in [without, nil] as [MembershipEntitlements?] {
            let suite = "DisasterPermissionNoPlan-\(UUID())"
            let storage = UserDefaults(suiteName: suite)!
            defer { storage.removePersistentDomain(forName: suite) }
            let permission = ClosurePermissionSpy(grants: true)
            let model = try closureSwitchModel(storage: storage, permission: permission, usesNotificationAlarms: false,
                                               entitlements: plan)
            let asked = expectation(description: "No plan with the rule, no prompt")
            asked.isInverted = true
            permission.onRequest(asked)
            model.settings.isDisasterSuspensionEnabled = true
            await fulfillment(of: [asked], timeout: 0.5)
            XCTAssertEqual(permission.requests, 0, String(describing: plan))
        }
    }

    /// Adversarial review, 2026-10-01: the rule makes the plan dated, and that registration
    /// usually finishes while the prompt is still up, so the renewal reminder it tries to set
    /// is refused for want of permission. Allowing it must set the reminder: with the previews
    /// off nothing re-registers once the prompt closes, and a plan could run out unannounced.
    func testAllowingNotificationsFromTheClosurePromptSetsTheRenewalReminder() async throws {
        let suite = "DisasterPermissionReminder-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let permission = GatedPermission()
        final class Reminders { var set: [(coveredUntil: Date, authorized: Bool)] = [] }
        let reminders = Reminders()
        let scheduler = DisasterSchedulerSpy()
        let model = try closureSwitchModel(storage: storage, permission: permission, usesNotificationAlarms: false,
                                           scheduler: scheduler, reminder: { coveredUntil, _ in
            let authorized = await permission.authorizationStatus() == .authorized
            reminders.set.append((coveredUntil, authorized))
        })
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(scheduler.weeklyCalls, 1)

        model.settings.isDisasterSuspensionEnabled = true
        await permission.gate.waitUntilEntered()
        // The prompt is up; the closure refresh re-registers the plan as a dated one meanwhile.
        let deadline = Date().addingTimeInterval(5)
        while (scheduler.calendarCalls == 0 || model.isScheduling), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let plan = try XCTUnwrap(model.scheduledAlarmSummary?.calendarPlan)
        XCTAssertFalse(reminders.set.contains { $0.authorized }, "Undecided: the reminder could not be set")

        await permission.gate.open()
        while !reminders.set.contains(where: { $0.authorized }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reminders.set.last?.coveredUntil, plan.coveredUntil)
        XCTAssertEqual(reminders.set.last?.authorized, true)
    }

    /// iOS 26: refused notifications drop every announcement push unseen, and the switch says
    /// so. Not while the rule is off, and not on iOS 17–25, where the alarm itself says so.
    func testTheClosureSwitchWarnsOnlyWhenAnnouncementsCannotAppear() throws {
        for (usesNotificationAlarms, savedOn, status, warns) in [
            (false, true, EveningPreviewAuthorization.denied, true),
            (false, true, .authorized, false),
            (false, true, .notDetermined, false),
            (false, false, .denied, false),
            (true, true, .denied, false),
        ] {
            let suite = "DisasterPermissionCaption-\(UUID())"
            let storage = UserDefaults(suiteName: suite)!
            defer { storage.removePersistentDomain(forName: suite) }
            let model = try closureSwitchModel(storage: storage, permission: ClosurePermissionSpy(grants: false),
                                               usesNotificationAlarms: usesNotificationAlarms, savedOn: savedOn)
            XCTAssertEqual(model.closureAnnouncementsAreBlocked(notifications: status), warns,
                           "\(usesNotificationAlarms) \(savedOn) \(status)")
        }
    }

    // MARK: - Closure previews against the current feed (adversarial review, 2026-10-01)

    private func previewModel(storage: UserDefaults, previews: PreviewRecorder, provider: FeedStub,
                              scheduler: DisasterSchedulerSpy, previewTime: Date? = nil) throws -> AlarmViewModel {
        var value = settings()
        // Local 07:30: the plan, the previews and `inTwoDays` below all read the local calendar.
        let local = AlarmCalendarSettings.calendar
        value.alarmTime = local.date(bySettingHour: 7, minute: 30, second: 0, of: local.date(byAdding: .day, value: 1, to: Date())!)!
        if let previewTime { value.eveningPreviewTime = previewTime }
        try storage.set(JSONEncoder().encode(value), forKey: "commuteAlarmSettings")
        return AlarmViewModel(notificationScheduler: scheduler, previewScheduler: previews, settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: provider, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, updateDisasterPushRegistration: { _ in },
            supportsTemporaryClosures: true)
    }

    /// The preview names the feed's own update time, the one the card shows under a closure
    /// (DAYOFF-SPEC §7) — not the time the app fetched it. A date two Taipei days ahead (spec v4)
    /// puts the closure's preview on tomorrow evening whatever the time of day.
    func testTheClosurePreviewCarriesTheFeedsOwnUpdateTime() async throws {
        let suite = "DisasterPreviewSource-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let local = AlarmCalendarSettings.calendar
        let inTwoDays = try XCTUnwrap(local.date(bySettingHour: 7, minute: 30, second: 0,
            of: local.date(byAdding: .day, value: 2, to: Date())!))
        let now = Date()
        let sourceUpdated = now.addingTimeInterval(-25 * 60)
        var announced = DisasterFeed(checkedAt: now, sourceUpdatedAt: sourceUpdated, notices: [.init(id: "ahead", sentAt: now,
            description: "[停班停課通知]臺北市:\(DayOffPushContent.dayLabel(inTwoDays))停止上班、停止上課。行政院人事行政總處。",
            severity: "Extreme")])
        announced.revision = String(repeating: "c", count: 64)
        let previews = PreviewRecorder()
        let scheduler = DisasterSchedulerSpy()
        let model = try previewModel(storage: storage, previews: previews, provider: FeedStub(value: .success(announced)),
                                     scheduler: scheduler)
        _ = await model.refreshDisasterSuspensions(force: true)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(model.nextAppliedDisasterSkip?.normalDate, inTwoDays)

        let closure = try XCTUnwrap(previews.current.first {
            if case .closure(let day, _) = $0.kind { return day == inTwoDays }
            return false
        }, "\(previews.current.map(\.kind))")
        XCTAssertEqual(closure.kind, .closure(normalAlarmDate: inTwoDays, sourceUpdatedAt: sourceUpdated))
    }

    /// A re-registration that fails after the announcement was withdrawn keeps the old summary,
    /// skip included, and cancels the previews on purpose. A later re-plan from that summary (a
    /// new preview time, the 12/24-hour switch) must not bring back a closure preview crediting
    /// the very feed revision that withdrew it.
    func testAWithdrawnClosureIsNotPreviewedAfterAFailedReRegistration() async throws {
        let suite = "DisasterPreviewWithdrawn-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let now = Date()
        let previewTime = now.addingTimeInterval(30 * 60)
        try XCTSkipUnless(Calendar.current.isDate(previewTime, inSameDayAs: now), "Tonight's preview must still be ahead")
        let provider = FeedStub(value: .success(feed(now: now)))
        let previews = PreviewRecorder()
        let scheduler = DisasterSchedulerSpy()
        let model = try previewModel(storage: storage, previews: previews, provider: provider, scheduler: scheduler,
                                     previewTime: previewTime)
        _ = await model.refreshDisasterSuspensions(force: true)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertNotNil(model.nextAppliedDisasterSkip)
        XCTAssertTrue(previews.current.contains { if case .closure = $0.kind { return true }; return false },
                      "Committed and supported: previewed as a closure")

        var withdrawn = DisasterFeed(checkedAt: Date(), sourceUpdatedAt: Date(), notices: [])
        withdrawn.revision = String(repeating: "d", count: 64)
        await provider.set(.success(withdrawn))
        scheduler.fail = true
        _ = await model.refreshDisasterSuspensions(force: true)
        XCTAssertTrue(model.disasterScheduleNeedsAttention)
        XCTAssertNotNil(model.nextAppliedDisasterSkip, "The failed registration kept the old skip")
        XCTAssertTrue(previews.current.isEmpty, "The failure cancelled the previews")

        model.settings.timeFormat = model.settings.timeFormat == .twelveHour ? .twentyFourHour : .twelveHour
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(previews.current.contains { if case .closure = $0.kind { return true }; return false },
                       "\(previews.current.map(\.kind))")
    }

    /// 1.8.0 ships with the gate open; these tests inject it closed to keep proving
    /// what a gated build does with saved closure rules.
    func testClosedGateExcludesClosureWithoutErasingSavedRulesOrFetching() async throws {
        XCTAssertTrue(AppEnvironment.supportsTemporaryClosures, "1.8.0 ships temporary closures")
        let suite = "DeferredClosures-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let saved = settings()
        try storage.set(JSONEncoder().encode(saved), forKey: "commuteAlarmSettings")
        let provider = FeedStub(value: .success(feed(now: Date())))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter, membershipEntitlements: { nil },
            supportsTemporaryClosures: false)
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

    func testClosedGateRetriesOldClosureScheduleWithoutCancellingExistingAlarm() async throws {
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
            disasterFeedProvider: provider, membershipEntitlements: { nil }, supportsTemporaryClosures: false)
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

    // MARK: - Before the plan is known (adversarial review, 2026-10-01)

    /// Registers the next 07:30 alarm for a subscriber, so the closure rule is in the fingerprint.
    private func storeSubscriberRegistration(in storage: UserDefaults) async throws {
        let next = calendar.date(byAdding: .day, value: 1, to: Date())!
        var value = settings()
        value.alarmTime = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: next)!
        try storage.set(JSONEncoder().encode(value), forKey: "commuteAlarmSettings")
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            autoRefreshDebounce: .seconds(60),
            disasterFeedProvider: FeedStub(value: .success(.init(checkedAt: Date(), notices: []))),
            disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertFalse(model.isScheduleStale)
    }

    /// A background task or a push launch never reaches `MembershipManager.start()`, so the
    /// model saw no plan — and no plan passed the saved closure rule through, so a lapsed
    /// subscriber's alarm was still skipped for an announced closure. The rule only takes
    /// rings away: until a plan is confirmed, the alarm rings.
    func testWithoutAConfirmedPlanAnAnnouncedClosureDoesNotSkipTheAlarm() async throws {
        let suite = "DisasterUnconfirmedPlan-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try await storeSubscriberRegistration(in: storage)
        let provider = FeedStub(value: .success(feed(now: Date())))
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            disasterFeedProvider: provider, disasterSyncReporter: reporter,
            membershipEntitlements: { nil }, membershipConfigured: { true }, supportsTemporaryClosures: true)
        XCTAssertFalse(model.effectiveSchedulingSettings.isDisasterSuspensionEnabled)
        _ = await model.refreshScheduledAlarmUnattended()
        XCTAssertNil(model.nextAppliedDisasterSkip, "Nothing confirms the plan includes the rule, so the alarm must ring")
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertTrue(reporter.receipts.isEmpty, "Nothing was applied, so nothing is acknowledged")
        XCTAssertTrue(model.settings.isDisasterSuspensionEnabled, "The saved preference is kept for when a plan is confirmed")
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    /// The other half: the model is built before anything restores the plan (the app's first
    /// body, or an earlier run), so the background task, the push and the launch restore it
    /// before deciding. A subscriber keeps the closure, and the registration judged against no
    /// plan is judged again; a confirmed lapse, or nothing to restore, rings.
    func testTheRestoredPlanDecidesTheClosure() async throws {
        let lapsed = MembershipEntitlements(removeBanner: false, calendar: false, temporaryClosures: false,
            dailyAI: false, subscriptionActive: false, lifetimeActive: false, subscriptionExpiresAt: 1,
            subscriptionProductId: MembershipPlan.monthly.rawValue)
        final class Restore { var plan: MembershipEntitlements?; var count = 0 }
        let cases: [(plan: MembershipEntitlements?, skips: Bool)] = [(Self.closureEntitlements, true), (lapsed, false), (nil, false)]
        for (plan, skips) in cases {
            let suite = "DisasterRestoredPlan-\(UUID())"
            let storage = UserDefaults(suiteName: suite)!
            defer { storage.removePersistentDomain(forName: suite) }
            try await storeSubscriberRegistration(in: storage)
            let restore = Restore()
            let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
                disasterFeedProvider: FeedStub(value: .success(feed(now: Date()))),
                disasterSyncReporter: DisasterReceiptSpy(),
                membershipEntitlements: { restore.plan }, membershipConfigured: { true },
                restoreMembershipEntitlements: { restore.count += 1; restore.plan = plan },
                supportsTemporaryClosures: true)
            XCTAssertTrue(model.isScheduleStale, "Judged against no plan, the closure registration looks outdated")
            await model.loadMembershipEntitlements()
            XCTAssertEqual(restore.count, 1)
            XCTAssertEqual(model.isScheduleStale, !skips, "Judged again against the restored plan")
            _ = await model.refreshDisasterSuspensions(force: true)
            XCTAssertEqual(model.nextAppliedDisasterSkip?.noticeIDs, skips ? ["dgpa-test"] : nil)
            XCTAssertTrue(model.hasScheduledAlarm)
            XCTAssertTrue(model.settings.isDisasterSuspensionEnabled)
        }
    }

    /// Only a saved paid rule depends on the plan: without one nothing waits for StoreKit, which
    /// may have to fetch the App Transaction over a poor connection at 06:40 (adversarial review,
    /// 2026-10-01).
    func testOnlyASavedPaidRuleWaitsForThePlan() async throws {
        final class Restore { var count = 0 }
        for (closures, calendarRule, waits) in [(false, false, false), (true, false, true), (false, true, true)] {
            let suite = "DisasterRestoreGate-\(UUID())"
            let storage = UserDefaults(suiteName: suite)!
            defer { storage.removePersistentDomain(forName: suite) }
            var value = settings()
            value.isDisasterSuspensionEnabled = closures
            value.calendarSettings.isEnabled = calendarRule
            try storage.set(JSONEncoder().encode(value), forKey: "commuteAlarmSettings")
            let restore = Restore()
            let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
                membershipEntitlements: { nil }, membershipConfigured: { true },
                restoreMembershipEntitlements: { restore.count += 1 }, supportsTemporaryClosures: true)
            XCTAssertEqual(model.membershipPlanIsSettled, !closures, "Only a saved closure rule waits for the widget")
            await model.loadMembershipEntitlements()
            XCTAssertEqual(restore.count, waits ? 1 : 0, "closures \(closures), calendar \(calendarRule)")
            XCTAssertTrue(model.membershipPlanIsSettled)
        }
    }

    /// Adversarial review, 2026-10-01: the launch decided with no plan (a restored backup's
    /// keychain holds none, so the closure rule was dropped and the push unregistered), and the
    /// plan `start()` confirmed seconds later changed nothing until the next activation. A change
    /// of plan now re-decides at once: the push registration, and the alarm's closure skip.
    func testAPlanConfirmedAfterLaunchIsActedOnAtOnce() async throws {
        let suite = "DisasterPlanChange-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try await storeSubscriberRegistration(in: storage)
        final class Plan { var value: MembershipEntitlements?; var pushes: [Bool] = [] }
        let plan = Plan()
        let changes = PassthroughSubject<MembershipEntitlements?, Never>()
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            autoRefreshDebounce: .seconds(60),
            disasterFeedProvider: FeedStub(value: .success(feed(now: Date()))), disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { plan.value }, membershipConfigured: { true },
            restoreMembershipEntitlements: {}, membershipPlanChanges: changes.eraseToAnyPublisher(),
            updateDisasterPushRegistration: { plan.pushes.append($0) }, supportsTemporaryClosures: true)
        await model.loadMembershipEntitlements()
        XCTAssertTrue(model.isScheduleStale, "Decided with no plan: the closure rule is not applied")
        XCTAssertNil(model.nextAppliedDisasterSkip)

        plan.value = Self.closureEntitlements
        changes.send(plan.value)
        try await waitUntil("the confirmed plan applies the closure") { model.nextAppliedDisasterSkip != nil }
        XCTAssertEqual(model.nextAppliedDisasterSkip?.noticeIDs, ["dgpa-test"])
        XCTAssertEqual(plan.pushes, [true], "The push registration follows the plan without an activation")
        XCTAssertFalse(model.isScheduleStale)

        plan.value = nil
        changes.send(nil)
        try await waitUntil("the push registration follows the plan back") { plan.pushes == [true, false] }
    }

    // MARK: - Background and push entry points (adversarial review, 2026-10-01)

    /// Stores a subscriber's registration with the closure skip for tomorrow committed, then
    /// builds the model a cold background or push launch gets: no plan until it restores one.
    private func coldLaunchAfterACommittedClosure(storage: UserDefaults, restoring restored: MembershipEntitlements?,
                                                  provider: FeedStub) async throws -> AlarmViewModel {
        try await storeSubscriberRegistration(in: storage)
        let first = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: FeedStub(value: .success(feed(now: Date()))),
            disasterSyncReporter: DisasterReceiptSpy(), membershipEntitlements: { Self.closureEntitlements },
            updateDisasterPushRegistration: { _ in }, supportsTemporaryClosures: true)
        _ = await first.refreshDisasterSuspensions(force: true)
        XCTAssertEqual(first.nextAppliedDisasterSkip?.noticeIDs, ["dgpa-test"])
        final class Plan { var value: MembershipEntitlements? }
        let plan = Plan()
        return AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: provider, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { plan.value }, membershipConfigured: { true },
            restoreMembershipEntitlements: { plan.value = restored },
            updateDisasterPushRegistration: { _ in }, supportsTemporaryClosures: true)
    }

    /// A lapsed rule restored as lapsed rings; the restore has to come before this morning's
    /// check window, which a test cannot move.
    private func skipInsideTodaysRingWindow() throws {
        let local = AlarmCalendarSettings.calendar
        let now = Date()
        let start = local.date(bySettingHour: 6, minute: 55, second: 0, of: now)!
        let end = local.date(bySettingHour: 7, minute: 35, second: 0, of: now)!
        try XCTSkipIf(now >= start && now < end, "Inside this morning's 07:00–07:30 window a lapsed plan is applied later")
    }

    /// The background task restores the plan before it decides: a subscriber keeps the closure
    /// skip, and a plan that lapsed (or nothing to restore) rings.
    func testTheBackgroundTaskDecidesWithTheRestoredPlan() async throws {
        try skipInsideTodaysRingWindow()
        for (restored, keepsSkip) in [(Self.closureEntitlements, true), (nil, false)] as [(MembershipEntitlements?, Bool)] {
            let suite = "DisasterBackgroundPlan-\(UUID())"
            let storage = UserDefaults(suiteName: suite)!
            defer { storage.removePersistentDomain(forName: suite) }
            let model = try await coldLaunchAfterACommittedClosure(storage: storage, restoring: restored,
                                                                   provider: FeedStub(value: .success(feed(now: Date()))))
            final class Retired { var count = 0 }
            let retired = Retired()
            _ = await CommuteAlarmRefresher.refreshArmedAlarm(model: model, retireSupersededAlarms: { retired.count += 1 })
            XCTAssertEqual(retired.count, 1)
            XCTAssertTrue(model.hasScheduledAlarm)
            XCTAssertEqual(model.nextAppliedDisasterSkip?.noticeIDs, keepsSkip ? ["dgpa-test"] : nil, String(describing: restored))
        }
    }

    /// The day-off push does the same, and cancels a replaced alarm that has been stopped.
    func testTheDayOffPushDecidesWithTheRestoredPlan() async throws {
        let suite = "DisasterPushPlan-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        try await storeSubscriberRegistration(in: storage)
        final class Plan { var value: MembershipEntitlements?; var retired = 0 }
        let plan = Plan()
        let provider = FeedStub(value: .success(feed(now: Date())))
        let model = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: storage,
            autoRefreshDebounce: .seconds(60), disasterFeedProvider: provider, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { plan.value }, membershipConfigured: { true },
            restoreMembershipEntitlements: { plan.value = Self.closureEntitlements },
            updateDisasterPushRegistration: { _ in }, supportsTemporaryClosures: true)
        let result = await DisasterPushDelegate.handleDayOffSync(model: model, retireSupersededAlarms: { plan.retired += 1 })
        XCTAssertEqual(result, .newData)
        XCTAssertEqual(plan.retired, 1)
        XCTAssertEqual(model.nextAppliedDisasterSkip?.noticeIDs, ["dgpa-test"])

        // Nothing to restore: no plan, no closure rule, no fetch.
        let emptySuite = "DisasterPushNoPlan-\(UUID())"
        let emptyStorage = UserDefaults(suiteName: emptySuite)!
        defer { emptyStorage.removePersistentDomain(forName: emptySuite) }
        try await storeSubscriberRegistration(in: emptyStorage)
        let untouched = FeedStub(value: .success(feed(now: Date())))
        let unplanned = AlarmViewModel(notificationScheduler: DisasterSchedulerSpy(), settingsStorage: emptyStorage,
            disasterFeedProvider: untouched, disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { nil }, membershipConfigured: { true }, restoreMembershipEntitlements: {},
            updateDisasterPushRegistration: { _ in }, supportsTemporaryClosures: true)
        let unplannedResult = await DisasterPushDelegate.handleDayOffSync(model: unplanned, retireSupersededAlarms: {})
        XCTAssertEqual(unplannedResult, .noData)
        let calls = await untouched.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(unplanned.nextAppliedDisasterSkip)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting until \(what)", file: file, line: line)
    }

    // MARK: - Between an early ring and the normal time (adversarial review, 2026-09-29)

    /// Stores a dated registration made before this morning's early (rain) ring, which has
    /// since gone off: normal time ~10 minutes away, the ring 30 minutes before it.
    /// `dropped`: a registration inside the window already took that morning out of the plan.
    private func storeRungEarlyMorning(in storage: UserDefaults, dropped: Bool) throws -> Date {
        let now = Date()
        var value = settings()
        value.alarmTime = now.addingTimeInterval(10 * 60)
        value.rainLeadTimeMinutes = 30
        let normal = TomorrowWeatherRequest(settings: value, now: now).normalAlarmDate
        let early = normal.addingTimeInterval(-30 * 60)
        let registeredAt = early.addingTimeInterval(-5 * 60)
        try XCTSkipUnless(Calendar.current.isDate(registeredAt, inSameDayAs: normal) && Calendar.current.isDate(now, inSameDayAs: normal),
                          "The window must sit inside one calendar day")
        var plan = CalendarAlarmPlan.make(settings: value, holidays: .init(), rain: false, now: registeredAt,
                                          days: AlarmViewModel.calendarHorizonDays)
        XCTAssertEqual(plan.occurrences.first?.normalDate, normal)
        plan.occurrences[0].ringDate = early
        var summary: ScheduledAlarmSummary
        if dropped {
            plan.occurrences.removeFirst()
            let next = try XCTUnwrap(plan.occurrences.first)
            summary = ScheduledAlarmSummary(normalAlarmDate: next.normalDate, scheduledAlarmDate: next.ringDate,
                weatherRefreshDate: next.normalDate.addingTimeInterval(-30 * 60), exceedsRainThreshold: false,
                leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0, calendarPlan: plan)
            summary.firedEarlyRing = .init(normalDate: normal, ringDate: early)
        } else {
            summary = ScheduledAlarmSummary(normalAlarmDate: normal, scheduledAlarmDate: early, weatherRefreshDate: early,
                exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5,
                maximumPrecipitationProbability: 0.72, calendarPlan: plan, calendarForecastDate: normal)
        }
        summary.disasterSkips = []
        try storage.set(JSONEncoder().encode(value), forKey: "commuteAlarmSettings")
        try storage.set(JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        try storage.set(JSONEncoder().encode(value.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        storage.set(early.addingTimeInterval(-3_600), forKey: "lastWeatherEvaluationAt")
        return normal
    }

    /// registerCalendar dropped a morning that had already rung early only while the loaded
    /// summary still pointed at it. After a cold launch inside the window, rollingForward
    /// has moved the summary to tomorrow, so the next re-registration re-armed that
    /// morning's normal-time ring — a second ring. A second re-registration did the same,
    /// its `previous` being tomorrow's summary by then.
    func testReRegisteringAfterAColdLaunchPastAnEarlyRingDoesNotRingThatMorningAgain() async throws {
        let suite = "EarlyRingColdLaunch-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let normal = try storeRungEarlyMorning(in: storage, dropped: false)
        let early = normal.addingTimeInterval(-30 * 60)
        let scheduler = DisasterSchedulerSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            disasterFeedProvider: FeedStub(value: .success(.init(checkedAt: Date(), notices: []))),
            disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        XCTAssertGreaterThan(try XCTUnwrap(model.scheduledAlarmSummary).normalAlarmDate, normal,
                             "The cold launch rolled the summary past the ring that went off")
        for pass in 1...2 {
            await model.applyCalendarSettings()
            XCTAssertEqual(scheduler.calendarCalls, pass)
            let plan = try XCTUnwrap(scheduler.lastPlan)
            XCTAssertFalse(plan.occurrences.contains { $0.normalDate == normal },
                           "Registration \(pass) re-armed a morning that already rang early")
            XCTAssertEqual(model.scheduledAlarmSummary?.firedEarlyRing, .init(normalDate: normal, ringDate: early))
            XCTAssertTrue(model.tomorrowStatus().hasRung)
        }
    }

    /// The closure refresh compared its skips against a plan that still held a morning whose
    /// early ring had gone off. A "today" closure announced after that ring then looked new
    /// on every refresh until the normal time: a re-registration every five minutes, none of
    /// which could be acknowledged.
    func testAClosureAnnouncedAfterTheEarlyRingIsNotReappliedOnEveryRefresh() async throws {
        let suite = "EarlyRingClosure-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let normal = try storeRungEarlyMorning(in: storage, dropped: true)
        let scheduler = DisasterSchedulerSpy()
        let reporter = DisasterReceiptSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            disasterFeedProvider: FeedStub(value: .success(feed(now: Date(), target: "今天"))),
            disasterSyncReporter: reporter,
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        for _ in 1...2 { _ = await model.refreshDisasterSuspensions(force: true) }
        XCTAssertEqual(scheduler.calendarCalls, 0, "The morning already rang: nothing is left to skip or re-register")
        XCTAssertEqual(reporter.receipts.map(\.result), [.applied, .applied])
        XCTAssertNil(model.nextAppliedDisasterSkip)
        XCTAssertFalse(model.scheduledAlarmSummary?.calendarPlan?.occurrences.contains { $0.normalDate == normal } ?? true)
    }

    /// Owner decision, 2026-09-30: after the early ring, the dated plan's next alarm —
    /// tomorrow's — can be skipped at once; this morning's normal ring stays out.
    func testAfterAnEarlyRingTheNextDatedMorningCanBeSkippedAtOnce() async throws {
        let suite = "EarlyRingSkip-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let normal = try storeRungEarlyMorning(in: storage, dropped: false)
        let tomorrow = try XCTUnwrap(AlarmCalendarSettings.calendar.date(byAdding: .day, value: 1, to: normal))
        let scheduler = DisasterSchedulerSpy()
        let model = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            disasterFeedProvider: FeedStub(value: .success(.init(checkedAt: Date(), notices: []))),
            disasterSyncReporter: DisasterReceiptSpy(),
            membershipEntitlements: { Self.closureEntitlements }, supportsTemporaryClosures: true)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail("\(model.skipAvailability())") }
        XCTAssertEqual(target.normalDate, tomorrow)
        let skipped = await model.skipNextAlarm(target)
        XCTAssertTrue(skipped)
        let plan = try XCTUnwrap(scheduler.lastPlan)
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == normal || $0.normalDate == tomorrow })
        XCTAssertEqual(model.scheduledAlarmSummary?.firedEarlyRing?.normalDate, normal)
        XCTAssertEqual(model.scheduledAlarmSummary?.userSkippedNormalDate, tomorrow)
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
            membershipEntitlements: { nil }, supportsTemporaryClosures: false)
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

/// Notification permission as the closure switch sees it: undecided until the prompt
/// is shown, then whatever it was answered.
private final class ClosurePermissionSpy: EveningPreviewScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let grants: Bool
    private var status = EveningPreviewAuthorization.notDetermined
    private var storedRequests = 0
    private var requested: XCTestExpectation?
    init(grants: Bool) { self.grants = grants }

    var requests: Int { lock.withLock { storedRequests } }
    func onRequest(_ expectation: XCTestExpectation) { lock.withLock { requested = expectation } }

    func authorizationStatus() async -> EveningPreviewAuthorization { lock.withLock { status } }
    func requestAuthorization() async -> Bool {
        let requested: XCTestExpectation? = lock.withLock {
            storedRequests += 1
            status = grants ? .authorized : .denied
            return self.requested
        }
        requested?.fulfill()
        return grants
    }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

/// Authorized previews, as the notification centre would hold them: what was last planned,
/// emptied by a cancel.
private final class PreviewRecorder: EveningPreviewScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [EveningPreview] = []
    var current: [EveningPreview] { lock.withLock { stored } }
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async { lock.withLock { stored = previews } }
    func cancelPreviews() async { lock.withLock { stored = [] } }
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

/// Notification permission whose prompt stays up until the test answers it (Allow).
private final class GatedPermission: EveningPreviewScheduling, @unchecked Sendable {
    let gate = DisasterTestGate()
    private let lock = NSLock()
    private var status = EveningPreviewAuthorization.notDetermined
    func authorizationStatus() async -> EveningPreviewAuthorization { lock.withLock { status } }
    func requestAuthorization() async -> Bool {
        await gate.hold()
        lock.withLock { status = .authorized }
        return true
    }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
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
    /// The last dated plan the system accepted.
    var lastPlan: CalendarAlarmPlan?
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
        lastPlan = plan
        await beforeCalendarCompletion?()
    }
    func cancelScheduledAlarms() async { cancellations += 1 }
}
