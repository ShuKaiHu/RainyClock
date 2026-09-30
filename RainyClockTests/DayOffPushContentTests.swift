import XCTest
@testable import RainyClock

/// The notification service extension shows only what the alarm evaluator would
/// act on. Same fixtures' vocabulary, same evaluator, different surface.
final class DayOffPushContentTests: XCTestCase {
    private let calendar = DisasterNoticeParser.taipeiCalendar
    private let now = Date(timeIntervalSince1970: 1_789_470_000) // 2026-09-15 20:20 Asia/Taipei

    private func tomorrowAlarm() -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)!
    }

    private func state(enabled: Bool = true, work: Bool = true, school: Bool = true,
                       home: DisasterRegion? = DisasterRegion(county: "新竹縣", district: "尖石鄉"),
                       alarm: Date? = nil) -> DayOffSharedState {
        DayOffSharedState(enabled: enabled, observesWork: work, observesSchool: school, home: home, destination: nil,
                          normalAlarmDate: alarm ?? tomorrowAlarm(), serviceURL: URL(string: "https://example.invalid"), updatedAt: now)
    }

    private func feed(_ description: String, severity: String = "Extreme", geocodes: [String] = ["1000412"]) -> DisasterFeed {
        DisasterFeed(checkedAt: now, notices: [
            DisasterNotice(id: "n1", sentAt: now.addingTimeInterval(-60), description: description,
                           severity: severity, geocodes: geocodes),
        ])
    }

    func testMatchingSuspensionIsTimeSensitiveAndNamesTheArea() {
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。"), now: now, chinese: true)
        XCTAssertEqual(result.urgency, .matched)
        XCTAssertEqual(result.title, "新竹縣尖石鄉已公告停班停課")
    }

    func testSchoolOnlyMatchesWhenBothSwitchesAreOn() {
        // Spec v3: both switches on is an OR.
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]新竹縣尖石鄉:明天照常上班、停止上課。行政院人事行政總處。", severity: "Severe"),
            now: now, chinese: false)
        XCTAssertEqual(result.urgency, .matched)
        XCTAssertEqual(result.title, "新竹縣尖石鄉: closure announced")
    }

    /// Spec §7: the time-sensitive "your district is closed" notification names the source
    /// and the source's own update time (Taipei), in both languages.
    func testMatchedNotificationCreditsTheSourceAndItsUpdateTime() {
        var announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。")
        announcement.sourceUpdatedAt = now.addingTimeInterval(-120) // 2026-09-15 18:58 Asia/Taipei
        let zh = DayOffPushContent.evaluate(state: state(), feed: announcement, now: now, chinese: true)
        XCTAssertEqual(zh.urgency, .matched)
        XCTAssertEqual(zh.body, "下一次鬧鐘會依你的設定處理，打開 App 確認。\n資料來源：行政院人事行政總處（經 NCDR 發布），更新 9/15 18:58")
        let en = DayOffPushContent.evaluate(state: state(), feed: announcement, now: now, chinese: false)
        XCTAssertEqual(en.body, "Your next alarm will follow your settings. Open the app to confirm.\nSource: DGPA via NCDR, updated 9/15 18:58")
    }

    func testMatchedNotificationFallsBackToTheNoticeTimeWithoutAFeedUpdateTime() {
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。"), now: now, chinese: false)
        XCTAssertTrue(result.body.hasSuffix("Source: DGPA via NCDR, updated 9/15 18:59"), result.body)
    }

    func testEnglishRelatedNotificationContainsNoChineseReason() {
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。", geocodes: ["1000412-001"]),
            now: now, chinese: false)
        XCTAssertEqual(result.urgency, .related)
        XCTAssertEqual(result.body, "Only part of your district is closed, so your alarm stays on.\nSource: DGPA via NCDR")
        XCTAssertNil(result.body.range(of: #"\p{Han}"#, options: .regularExpression))
    }

    /// Spec §7, adversarial review 2026-10-01: "only part of your district is closed" relays an
    /// announcement for the user's own district as much as a match does, so it names the source
    /// and the source's update time too. It used to carry the reason alone.
    func testRelatedNotificationCreditsTheSourceAndItsUpdateTime() {
        var announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。", geocodes: ["1000412-001"])
        announcement.sourceUpdatedAt = now.addingTimeInterval(-120) // 2026-09-15 18:58 Asia/Taipei
        let zh = DayOffPushContent.evaluate(state: state(), feed: announcement, now: now, chinese: true)
        XCTAssertEqual(zh.urgency, .related)
        XCTAssertEqual(zh.body, "僅部分地區停班停課，維持原鬧鐘\n資料來源：行政院人事行政總處（經 NCDR 發布），更新 9/15 18:58")
        let en = DayOffPushContent.evaluate(state: state(), feed: announcement, now: now, chinese: false)
        XCTAssertEqual(en.urgency, .related)
        XCTAssertEqual(en.body, "Only part of your district is closed, so your alarm stays on.\nSource: DGPA via NCDR, updated 9/15 18:58")
    }

    func testNoNotificationTextPromisesTomorrow() {
        let announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。")
        for chinese in [true, false] {
            for body in [DayOffPushContent.evaluate(state: state(), feed: announcement, now: now, chinese: chinese).body,
                         DayOffPushContent.evaluate(state: nil, feed: announcement, now: now, chinese: chinese).body] {
                XCTAssertFalse(body.contains("明天") || body.lowercased().contains("tomorrow"), body)
            }
        }
    }

    func testAnnouncementForAnotherCountyIsSilent() {
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]宜蘭縣:明天停止上班、停止上課。行政院人事行政總處。", geocodes: ["10002"]),
            now: now, chinese: true)
        XCTAssertEqual(result.urgency, .unrelated)
        XCTAssertEqual(result.body, "與你設定的地區無關，鬧鐘照常。")
    }

    func testVillageLevelAnnouncementInformsWithoutClaimingASkip() {
        let result = DayOffPushContent.evaluate(
            state: state(), feed: feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。", geocodes: ["1000412-001"]),
            now: now, chinese: true)
        XCTAssertEqual(result.urgency, .related)
        XCTAssertEqual(result.body, "僅部分地區停班停課，維持原鬧鐘\n資料來源：行政院人事行政總處（經 NCDR 發布）")
    }

    func testMissingStateFeedOrFutureAlarmLeavesTheGenericFallback() {
        let announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。")
        XCTAssertEqual(DayOffPushContent.evaluate(state: nil, feed: announcement, now: now, chinese: true).urgency, .unknown)
        XCTAssertEqual(DayOffPushContent.evaluate(state: state(enabled: false), feed: announcement, now: now, chinese: true).urgency, .unknown)
        XCTAssertEqual(DayOffPushContent.evaluate(state: state(home: nil), feed: announcement, now: now, chinese: true).urgency, .unknown)
        XCTAssertEqual(DayOffPushContent.evaluate(state: state(), feed: nil, now: now, chinese: true).urgency, .unknown)
        XCTAssertEqual(DayOffPushContent.evaluate(state: state(alarm: now.addingTimeInterval(-60)), feed: announcement, now: now, chinese: true).urgency, .unknown)
    }

    func testSharedStateRoundTripsThroughDefaultsWithoutAnythingButDistricts() throws {
        let suite = "DayOffSharedStateTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = state()
        original.upcomingNormalAlarmDates = [tomorrowAlarm(), tomorrowAlarm().addingTimeInterval(86_400)]
        original.skippedNormalAlarmDates = [tomorrowAlarm()]
        original.save(to: defaults)
        XCTAssertEqual(DayOffSharedState.load(from: defaults), original)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(original), encoding: .utf8))
        for forbidden in ["token", "credential", "address", "route", "installationId"] {
            XCTAssertFalse(json.lowercased().contains(forbidden), forbidden)
        }
        DayOffSharedState.clear(from: defaults)
        XCTAssertNil(DayOffSharedState.load(from: defaults))
    }

    // MARK: - Repeat announcement for a day already skipped (device report 2026-09-28)

    private let tainan = DisasterRegion(county: "臺南市", district: "善化區")
    private let anding = DisasterRegion(county: "臺南市", district: "安定區")

    private func taipei(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func tainanFeed(sentAt: Date, checkedAt: Date) -> DisasterFeed {
        DisasterFeed(checkedAt: checkedAt, notices: [
            DisasterNotice(id: "tainan-0929", sentAt: sentAt,
                           description: "[停班停課通知]臺南市:明天停止上班、停止上課。行政院人事行政總處。",
                           severity: "Extreme", geocodes: ["67000"]),
        ])
    }

    /// What the app committed at 18:47 after verifying the 9/29 closure: weekdays 07:20,
    /// 9/29 filtered out of the plan and recorded as a disaster skip, 9/30 the next ring.
    private func summaryAfterSkippingTomorrow() -> ScheduledAlarmSummary {
        let ringing = [taipei(9, 30, 7, 20), taipei(10, 1, 7, 20), taipei(10, 2, 7, 20),
                       taipei(10, 5, 7, 20), taipei(10, 6, 7, 20), taipei(10, 7, 7, 20),
                       taipei(10, 8, 7, 20), taipei(10, 9, 7, 20)]
        let plan = CalendarAlarmPlan(occurrences: ringing.map { .init(normalDate: $0, ringDate: $0) },
                                     coveredUntil: taipei(10, 12, 0, 0), timeZoneID: "Asia/Taipei")
        var summary = ScheduledAlarmSummary(
            normalAlarmDate: ringing[0], scheduledAlarmDate: ringing[0],
            weatherRefreshDate: ringing[0].addingTimeInterval(-3_600), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0,
            calendarPlan: plan)
        summary.disasterSkips = [AppliedDisasterSkip(normalDate: taipei(9, 29, 7, 20), noticeIDs: ["tainan-0929"],
                                                     appliedAt: taipei(9, 28, 18, 47))]
        return summary
    }

    private func mirroredState(from summary: ScheduledAlarmSummary, at time: Date) -> DayOffSharedState {
        let dates = summary.dayOffAlarmDates(after: time)
        return DayOffSharedState(enabled: true, observesWork: true, observesSchool: true, home: tainan, destination: anding,
                                 normalAlarmDate: summary.normalAlarmDate, serviceURL: URL(string: "https://example.invalid"),
                                 updatedAt: time, upcomingNormalAlarmDates: dates.upcoming, skippedNormalAlarmDates: dates.skipped)
    }

    func testMirroredDatesIncludeTheSkippedDayAndStopAtTheLimit() {
        let dates = summaryAfterSkippingTomorrow().dayOffAlarmDates(after: taipei(9, 28, 18, 47))
        XCTAssertEqual(dates.skipped, [taipei(9, 29, 7, 20)])
        XCTAssertEqual(dates.upcoming.count, DayOffSharedState.upcomingDateLimit)
        XCTAssertEqual(Array(dates.upcoming.prefix(2)), [taipei(9, 29, 7, 20), taipei(9, 30, 7, 20)])
        XCTAssertEqual(dates.upcoming, dates.upcoming.sorted())
    }

    func testWeeklyScheduleWithoutAPlanMirrorsItsSingleNextDate() {
        let next = taipei(9, 29, 7, 20)
        let summary = ScheduledAlarmSummary(normalAlarmDate: next, scheduledAlarmDate: next, weatherRefreshDate: next,
                                            exceedsRainThreshold: false, leadTimeMinutes: 0, rainProbabilityThreshold: 0.5,
                                            maximumPrecipitationProbability: 0)
        let dates = summary.dayOffAlarmDates(after: taipei(9, 28, 18, 47))
        XCTAssertEqual(dates.upcoming, [next])
        XCTAssertEqual(dates.skipped, [])
    }

    func testRepeatAnnouncementForAnAlreadySkippedDayIsRecognisedQuietly() {
        let secondPush = taipei(9, 28, 23, 26)
        let state = mirroredState(from: summaryAfterSkippingTomorrow(), at: taipei(9, 28, 18, 47))
        // The bug: normalAlarmDate alone is 9/30, which the 9/29 announcement never matches.
        XCTAssertEqual(state.normalAlarmDate, taipei(9, 30, 7, 20))
        let feed = tainanFeed(sentAt: secondPush, checkedAt: secondPush.addingTimeInterval(30))
        let now = secondPush.addingTimeInterval(60)
        let zh = DayOffPushContent.evaluate(state: state, feed: feed, now: now, chinese: true)
        // Recognised as the user's closure, but not news: no sound at 23:26.
        XCTAssertEqual(zh.urgency, .alreadyApplied)
        XCTAssertEqual(zh.title, "臺南市已公告停班停課")
        XCTAssertEqual(zh.body, "9/29 當天的鬧鐘已略過。\n資料來源：行政院人事行政總處（經 NCDR 發布），更新 9/28 23:26")
        let en = DayOffPushContent.evaluate(state: state, feed: feed, now: now, chinese: false)
        XCTAssertEqual(en.urgency, .alreadyApplied)
        XCTAssertEqual(en.body, "9/29: that day's alarm has already been skipped.\nSource: DGPA via NCDR, updated 9/28 23:26")
        XCTAssertFalse(en.body.contains("rings as usual"))
    }

    func testFirstAnnouncementBeforeTheSkipKeepsTheFollowYourSettingsWording() {
        let firstPush = taipei(9, 28, 18, 43)
        var summary = summaryAfterSkippingTomorrow()
        summary.disasterSkips = nil
        summary.calendarPlan?.occurrences.insert(.init(normalDate: taipei(9, 29, 7, 20), ringDate: taipei(9, 29, 7, 20)), at: 0)
        summary.normalAlarmDate = taipei(9, 29, 7, 20)
        let state = mirroredState(from: summary, at: taipei(9, 28, 12, 0))
        let result = DayOffPushContent.evaluate(state: state, feed: tainanFeed(sentAt: firstPush, checkedAt: firstPush),
                                                now: firstPush.addingTimeInterval(60), chinese: true)
        XCTAssertEqual(result.urgency, .matched)
        XCTAssertTrue(result.body.hasPrefix("下一次鬧鐘會依你的設定處理，打開 App 確認。\n"), result.body)
    }

    func testAnnouncementForADayWithoutAnAlarmDoesNotMatch() {
        // Friday evening: "明天" is Saturday, and the weekday alarm next rings on Monday.
        let push = taipei(10, 2, 20, 0)
        let summary = summaryAfterSkippingTomorrow()
        let state = mirroredState(from: summary, at: taipei(10, 2, 8, 0))
        XCTAssertFalse(state.upcomingNormalAlarmDates!.contains { calendar.isDate($0, inSameDayAs: taipei(10, 3, 0, 0)) })
        let result = DayOffPushContent.evaluate(state: state, feed: tainanFeed(sentAt: push, checkedAt: push),
                                                now: push.addingTimeInterval(60), chinese: false)
        XCTAssertNotEqual(result.urgency, .matched)
        XCTAssertEqual(result.urgency, .unrelated)
    }

    func testStateWrittenBeforeTheNewFieldsStillDecodesAndUsesTheNextAlarmOnly() throws {
        let alarm = tomorrowAlarm()
        let old = #"{"enabled":true,"observesWork":true,"observesSchool":true,"home":{"county":"新竹縣","district":"尖石鄉"},"#
            + #""normalAlarmDate":\#(alarm.timeIntervalSinceReferenceDate),"serviceURL":"https:\/\/example.invalid","#
            + #""updatedAt":\#(now.timeIntervalSinceReferenceDate)}"#
        let decoded = try JSONDecoder().decode(DayOffSharedState.self, from: Data(old.utf8))
        XCTAssertNil(decoded.upcomingNormalAlarmDates)
        XCTAssertNil(decoded.skippedNormalAlarmDates)
        XCTAssertEqual(decoded, state())
        let announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。")
        let result = DayOffPushContent.evaluate(state: decoded, feed: announcement, now: now, chinese: true)
        XCTAssertEqual(result.urgency, .matched)
        XCTAssertTrue(result.body.hasPrefix("下一次鬧鐘會依你的設定處理"), result.body)
        XCTAssertEqual(DayOffPushContent.evaluate(
            state: decoded, feed: feed("[停班停課通知]宜蘭縣:明天停止上班、停止上課。行政院人事行政總處。", geocodes: ["10002"]),
            now: now, chinese: true).urgency, .unrelated)
    }

    func testANewClosureOutranksADayAlreadySkippedAndNamesItsDay() {
        let push = taipei(9, 28, 23, 26)
        let state = mirroredState(from: summaryAfterSkippingTomorrow(), at: taipei(9, 28, 18, 47))
        var feed = tainanFeed(sentAt: taipei(9, 28, 18, 43), checkedAt: push.addingTimeInterval(30))
        feed.notices.append(DisasterNotice(id: "tainan-0930", sentAt: push,
                                           description: "[停班停課通知]臺南市:9/30停止上班、停止上課。行政院人事行政總處。",
                                           severity: "Extreme", geocodes: ["67000"]))
        let zh = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: true)
        XCTAssertEqual(zh.urgency, .matched, "9/30 is new; it must ring even though 9/29 is already off")
        XCTAssertTrue(zh.body.hasPrefix("9/30 的鬧鐘會依你的設定處理"), zh.body)
        let en = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: false)
        XCTAssertTrue(en.body.hasPrefix("9/30: that day's alarm will follow your settings"), en.body)
    }

    func testAnotherCountysUpdateOnASkippedNightStaysQuiet() {
        let push = taipei(9, 29, 2, 10)
        let state = mirroredState(from: summaryAfterSkippingTomorrow(), at: taipei(9, 28, 18, 47))
        var feed = tainanFeed(sentAt: taipei(9, 28, 18, 43), checkedAt: push.addingTimeInterval(30))
        feed.notices.append(DisasterNotice(id: "yilan-0929", sentAt: push,
                                           description: "[停班停課通知]宜蘭縣:今天停止上班、停止上課。行政院人事行政總處。",
                                           severity: "Extreme", geocodes: ["10002"]))
        let result = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: true)
        XCTAssertEqual(result.urgency, .alreadyApplied, "Yilan's update must not wake a Tainan user whose day is already off")
    }

    func testASkippedNearestDayWithNothingSuppressingSaysNothingSpecific() {
        let push = taipei(9, 28, 23, 26)
        let state = mirroredState(from: summaryAfterSkippingTomorrow(), at: taipei(9, 28, 18, 47))
        // The Tainan notice is gone and only another county remains.
        let feed = DisasterFeed(checkedAt: push.addingTimeInterval(30), notices: [
            DisasterNotice(id: "yilan-0929", sentAt: push, description: "[停班停課通知]宜蘭縣:明天停止上班、停止上課。行政院人事行政總處。",
                           severity: "Extreme", geocodes: ["10002"]),
        ])
        let result = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: true)
        XCTAssertEqual(result.urgency, .unknown)
        XCTAssertFalse(result.body.contains("鬧鐘照常"), "9/29 is not armed; never say it rings")
    }

    func testPushMarkerRoundTripsThroughTheAppGroupDefaults() throws {
        let suite = "DayOffPushMarker-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(DayOffPushMarker.lastReceivedAt(from: defaults))
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        DayOffPushMarker.record(when, to: defaults)
        XCTAssertEqual(DayOffPushMarker.lastReceivedAt(from: defaults), when)
        XCTAssertNil(DayOffSharedState.load(from: defaults), "The marker must not touch the app-written state")
    }

    // MARK: - Adversarial review of the device-test fixes

    func testQuietResultsAreActuallySilentAndPassive() {
        for urgency in [DayOffPushContent.Urgency.unrelated, .alreadyApplied, .keptByUser, .alarmOff] {
            XCTAssertEqual(DayOffPushContent.presentation(for: urgency),
                           .init(playsSound: false, interruptionLevel: .passive), "\(urgency)")
        }
        XCTAssertEqual(DayOffPushContent.presentation(for: .matched), .init(playsSound: true, interruptionLevel: .timeSensitive))
        XCTAssertEqual(DayOffPushContent.presentation(for: .related), .init(playsSound: true, interruptionLevel: .active))
        XCTAssertNil(DayOffPushContent.presentation(for: .unknown), "Unknown leaves the server's generic text untouched")
    }

    /// A day the user set to ring anyway (a manual "ring" outranks a closure) is already
    /// decided. Every revision of a typhoon night must not break through Sleep Focus for it.
    func testADayTheUserKeptRingingStaysQuiet() {
        let push = taipei(9, 28, 23, 26)
        let state = DayOffSharedState(enabled: true, observesWork: true, observesSchool: true, home: tainan, destination: anding,
                                      normalAlarmDate: taipei(9, 29, 7, 20), serviceURL: URL(string: "https://example.invalid"),
                                      updatedAt: taipei(9, 28, 20, 0),
                                      upcomingNormalAlarmDates: [taipei(9, 29, 7, 20), taipei(9, 30, 7, 20)],
                                      skippedNormalAlarmDates: [], keptNormalAlarmDates: [taipei(9, 29, 7, 20)])
        let feed = tainanFeed(sentAt: push, checkedAt: push.addingTimeInterval(30))
        let zh = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: true)
        XCTAssertEqual(zh.urgency, .keptByUser)
        XCTAssertEqual(zh.title, "臺南市已公告停班停課")
        XCTAssertEqual(zh.body, "9/29 依你的設定照響。\n資料來源：行政院人事行政總處（經 NCDR 發布），更新 9/28 23:26")
        let en = DayOffPushContent.evaluate(state: state, feed: feed, now: push.addingTimeInterval(60), chinese: false)
        XCTAssertTrue(en.body.hasPrefix("9/29: your alarm rings as you set it."), en.body)
    }

    /// A night-shift alarm: 9/16 19:00 is already skipped for a full closure, and at 18:30 a
    /// village-level announcement arrives for 9/17. The day that will ring is the news.
    func testAPartialClosureForTheNextRingingDayOutranksARepeatForASkippedDay() {
        let skipped = taipei(9, 16, 19, 0), next = taipei(9, 17, 19, 0), push = taipei(9, 16, 18, 30)
        let state = DayOffSharedState(enabled: true, observesWork: true, observesSchool: true,
                                      home: DisasterRegion(county: "新竹縣", district: "尖石鄉"), destination: nil,
                                      normalAlarmDate: next, serviceURL: URL(string: "https://example.invalid"),
                                      updatedAt: taipei(9, 15, 20, 30),
                                      upcomingNormalAlarmDates: [skipped, next], skippedNormalAlarmDates: [skipped])
        let feed = DisasterFeed(checkedAt: push.addingTimeInterval(-30), notices: [
            DisasterNotice(id: "full-0916", sentAt: taipei(9, 15, 20, 19),
                           description: "[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。",
                           severity: "Extreme", geocodes: ["1000412"]),
            DisasterNotice(id: "partial-0917", sentAt: push.addingTimeInterval(-60),
                           description: "[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。",
                           severity: "Extreme", geocodes: ["1000412-001"]),
        ])
        let result = DayOffPushContent.evaluate(state: state, feed: feed, now: push, chinese: true)
        XCTAssertEqual(result.urgency, .related, result.body)
        XCTAssertEqual(result.body, "僅部分地區停班停課，維持原鬧鐘\n資料來源：行政院人事行政總處（經 NCDR 發布）")
    }

    func testStateWithoutKeptDatesDecodesAsNothingKept() throws {
        let json = #"{"enabled":true,"observesWork":true,"observesSchool":false,"updatedAt":0}"#
        let state = try JSONDecoder().decode(DayOffSharedState.self, from: Data(json.utf8))
        XCTAssertNil(state.keptNormalAlarmDates)
        XCTAssertFalse(state.isKeptRinging(Date(timeIntervalSinceReferenceDate: 0)))
    }

    // The service caches each snapshot for five seconds per instance, so the extension's
    // first read right after a broadcast can still be the previous revision.
    private func revisioned(_ revision: String?) -> DisasterFeed {
        var feed = DisasterFeed(checkedAt: now, notices: [])
        feed.revision = revision
        return feed
    }

    func testFeedMatchingThePushIsUsedWithoutWaiting() async {
        var fetches = 0, sleeps: [Duration] = []
        let feed = await DayOffPushContent.fetchFeed(matching: "new", fetch: { fetches += 1; return self.revisioned("new") },
                                                     sleep: { sleeps.append($0) })
        XCTAssertEqual(feed?.revision, "new")
        XCTAssertEqual(fetches, 1)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testAnOlderRevisionIsRetriedOnceAfterTheCacheExpires() async {
        var fetches = 0, sleeps: [Duration] = []
        let feed = await DayOffPushContent.fetchFeed(matching: "new", fetch: {
            fetches += 1
            return self.revisioned(fetches == 1 ? "old" : "new")
        }, sleep: { sleeps.append($0) })
        XCTAssertEqual(feed?.revision, "new")
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(sleeps, [.seconds(6)])
    }

    func testARevisionThatNeverMatchesFallsBackToTheGenericText() async {
        var fetches = 0
        let feed = await DayOffPushContent.fetchFeed(matching: "new", fetch: { fetches += 1; return self.revisioned("old") },
                                                     sleep: { _ in })
        XCTAssertNil(feed, "Evaluating the old revision could say 'not for your districts' about this very closure")
        XCTAssertEqual(fetches, 2)
    }

    func testAPushWithoutARevisionOrAFailedFetch() async {
        let taken = await DayOffPushContent.fetchFeed(matching: nil, fetch: { self.revisioned("any") }, sleep: { _ in })
        XCTAssertEqual(taken?.revision, "any")
        let failed = await DayOffPushContent.fetchFeed(matching: "new", fetch: { throw URLError(.timedOut) }, sleep: { _ in })
        XCTAssertNil(failed)
    }

    // MARK: - Master switch (1.8.0)

    func testAnAnnouncementWhileTheAlarmIsOffIsQuietEvenWithoutAFeed() {
        var state = mirroredState(from: summaryAfterSkippingTomorrow(), at: taipei(9, 28, 18, 47))
        state.alarmOff = true
        for feed in [nil, tainanFeed(sentAt: taipei(9, 28, 23, 26), checkedAt: taipei(9, 28, 23, 27))] as [DisasterFeed?] {
            let result = DayOffPushContent.evaluate(state: state, feed: feed, now: taipei(9, 28, 23, 28), chinese: true)
            XCTAssertEqual(result.urgency, .alarmOff)
            XCTAssertEqual(result.body, "你的鬧鐘目前關閉，這則公告不會改變鬧鐘。")
        }
    }

    /// The alarm is off whatever the closure rules say. No rule on, no district or the
    /// feature off must not fall back to the server's sounding "check your next alarm".
    func testAnAnnouncementWhileTheAlarmIsOffIsQuietEvenWithAnIncompleteSetup() {
        let announcement = feed("[停班停課通知]新竹縣尖石鄉:明天停止上班、停止上課。行政院人事行政總處。")
        for var incomplete in [state(work: false, school: false), state(home: nil), state(enabled: false)] {
            incomplete.alarmOff = true
            for fetched in [nil, announcement] as [DisasterFeed?] {
                let result = DayOffPushContent.evaluate(state: incomplete, feed: fetched, now: now, chinese: true)
                XCTAssertEqual(result.urgency, .alarmOff)
                XCTAssertEqual(result.body, "你的鬧鐘目前關閉，這則公告不會改變鬧鐘。")
            }
        }
    }

    /// The user turned off only 9/30. A closure for 9/30 is not news; another county's
    /// update is judged against the next armed day, not the loud generic text.
    func testAUserSkippedMorningIsHandledQuietly() {
        let push = taipei(9, 29, 20, 0)
        let state = DayOffSharedState(enabled: true, observesWork: true, observesSchool: true, home: tainan, destination: anding,
                                      normalAlarmDate: taipei(10, 1, 7, 20), serviceURL: URL(string: "https://example.invalid"),
                                      updatedAt: taipei(9, 29, 12, 0),
                                      upcomingNormalAlarmDates: [taipei(9, 30, 7, 20), taipei(10, 1, 7, 20)],
                                      skippedNormalAlarmDates: [], keptNormalAlarmDates: [],
                                      userSkippedNormalAlarmDates: [taipei(9, 30, 7, 20)])
        let closure = tainanFeed(sentAt: push, checkedAt: push.addingTimeInterval(30))
        XCTAssertEqual(DayOffPushContent.evaluate(state: state, feed: closure, now: push.addingTimeInterval(60), chinese: true).urgency,
                       .alreadyApplied)
        let yilan = DisasterFeed(checkedAt: push.addingTimeInterval(30), notices: [
            DisasterNotice(id: "yilan", sentAt: push, description: "[停班停課通知]宜蘭縣:明天停止上班、停止上課。行政院人事行政總處。",
                           severity: "Extreme", geocodes: ["10002"]),
        ])
        XCTAssertEqual(DayOffPushContent.evaluate(state: state, feed: yilan, now: push.addingTimeInterval(60), chinese: true).urgency,
                       .unrelated)
    }
}
