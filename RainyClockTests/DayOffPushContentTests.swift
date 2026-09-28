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
        XCTAssertEqual(result.body, "Only part of your district is closed, so your alarm stays on.")
        XCTAssertNil(result.body.range(of: #"\p{Han}"#, options: .regularExpression))
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
        XCTAssertEqual(result.body, "僅部分地區停班停課，維持原鬧鐘")
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
        let original = state()
        original.save(to: defaults)
        XCTAssertEqual(DayOffSharedState.load(from: defaults), original)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(original), encoding: .utf8))
        for forbidden in ["token", "credential", "address", "route", "installationId"] {
            XCTAssertFalse(json.lowercased().contains(forbidden), forbidden)
        }
        DayOffSharedState.clear(from: defaults)
        XCTAssertNil(DayOffSharedState.load(from: defaults))
    }
}
