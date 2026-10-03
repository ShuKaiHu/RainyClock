import XCTest
@testable import RainyClock

final class DisasterMapStatusTests: XCTestCase {
    private let region = DisasterRegion(county: "臺北市", district: "士林區")
    private func date(_ value: String) -> Date { DisasterISO8601.date(value)! }
    private var now: Date { date("2026-09-15T18:00:00+08:00") }
    private var today: Date { date("2026-09-15T00:00:00+08:00") }

    private func notice(_ body: String = "明天停止上班、停止上課", id: String = "county", area: String = "臺北市",
                        sent: String = "2026-09-14T20:00:00+08:00", severity: String = "Extreme",
                        type: String = "Alert", status: String = "Actual", codes: [String] = [], references: [String] = []) -> DisasterNotice {
        .init(id: id, sentAt: date(sent), description: "[停班停課通知]\(area):\(body)。行政院人事行政總處。",
              severity: severity, msgType: type, status: status, geocodes: codes, references: references)
    }

    private func resolve(_ notices: [DisasterNotice], date target: Date? = nil, checkedAt: Date? = nil,
                         sourceFailed: Bool = false) -> DisasterMapStatus {
        .resolve(region: region, date: target ?? today,
            feed: .init(checkedAt: checkedAt ?? now, notices: notices), now: now, sourceFailed: sourceFailed)
    }

    func testCurrentDayRemainsVisibleAfterWakeTimeAndEighteenHoursSinceAnnouncement() {
        let result = resolve([notice()])
        XCTAssertEqual(result.state, .closed)
        XCTAssertEqual(result.latestNotice?.id, "county")
        XCTAssertEqual(result.work, .suspended)
        XCTAssertEqual(result.school, .suspended)
    }

    func testExplicitNormalAndIndependentWorkSchoolStatuses() {
        XCTAssertEqual(resolve([notice("明天照常上班、照常上課", severity: "Severe")]).state, .normal)
        XCTAssertEqual(resolve([notice("明天停止上班、照常上課")]).state, .workOnly)
        XCTAssertEqual(resolve([notice("明天照常上班、停止上課", severity: "Severe")]).state, .schoolOnly)
        XCTAssertEqual(resolve([]).state, .unknown)
        XCTAssertEqual(resolve([notice("明天尚未宣布消息", severity: "Minor")]).state, .unknown)
        XCTAssertEqual(resolve([notice(area: "高雄市")]).state, .unknown)
    }

    func testPartialTimesRemainPartialRegardlessOfCurrentHourAndKeepOriginalWording() {
        for body in ["明天上午停止上班、停止上課", "明天下午停止上班、停止上課", "明天晚上8:00起停止上班、停止上課", "明天13:00起停止上班、停止上課"] {
            let value = notice(body)
            let result = resolve([value])
            XCTAssertEqual(result.state, .partial, body)
            XCTAssertEqual(result.reason, .partialTime, body)
            XCTAssertEqual(result.latestNotice?.description, value.description)
        }
        let evening = resolve([notice("明天晚上8:00起停止上班、停止上課")])
        XCTAssertEqual(evening.dayPart, .evening)
        XCTAssertEqual(evening.startsAtMinute, 20 * 60)
    }

    func testVillageNoticesAndNarrowGeocodesNeverColorWholeAreaClosed() {
        for value in [notice(area: region.name + "永福里"), notice(area: region.name, codes: ["6301100-043"]),
                      notice(area: "臺北市", codes: ["6301100"])] {
            XCTAssertEqual(resolve([value]).state, .partial)
            XCTAssertEqual(resolve([value]).reason, .partialArea)
        }
        XCTAssertEqual(resolve([notice(area: "臺北市北投區永福里")]).state, .unknown)
        XCTAssertEqual(resolve([notice(codes: ["bad-code"])]).state, .unknown)
    }

    func testNewerDistrictNoticeOverridesCountyAndMalformedLatestNeverFallsBack() {
        let old = notice()
        let district = notice("今天照常上班、照常上課", id: "district", area: region.name, sent: "2026-09-15T08:00:00+08:00", severity: "Severe")
        XCTAssertEqual(resolve([old, district]).state, .normal)
        let malformed = notice("今天請依後續公告", id: "pending", area: region.name, sent: "2026-09-15T09:00:00+08:00")
        XCTAssertEqual(resolve([old, district, malformed]).state, .unknown)
        XCTAssertEqual(resolve([old, district, malformed]).latestNotice?.id, "pending")
    }

    func testCancellationReferencesAndUpdatesPreventFallingBackToOlderPositiveNotice() {
        let old = notice()
        let district = notice("今天停止上班、停止上課", id: "district", area: region.name, sent: "2026-09-15T08:00:00+08:00")
        let cancellation = DisasterNotice(id: "cancel", sentAt: date("2026-09-15T09:00:00+08:00"), description: "撤銷",
            severity: "Minor", msgType: "Cancel", references: ["sender,district,2026-09-15T08:00:00+08:00"])
        let result = resolve([old, district, cancellation])
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, .withdrawn)
        XCTAssertEqual(result.latestNotice?.id, "cancel")
        let update = notice("今天照常上班、照常上課", id: "update", area: region.name,
            sent: "2026-09-15T10:00:00+08:00", severity: "Severe", type: "Update", references: ["district"])
        XCTAssertEqual(resolve([old, district, update]).state, .normal)
        let chainedUpdate = DisasterNotice(id: "chained", sentAt: date("2026-09-15T10:00:00+08:00"),
            description: "內容待確認", severity: "Minor", msgType: "Update", references: ["cancel"])
        let chained = resolve([old, district, cancellation, chainedUpdate])
        XCTAssertEqual(chained.state, .unknown)
        XCTAssertEqual(chained.latestNotice?.id, "chained")
    }

    func testEqualTimestampConflictRetainsAnInspectableNoticeAndExactDuplicatesAreHarmless() {
        let closed = notice()
        let normal = notice("明天照常上班、照常上課", id: "normal", severity: "Severe")
        let conflict = resolve([closed, normal])
        XCTAssertEqual(conflict.state, .unknown)
        XCTAssertEqual(conflict.reason, .conflict)
        XCTAssertNotNil(conflict.latestNotice)
        XCTAssertEqual(resolve([closed, closed]).state, .closed)
    }

    func testFailedStaleFutureOrInvalidSourcesNeverProduceGreenOrRed() {
        XCTAssertEqual(resolve([notice()], sourceFailed: true).reason, .sourceUnavailable)
        // The poll runs every 30 minutes, so a feed is routinely half an hour old.
        XCTAssertEqual(resolve([notice()], checkedAt: now.addingTimeInterval(-3600)).state, .closed)
        XCTAssertEqual(resolve([notice()], checkedAt: now.addingTimeInterval(-3601)).reason, .stale)
        XCTAssertEqual(resolve([notice()], checkedAt: now.addingTimeInterval(1)).reason, .invalid)
        XCTAssertEqual(resolve([notice("今天停止上班、停止上課", sent: "2026-09-15T18:01:00+08:00")]).state, .unknown)
        XCTAssertEqual(resolve([notice("9/15停止上班、停止上課", sent: "2026-09-13T20:00:00+08:00")]).state, .unknown)
        XCTAssertEqual(resolve([notice(status: "Test")]).state, .unknown)
        XCTAssertEqual(resolve([notice(severity: "Severe")]).state, .unknown)
        XCTAssertEqual(resolve([notice("9/31停止上班、停止上課")]).state, .unknown)
    }

    func testTodayTomorrowAreSeparateAndDatesUseTaipeiMidnight() {
        let tomorrowNotice = notice(sent: "2026-09-15T16:00:00+08:00")
        XCTAssertEqual(resolve([tomorrowNotice]).state, .unknown)
        XCTAssertEqual(resolve([tomorrowNotice], date: date("2026-09-16T12:00:00+08:00")).state, .closed)
        XCTAssertEqual(resolve([notice()], date: date("2026-09-17T00:00:00+08:00")).state, .unknown)
        let newYearNow = date("2027-01-01T16:00:00+08:00")
        let yearNotice = notice("1/1停止上班、停止上課", sent: "2026-12-31T20:00:00+08:00")
        XCTAssertEqual(DisasterMapStatus.resolve(region: region, date: newYearNow,
            feed: .init(checkedAt: newYearNow, notices: [yearNotice]), now: newYearNow, sourceFailed: false).state, .closed)
    }

    func testWholeMapSharesParsingAndMatchesIndividualResults() {
        let regions = [region, DisasterRegion(county: "臺北市", district: "北投區"),
                       DisasterRegion(county: "高雄市", district: "左營區"), region]
        let feed = DisasterFeed(checkedAt: now, notices: [notice(),
            notice("今天照常上班、照常上課", id: "district", area: region.name,
                sent: "2026-09-15T08:00:00+08:00", severity: "Severe")])
        let bulk = DisasterMapStatus.resolve(regions: regions, date: today, feed: feed, now: now, sourceFailed: false)
        XCTAssertEqual(bulk.count, 3)
        for region in regions {
            XCTAssertEqual(bulk[region], DisasterMapStatus.resolve(region: region, date: today, feed: feed, now: now, sourceFailed: false))
        }
        XCTAssertEqual(bulk[regions[0]]?.state, .normal)
        XCTAssertEqual(bulk[regions[1]]?.state, .closed)
        XCTAssertEqual(bulk[regions[2]]?.state, .unknown)
    }
}
