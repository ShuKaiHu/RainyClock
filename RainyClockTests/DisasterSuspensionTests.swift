import XCTest
@testable import RainyClock

final class DisasterSuspensionTests: XCTestCase {
    private let home = DisasterRegion(county: "臺北市", district: "士林區")
    private func date(_ value: String) -> Date { DisasterISO8601.date(value)! }
    private var now: Date { date("2026-09-15T06:00:00+08:00") }
    private var alarm: Date { date("2026-09-15T07:30:00+08:00") }
    private func notice(_ body: String = "明天停止上班、停止上課", id: String = "notice-1", area: String = "臺北市", sent: String = "2026-09-14T20:00:00+08:00", severity: String = "Extreme", type: String = "Alert", status: String = "Actual", references: [String] = []) -> DisasterNotice {
        DisasterNotice(id: id, sentAt: date(sent), description: "[停班停課通知]\(area):\(body)。行政院人事行政總處。", severity: severity, msgType: type, status: status, references: references)
    }
    private func decision(_ notices: [DisasterNotice], alarmDate: Date? = nil, checkedAt: Date? = nil, work: Bool = true, school: Bool = false) -> DisasterDecision {
        DisasterSuspensionEvaluator.decision(feed: .init(checkedAt: checkedAt ?? now, notices: notices), normalAlarmDate: alarmDate ?? alarm, now: now,
                                             home: home, destination: nil, observesWork: work, observesSchool: school)
    }

    private struct Fixtures: Decodable {
        struct Input: Decodable {
            var description: String; var severity: String; var msgType: String; var sentDate: String
            var geocode: String?
            func notice(id: String) -> DisasterNotice {
                DisasterNotice(id: id, sentAt: DisasterISO8601.date(sentDate + "+08:00")!, description: description,
                               severity: severity, msgType: msgType, geocodes: geocode.map { [$0] } ?? [])
            }
        }
        struct Parse: Decodable {
            struct Expect: Decodable { var area: String?; var targetDate: String; var dayPart: String; var work: String; var school: String }
            var id: String; var input: Input; var expect: Expect
        }
        struct Decision: Decodable {
            var id: String; var home: String; var work: String; var mode: String; var alarmDate: String
            var feed: [Input]?; var expect: String; var expectArea: String?; var expectStatus: String?
        }
        var specVersion: Int; var parseCases: [Parse]; var decisionCases: [Decision]
    }
    private func fixtures() throws -> Fixtures {
        let defaultURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/dayoff-fixtures.json")
        let url = ProcessInfo.processInfo.environment["DAYOFF_FIXTURES_PATH"].map { URL(fileURLWithPath: $0) } ?? defaultURL
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    private func region(_ fullName: String) -> DisasterRegion? {
        let normalized = DisasterRegion.normalize(fullName)
        guard let county = DisasterRegion.counties.first(where: { normalized.hasPrefix($0) }) else { return nil }
        return DisasterRegion(county: county, district: String(normalized.dropFirst(county.count)))
    }

    func testEverySharedSpecTwoParserFixture() throws {
        let fixtures = try fixtures()
        XCTAssertEqual(fixtures.specVersion, 2, "Review the shared contract before accepting a new version")
        XCTAssertEqual(fixtures.parseCases.count, 28)
        for example in fixtures.parseCases {
            let parsed = DisasterNoticeParser.parse(example.input.notice(id: example.id))
            XCTAssertEqual(parsed?.area, example.expect.area, example.id)
            guard example.expect.area != nil else { XCTAssertNil(parsed, example.id); continue }
            XCTAssertEqual(parsed?.targetDateToken, example.expect.targetDate, example.id)
            XCTAssertEqual(parsed?.dayPart.rawValue, example.expect.dayPart, example.id)
            XCTAssertEqual(parsed?.work.rawValue, example.expect.work, example.id)
            XCTAssertEqual(parsed?.school.rawValue, example.expect.school, example.id)
            XCTAssertTrue(parsed?.isRecognized == true, example.id)
        }
    }

    func testEverySharedSpecTwoDecisionFixture() throws {
        let fixtures = try fixtures()
        XCTAssertEqual(fixtures.decisionCases.count, 25)
        for example in fixtures.decisionCases {
            let alarm = date(example.alarmDate + "T07:30:00+08:00")
            let check = alarm.addingTimeInterval(-90 * 60)
            let feed = example.feed.map { inputs in
                DisasterFeed(checkedAt: check, notices: inputs.enumerated().map { $0.element.notice(id: "\(example.id)-\($0.offset)") })
            }
            let result = DisasterSuspensionEvaluator.decision(feed: feed, normalAlarmDate: alarm, now: check,
                home: region(example.home), destination: region(example.work), observesWork: example.mode != "school", observesSchool: example.mode != "work")
            XCTAssertEqual(result.shouldSkip, example.expect == "suppress", example.id)
            if let area = example.expectArea { XCTAssertEqual(result.area, area, example.id) }
            if let status = example.expectStatus { XCTAssertEqual(result.status, status, example.id) }
        }
    }

    func testFullDayMatchesOnlyItsSpecificDateAndIncludesAttribution() {
        let result = decision([notice()])
        XCTAssertTrue(result.shouldSkip)
        XCTAssertEqual(result.noticeIDs, ["notice-1"])
        XCTAssertEqual(result.area, "臺北市")
        XCTAssertEqual(result.sourceUpdatedAt, notice().sentAt)
        XCTAssertFalse(decision([notice()], alarmDate: alarm.addingTimeInterval(86_400)).shouldSkip)
    }

    func testMorningDoesNotSuppressAfternoonAlarmOrEarlierThanAnnouncedStart() {
        XCTAssertTrue(decision([notice("明天上午停止上班、停止上課")]).shouldSkip)
        XCTAssertFalse(decision([notice("明天上午停止上班、停止上課")], alarmDate: date("2026-09-15T13:00:00+08:00")).shouldSkip)
        XCTAssertFalse(decision([notice("明天上午8:00起停止上班、停止上課")]).shouldSkip)
        XCTAssertTrue(decision([notice("明天上午7:00起停止上班、停止上課")]).shouldSkip)
        XCTAssertFalse(decision([notice("明天停止上班、停止上課")], alarmDate: now).shouldSkip)
    }

    func testUnknownTestCancelSeverityConflictAndInvalidDatesPreserveAlarm() {
        let cases = [notice(status: "Test"), notice(type: "Cancel"), notice(type: "Ack"), notice(severity: "Severe"), notice(severity: "Unknown"),
                     notice("明天可能停止上班、停止上課"), notice("明天未達停止上班及上課標準", severity: "Severe"),
                     notice("9/31停止上班、停止上課"), notice("明天上午29:00起停止上班、停止上課"),
                     notice(area: "臺北市士林區永福里"), notice(area: "臺北市士林區某國小")]
        for value in cases { XCTAssertFalse(decision([value]).shouldSkip, value.description + value.status + value.msgType) }
    }

    func testFreshDownloadCannotMakeAnOldAnnouncementFresh() {
        XCTAssertFalse(decision([notice("今天停止上班、停止上課", sent: "2026-09-13T20:00:00+08:00")]).shouldSkip)
        XCTAssertFalse(decision([notice()], checkedAt: now.addingTimeInterval(-19 * 3_600)).shouldSkip)
        XCTAssertFalse(decision([notice()], checkedAt: now.addingTimeInterval(1)).shouldSkip)
        XCTAssertFalse(decision([notice("今天停止上班、停止上課", sent: "2026-09-15T06:01:00+08:00")]).shouldSkip)
        XCTAssertTrue(decision([notice("9/15停止上班、停止上課", sent: "2026-09-14T12:00:00+08:00")]).shouldSkip)
        XCTAssertFalse(decision([notice("9/15停止上班、停止上課", sent: "2026-09-14T11:59:59+08:00")]).shouldSkip)
        XCTAssertFalse(decision([notice("今天停止上班、停止上課")]).shouldSkip)
    }

    func testVillageGeocodeNeverBecomesAWholeDistrictSuspension() {
        var value = notice(area: home.name)
        value.geocodes = ["6301100-043"]
        XCTAssertFalse(decision([value]).shouldSkip)
        XCTAssertEqual(decision([value]).status, "partialDistrict")
        value.geocodes = ["unknown"]
        XCTAssertFalse(decision([value]).shouldSkip)
    }

    func testNewerNormalUnknownOrCancelOverridesOlderSuspension() {
        let old = notice()
        let variants = [notice("明天照常上班、照常上課", id: "new", sent: "2026-09-14T22:00:00+08:00", severity: "Severe"),
                        notice("明天請依後續公告", id: "new", sent: "2026-09-14T22:00:00+08:00"),
                        notice(id: "new", sent: "2026-09-14T22:00:00+08:00", type: "Cancel")]
        for value in variants { XCTAssertFalse(decision([old, value]).shouldSkip) }
        let cancellation = DisasterNotice(id: "cancel", sentAt: date("2026-09-14T22:00:00+08:00"), description: "撤銷", severity: "Minor", msgType: "Cancel", references: ["sender,notice-1,2026-09-14T20:00:00+08:00"])
        XCTAssertFalse(decision([old, cancellation]).shouldSkip)
    }

    func testNewerSpecificDistrictNormalOverridesCountySuspension() {
        let district = notice("明天照常上班、照常上課", id: "district", area: home.name, sent: "2026-09-14T22:00:00+08:00", severity: "Severe")
        XCTAssertFalse(decision([notice(), district]).shouldSkip)
    }

    func testEqualTimestampConflictAndNoSelectedPurposePreserveAlarm() {
        XCTAssertFalse(decision([notice(), notice("明天照常上班、照常上課", id: "conflict", severity: "Severe")]).shouldSkip)
        XCTAssertFalse(decision([notice()], work: false, school: false).shouldSkip)
    }

    func testDateResolutionUsesTaipeiAndRollsYearAcrossDecember() {
        let value = notice("1/1停止上班、停止上課", sent: "2026-12-31T20:00:00+08:00")
        XCTAssertEqual(DisasterNoticeParser.parse(value)?.targetDate, date("2027-01-01T00:00:00+08:00"))
        let utc = notice("明天停止上班、停止上課", sent: "2026-09-14T17:00:00Z")
        XCTAssertEqual(DisasterNoticeParser.parse(utc)?.targetDate, date("2026-09-16T00:00:00+08:00"))
    }

    func testJSONRoundTripUsesISO8601AndMalformedResponseCannotCreateSuppression() throws {
        let feed = DisasterFeed(checkedAt: now, sourceUpdatedAt: notice().sentAt, notices: [notice()])
        let encoded = try JSONEncoder().encode(feed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["checkedAt"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(DisasterFeed.self, from: encoded), feed)
        for bytes in [Data("<html>error</html>".utf8), Data(#"{"schemaVersion":1,"checkedAt":"not-a-date","notices":[]}"#.utf8)] {
            let decoded = try? JSONDecoder().decode(DisasterFeed.self, from: bytes)
            XCTAssertNil(decoded)
            XCTAssertFalse(DisasterSuspensionEvaluator.decision(feed: decoded, normalAlarmDate: alarm, now: now, home: home, destination: nil, observesWork: true, observesSchool: false).shouldSkip)
        }
        XCTAssertNotNil(DisasterISO8601.date("2026-09-15T06:00:00.123+08:00"))
        XCTAssertNil(DisasterISO8601.date("2026-09-15T06:00:00"))
    }

    func testUnconfiguredAndInsecureClientFailWithoutNetworkRequest() async {
        for endpoint in [nil, URL(string: "http://example.com/notices"), URL(string: "https://user:secret@example.com/notices")] {
            do {
                _ = try await DisasterFeedClient(endpoint: endpoint).fetch()
                XCTFail("Invalid endpoint must fail before any network request")
            } catch { XCTAssertTrue(error is DisasterFeedError) }
        }
    }
}
