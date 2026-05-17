import XCTest
@testable import JackWeatherClock

final class AlarmTimeCalculatorTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    func testNormalAlarmUsesTodayWhenTimeIsStillAhead() {
        let now = date(year: 2026, month: 5, day: 17, hour: 6, minute: 45)
        let alarmTime = date(year: 2026, month: 5, day: 17, hour: 7, minute: 30)

        let summary = AlarmTimeCalculator.nextAlarmDate(
            alarmTime: alarmTime,
            leadTimeMinutes: 30,
            shouldApplyLeadTime: false,
            rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.2,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.normalAlarmDate, date(year: 2026, month: 5, day: 17, hour: 7, minute: 30))
        XCTAssertEqual(summary.scheduledAlarmDate, summary.normalAlarmDate)
        XCTAssertEqual(summary.weatherRefreshDate, date(year: 2026, month: 5, day: 17, hour: 7, minute: 0))
        XCTAssertEqual(summary.leadTimeMinutes, 0)
    }

    func testNormalAlarmRollsToTomorrowWhenTimeAlreadyPassed() {
        let now = date(year: 2026, month: 5, day: 17, hour: 8, minute: 0)
        let alarmTime = date(year: 2026, month: 5, day: 17, hour: 7, minute: 30)

        let summary = AlarmTimeCalculator.nextAlarmDate(
            alarmTime: alarmTime,
            leadTimeMinutes: 30,
            shouldApplyLeadTime: false,
            rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.2,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.normalAlarmDate, date(year: 2026, month: 5, day: 18, hour: 7, minute: 30))
        XCTAssertEqual(summary.scheduledAlarmDate, summary.normalAlarmDate)
        XCTAssertEqual(summary.weatherRefreshDate, date(year: 2026, month: 5, day: 18, hour: 7, minute: 0))
    }

    func testRainLeadTimeMovesScheduledAlarmEarlier() {
        let now = date(year: 2026, month: 5, day: 17, hour: 6, minute: 0)
        let alarmTime = date(year: 2026, month: 5, day: 17, hour: 7, minute: 30)

        let summary = AlarmTimeCalculator.nextAlarmDate(
            alarmTime: alarmTime,
            leadTimeMinutes: 30,
            shouldApplyLeadTime: true,
            rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.8,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.normalAlarmDate, date(year: 2026, month: 5, day: 17, hour: 7, minute: 30))
        XCTAssertEqual(summary.scheduledAlarmDate, date(year: 2026, month: 5, day: 17, hour: 7, minute: 0))
        XCTAssertEqual(summary.weatherRefreshDate, summary.scheduledAlarmDate)
        XCTAssertEqual(summary.leadTimeMinutes, 30)
    }

    func testRainLeadTimeDoesNotScheduleInThePast() {
        let now = date(year: 2026, month: 5, day: 17, hour: 7, minute: 15)
        let alarmTime = date(year: 2026, month: 5, day: 17, hour: 7, minute: 30)

        let summary = AlarmTimeCalculator.nextAlarmDate(
            alarmTime: alarmTime,
            leadTimeMinutes: 30,
            shouldApplyLeadTime: true,
            rainProbabilityThreshold: 0.5,
            maximumPrecipitationProbability: 0.8,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.weatherRefreshDate, date(year: 2026, month: 5, day: 17, hour: 7, minute: 0))
        XCTAssertEqual(summary.scheduledAlarmDate, now)
    }

    func testRouteWeatherThresholdUsesGreaterThanOrEqual() {
        let snapshot = RouteWeatherSnapshot(
            checkedAt: date(year: 2026, month: 5, day: 17, hour: 6, minute: 0),
            segments: [
                RouteWeatherSegment(name: "Segment A", condition: .cloudy, precipitationProbability: 0.49),
                RouteWeatherSegment(name: "Segment B", condition: .rain, precipitationProbability: 0.5)
            ]
        )

        XCTAssertTrue(snapshot.exceedsRainThreshold(0.5))
        XCTAssertEqual(snapshot.maximumPrecipitationProbability, 0.5)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
