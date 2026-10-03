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
    private func decision(_ notices: [DisasterNotice], alarmDate: Date? = nil, checkedAt: Date? = nil, at time: Date? = nil, work: Bool = true, school: Bool = false) -> DisasterDecision {
        DisasterSuspensionEvaluator.decision(feed: .init(checkedAt: checkedAt ?? time ?? now, notices: notices), normalAlarmDate: alarmDate ?? alarm, now: time ?? now,
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
            /// Spec v4: when the decision is made and when the feed copy was fetched, Taipei local
            /// time like `sentDate`. Absent: 06:00 on the alarm day, and the evaluation time.
            var evaluatedAt: String?; var checkedAt: String?
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
        XCTAssertEqual(fixtures.specVersion, 4, "Review the shared contract before accepting a new version")
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
        XCTAssertEqual(fixtures.decisionCases.count, 33)
        for example in fixtures.decisionCases {
            let alarm = date(example.alarmDate + "T07:30:00+08:00")
            let check = example.evaluatedAt.map { date($0 + "+08:00") } ?? alarm.addingTimeInterval(-90 * 60)
            let fetched = example.checkedAt.map { date($0 + "+08:00") } ?? check
            let feed = example.feed.map { inputs in
                DisasterFeed(checkedAt: fetched, notices: inputs.enumerated().map { $0.element.notice(id: "\(example.id)-\($0.offset)") })
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
        // Spec v4: a notice naming 9/15 is judged by how far ahead of 9/15 it was sent, not by
        // its age at 06:00 (v3 rejected this one at 18 h 1 s). Two days ahead is the limit.
        XCTAssertTrue(decision([notice("9/15停止上班、停止上課", sent: "2026-09-14T11:59:59+08:00")]).shouldSkip)
        XCTAssertTrue(decision([notice("9/15停止上班、停止上課", sent: "2026-09-13T00:00:00+08:00")]).shouldSkip)
        // Three days ahead is further than the app acts on (P5) — said as such, not as "out of
        // date": the push relays the reason, and the notice may be a minute old.
        let threeDaysAhead = decision([notice("9/15停止上班、停止上課", sent: "2026-09-12T23:59:59+08:00")])
        XCTAssertFalse(threeDaysAhead.shouldSkip)
        XCTAssertEqual(threeDaysAhead.reason, "公告日期超出可判斷範圍，維持原鬧鐘")
        // A frozen archive's year-rolled date: "9/15" sent in October resolves to next year's 9/15.
        let archived = notice("9/15停止上班、停止上課", sent: "2025-10-01T20:00:00+08:00")
        XCTAssertEqual(DisasterNoticeParser.parse(archived)?.targetDate, date("2026-09-15T00:00:00+08:00"))
        XCTAssertFalse(decision([archived]).shouldSkip)
        XCTAssertFalse(decision([notice("今天停止上班、停止上課")]).shouldSkip)
        // A notice naming no day never suppresses and still ages out after 18 h, so an old
        // "尚未宣布消息" cannot keep the district reading as undeclared. Aged out it is no
        // announcement at all (adversarial review, 2026-10-01): the NCDR feed never empties,
        // and read as "expired" it made every later push about any county sound for this user.
        let undeclared = notice("尚未宣布消息", sent: "2026-09-14T12:00:00+08:00", severity: "Minor")
        XCTAssertEqual(decision([undeclared]).status, "undeclared")
        let agedOut = decision([undeclared], at: date("2026-09-15T06:00:01+08:00"))
        XCTAssertFalse(agedOut.shouldSkip)
        XCTAssertEqual(agedOut.status, "noAnnouncement")
        // With an older dated notice for this day behind it, it still hides that one (P5).
        let dated = notice(id: "dated", sent: "2026-09-14T11:00:00+08:00")
        let hidden = decision([dated, undeclared], at: date("2026-09-15T06:00:01+08:00"))
        XCTAssertFalse(hidden.shouldSkip)
        XCTAssertEqual(hidden.reason, "公告已過期或時間異常，維持原鬧鐘")
    }

    /// Adversarial review, 2026-10-01: a 12:00 "明天" skipped tomorrow 07:30, and from 06:00 —
    /// when it turned 18 h old — every refresh put the alarm back on a confirmed day off.
    func testNoonAnnouncementStaysValidThroughTheMorningItNames() {
        let noon = notice(sent: "2026-09-14T12:00:00+08:00")
        for time in ["2026-09-14T12:05:00+08:00", "2026-09-15T06:00:01+08:00", "2026-09-15T07:29:00+08:00"] {
            let result = decision([noon], at: date(time))
            XCTAssertTrue(result.shouldSkip, time)
            XCTAssertEqual(result.noticeIDs, ["notice-1"], time)
        }
        // What still expires is the download: a copy from 12:30 the day before cannot show
        // that nothing newer has replaced the notice by 06:31.
        XCTAssertFalse(decision([noon], checkedAt: date("2026-09-14T12:30:00+08:00"), at: date("2026-09-15T06:31:00+08:00")).shouldSkip)
    }

    /// Dates announced days ahead: 9/16 announced on the evening of 9/14 holds until the 9/16
    /// alarm instead of lapsing at 14:00 on 9/15, and still covers no other day.
    func testExplicitDateAnnouncedDaysAheadStaysValidUntilThatDay() {
        let alarm = date("2026-09-16T07:30:00+08:00")
        let ahead = notice("9/16停止上班、停止上課", sent: "2026-09-14T20:00:00+08:00")
        for time in ["2026-09-14T20:05:00+08:00", "2026-09-15T14:01:00+08:00", "2026-09-16T07:00:00+08:00"] {
            XCTAssertTrue(decision([ahead], alarmDate: alarm, at: date(time)).shouldSkip, time)
        }
        XCTAssertFalse(decision([ahead], at: date("2026-09-15T06:00:00+08:00")).shouldSkip)
        XCTAssertFalse(decision([ahead], alarmDate: date("2026-09-17T07:30:00+08:00"), at: date("2026-09-16T08:00:00+08:00")).shouldSkip)
        // A newer notice for the same day still wins.
        let reversal = notice("9/16照常上班、照常上課", id: "later", sent: "2026-09-15T21:00:00+08:00", severity: "Severe")
        XCTAssertFalse(decision([ahead, reversal], alarmDate: alarm, at: date("2026-09-16T06:00:00+08:00")).shouldSkip)
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

/// The day-off service follows how APNs is signed: every DEBUG build carries an APNs
/// development token and so uses the sandbox stack; Release uses production. The membership
/// sandbox rule (launch arguments, the Debug Sandbox build) plays no part.
final class DayOffServiceConfigurationTests: XCTestCase {
    private let production = "https://rainyclock-dayoff-510427696731.asia-east1.run.app"
    private let sandbox = "https://rainyclock-dayoff-sandbox-510427696731.asia-east1.run.app"

    func testAPNsProductionBuildUsesTheProductionOrigin() {
        XCTAssertEqual(AppEnvironment.resolvedDayOffServiceURL(productionValue: production, sandboxValue: sandbox,
            apnsSandbox: false)?.absoluteString, production)
    }

    func testAPNsSandboxBuildUsesTheSandboxOrigin() {
        XCTAssertEqual(AppEnvironment.resolvedDayOffServiceURL(productionValue: production, sandboxValue: sandbox,
            apnsSandbox: true)?.absoluteString, sandbox)
    }

    func testBlankOrUnsafeProductionValueLeavesTheFeatureUnconfigured() {
        for raw in [nil, "", "http://rainyclock-dayoff.example.com", "https://user:secret@rainyclock-dayoff.example.com",
                    "https://rainyclock-dayoff.example.com/v1/suspensions", "https://rainyclock-dayoff.example.com?x=1"] {
            XCTAssertNil(AppEnvironment.resolvedDayOffServiceURL(productionValue: raw, sandboxValue: sandbox,
                apnsSandbox: false), raw ?? "nil")
        }
    }

    func testMissingOrMalformedSandboxValueCannotFallBackToProduction() {
        for raw in [nil, "", "http://sandbox.example.com", "https://sandbox.example.com/path"] {
            XCTAssertNil(AppEnvironment.resolvedDayOffServiceURL(productionValue: production, sandboxValue: raw,
                apnsSandbox: true), raw ?? "nil")
        }
    }

    func testBundleOriginsAreBareHTTPSOriginsTheExtensionCanAppendTo() throws {
        for (apnsSandbox, origin) in [(false, production), (true, sandbox)] {
            let url = try XCTUnwrap(AppEnvironment.resolvedDayOffServiceURL(productionValue: production,
                sandboxValue: sandbox, apnsSandbox: apnsSandbox))
            XCTAssertEqual(url.appendingPathComponent("v1/suspensions").absoluteString, origin + "/v1/suspensions")
        }
    }

    func testXCTestHostNeverReceivesAServiceURL() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
        XCTAssertNil(AppEnvironment.dayOffServiceURL)
    }

    #if DEBUG
    /// Plain Debug, Membership Local, the sandbox launch argument and the installed Debug
    /// Sandbox build are all signed `aps-environment = development`: none may reach production.
    func testEveryDebugBuildUsesTheSandboxOrigin() {
        XCTAssertTrue(AppEnvironment.usesAPNsSandbox)
        XCTAssertEqual(AppEnvironment.resolvedDayOffServiceURL(productionValue: production,
            sandboxValue: sandbox)?.absoluteString, sandbox)
        XCTAssertNil(AppEnvironment.resolvedDayOffServiceURL(productionValue: production, sandboxValue: nil))
    }
    #else
    func testReleaseUsesTheProductionOrigin() {
        XCTAssertFalse(AppEnvironment.usesAPNsSandbox)
        XCTAssertEqual(AppEnvironment.resolvedDayOffServiceURL(productionValue: production,
            sandboxValue: sandbox)?.absoluteString, production)
    }
    #endif
}
