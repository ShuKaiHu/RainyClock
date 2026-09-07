import XCTest
@testable import RainyClock

/// The evening-before preview is planned from dates alone, so these pin the
/// dates: which evenings, which one carries the armed decision, and what is
/// left out.
final class EveningPreviewPlannerTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    // 2026-09-07 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func summary(normal: Date, rain: Bool, lead: Int = 30) -> ScheduledAlarmSummary {
        let scheduled = rain ? calendar.date(byAdding: .minute, value: -lead, to: normal)! : normal
        return ScheduledAlarmSummary(
            normalAlarmDate: normal,
            scheduledAlarmDate: scheduled,
            weatherRefreshDate: calendar.date(byAdding: .minute, value: -lead, to: normal)!,
            exceedsRainThreshold: rain,
            leadTimeMinutes: rain ? lead : 0,
            rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: rain ? 0.8 : 0.1
        )
    }

    private let weekdaysTueToFri: Set<Int> = [3, 4, 5, 6]

    func testOneEveningPerSelectedWeekdayInsideAWeek() {
        // Monday noon; Tue–Fri alarms at 7:00. Evenings: Mon, Tue, Wed, Thu.
        // Next Tuesday is day 8 from Monday and falls outside the horizon.
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 7), rain: true),
            selectedWeekdays: weekdaysTueToFri,
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        XCTAssertEqual(previews.map(\.fireDate), [date(7, 21), date(8, 21), date(9, 21), date(10, 21)])
        XCTAssertEqual(previews.map(\.identifier), [
            "commute-rain-preview-20260908",
            "commute-rain-preview-20260909",
            "commute-rain-preview-20260910",
            "commute-rain-preview-20260911"
        ])
    }

    func testOnlyTheArmedRingCarriesTheDecision() {
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 7), rain: true),
            selectedWeekdays: weekdaysTueToFri,
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        guard case let .decision(rain, normal, scheduled, lead, checkedAt) = previews[0].kind else {
            return XCTFail("first preview should carry the decision, got \(previews[0].kind)")
        }
        XCTAssertTrue(rain)
        XCTAssertEqual(normal, date(8, 7))
        XCTAssertEqual(scheduled, date(8, 6, 30))
        XCTAssertEqual(lead, 30)
        XCTAssertEqual(checkedAt, now)

        for later in previews.dropFirst() {
            guard case .upcoming = later.kind else {
                return XCTFail("later previews only announce the alarm, got \(later.kind)")
            }
        }
        if case let .upcoming(normal) = previews[1].kind {
            XCTAssertEqual(normal, date(9, 7))
        }
    }

    func testAnEveningAlreadyPastIsSkipped() {
        // Monday 21:30: tonight's preview is gone; Tuesday's is the first.
        let now = date(7, 21, 30)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 7), rain: false),
            selectedWeekdays: weekdaysTueToFri,
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        XCTAssertEqual(previews.first?.fireDate, date(8, 21))
        // Tuesday's ring is the armed one, but its preview is gone with the
        // evening, so nothing in the plan carries the decision.
        XCTAssertFalse(previews.contains { if case .decision = $0.kind { true } else { false } })
    }

    func testAnArmedRingSeveralDaysOutStillGetsItsDecisionOnItsOwnEve() {
        // Only Thursdays. Decided on Monday, previewed Wednesday night.
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(10, 7), rain: false),
            selectedWeekdays: [5],
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews[0].fireDate, date(9, 21))
        guard case let .decision(rain, _, _, lead, _) = previews[0].kind else {
            return XCTFail("expected the decision")
        }
        XCTAssertFalse(rain)
        XCTAssertEqual(lead, 0)
    }

    func testEveryDaySelectedGivesAWeekOfEvenings() {
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 7), rain: false),
            selectedWeekdays: CommuteAlarmSettings.allWeekdays,
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        // Tuesday through next Monday: seven alarms, seven evenings, and never
        // more — the notification budget is shared with the iOS 17–25 alarms.
        XCTAssertEqual(previews.count, 7)
        XCTAssertEqual(previews.last?.fireDate, date(13, 21))
    }

    func testBackgroundRefreshAvailabilityIsCarriedOnEveryPreview() {
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 7), rain: false),
            selectedWeekdays: weekdaysTueToFri,
            checkedAt: now,
            now: now,
            canRefreshInBackground: false,
            calendar: calendar
        )

        XCTAssertFalse(previews.isEmpty)
        XCTAssertTrue(previews.allSatisfy { !$0.canRefreshInBackground })
    }

    func testAnAlarmJustAfterMidnightIsPreviewedTheEveningBefore() {
        // 00:30 alarm on Tuesday: the eve is Monday 21:00, three and a half
        // hours ahead, which is still "the night before".
        let now = date(7, 12)
        let previews = EveningPreviewPlanner.plan(
            summary: summary(normal: date(8, 0, 30), rain: false),
            selectedWeekdays: [3],
            checkedAt: now,
            now: now,
            canRefreshInBackground: true,
            calendar: calendar
        )

        XCTAssertEqual(previews.map(\.fireDate), [date(7, 21)])
    }
}
