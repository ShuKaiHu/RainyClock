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
    /// A dated (calendar) registration: (normal, ring) pairs plus the committed closure skips.
    private func planSummary(_ occurrences: [(Date, Date)], skips: [AppliedDisasterSkip] = [],
                             coveredUntil: Date) -> ScheduledAlarmSummary {
        let first = occurrences.first ?? (coveredUntil, coveredUntil)
        var value = summary(normal: first.0, ring: first.1)
        value.calendarPlan = .init(occurrences: occurrences.map { .init(normalDate: $0.0, ringDate: $0.1) },
            coveredUntil: coveredUntil, timeZoneID: calendar.timeZone.identifier)
        value.disasterSkips = skips.isEmpty ? nil : skips
        return value
    }
    private func closureSettings() -> CommuteAlarmSettings {
        var value = settings()
        value.isDisasterSuspensionEnabled = true
        value.homeSuspensionRegion = .init(county: "臺北市", district: "信義區")
        return value
    }
    private func taipeiClosure(id: String, sentAt: Date, checkedAt: Date, day: String) -> DisasterFeed {
        DisasterFeed(checkedAt: checkedAt, notices: [.init(id: id, sentAt: sentAt,
            description: "[停班停課通知]臺北市:\(day)停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")])
    }

    // The tests above the "coming morning" section run at 18:00 or 20:00, past the 07:30
    // normal time, so they also pin the card's tomorrow branch.

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

    /// D-D: after an early ring the weekly repeat rings at the same early time the next
    /// morning. That time is what AlarmKit will do, so it stays; what it must not claim is
    /// that rain moved it, until a forecast for that morning decides.
    @MainActor
    func testCarriedOverRainLeadKeepsRegisteredTimeWithoutClaimingRain() {
        let value = settings()
        // Decided Monday evening for Tuesday: rain moved Tuesday's 07:30 to 07:00.
        var registered = summary(normal: date(15, 7, 30), ring: date(15, 7))
        registered.decisionNormalAlarmDate = date(15, 7, 30)
        func rolled(_ summary: ScheduledAlarmSummary, at now: Date) -> ScheduledAlarmSummary {
            summary.rollingForwardAsPair(selectedWeekdays: value.selectedWeekdays, now: now, calendar: calendar)
        }

        // Tuesday 08:00: Tuesday's ring has fired; the repeat rings Wednesday 07:00.
        let afterRing = date(15, 8)
        let carried = status(value, now: afterRing, summary: rolled(registered, at: afterRing))
        XCTAssertEqual(carried.day, date(16, 0))
        XCTAssertEqual(carried.expectedRingDate, date(16, 7), "The registered time is what AlarmKit rings")
        XCTAssertEqual(carried.registeredRingDate, date(16, 7))
        XCTAssertEqual(carried.reason, .rain)
        XCTAssertEqual(carried.leadTimeMinutes, 30)
        XCTAssertTrue(carried.rainLeadIsCarriedOver)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: carried), .awaitingForecast)
        XCTAssertNil(TomorrowWidgetSnapshotBuilder.scheduleIssue(for: carried, flags: .init()), "Nothing to update: it is registered")

        // A Wednesday forecast that has gone stale did not decide the registration either.
        // (Requested at 07:30, when the coming morning became Wednesday; 31 minutes old.)
        let staleWednesday = record(value, now: date(15, 7, 30))
        let staleCheck = date(15, 8, 1)
        let stillCarried = status(value, now: staleCheck, weather: staleWednesday, summary: rolled(registered, at: staleCheck))
        XCTAssertTrue(stillCarried.weatherIsStale)
        XCTAssertTrue(stillCarried.rainLeadIsCarriedOver)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: stillCarried), .awaitingForecast)

        // A fresh Wednesday forecast decides Wednesday outright: rain, and said so.
        let decided = status(value, now: date(15, 9), weather: record(value, now: date(15, 9)),
                             summary: rolled(registered, at: date(15, 9)))
        XCTAssertFalse(decided.rainLeadIsCarriedOver)
        XCTAssertEqual(decided.reason, .rain)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: decided), .rainForecast(percent: 80, minutes: 30))

        // The same day: Wednesday's own forecast decided Wednesday at 22:00 and went stale by
        // 23:00. That lead was decided for this morning and keeps its reason.
        var sameDay = summary(normal: date(16, 7, 30), ring: date(16, 7))
        sameDay.decisionNormalAlarmDate = date(16, 7, 30)
        let evening = date(15, 23)
        let staleSameDay = status(value, now: evening, weather: record(value, now: date(15, 22)),
                                  summary: rolled(sameDay, at: evening))
        XCTAssertTrue(staleSameDay.weatherIsStale)
        XCTAssertEqual(staleSameDay.expectedRingDate, date(16, 7))
        XCTAssertEqual(staleSameDay.reason, .rain)
        XCTAssertFalse(staleSameDay.rainLeadIsCarriedOver)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: staleSameDay), .rainEarlier(minutes: 30))
        // ...and with no forecast left at all.
        XCTAssertFalse(status(value, now: evening, summary: rolled(sameDay, at: evening)).rainLeadIsCarriedOver)

        // A lead-free carried registration claims nothing either way.
        var dry = summary(normal: date(15, 7, 30), ring: date(15, 7, 30))
        dry.decisionNormalAlarmDate = date(15, 7, 30)
        let dryCarried = status(value, now: afterRing, summary: rolled(dry, at: afterRing))
        XCTAssertEqual(dryCarried.reason, .normal)
        XCTAssertFalse(dryCarried.rainLeadIsCarriedOver)

        // A summary stored before 1.8.0 names no morning: read as decided, as it always was.
        let legacy = summary(normal: date(15, 7, 30), ring: date(15, 7))
        XCTAssertFalse(status(value, now: afterRing, summary: rolled(legacy, at: afterRing)).rainLeadIsCarriedOver)

        // A dated calendar plan only ever puts rain on the occurrence its forecast decided.
        var plan = summary(normal: date(16, 7, 30), ring: date(16, 7))
        plan.decisionNormalAlarmDate = date(15, 7, 30)
        plan.calendarPlan = .init(occurrences: [.init(normalDate: date(16, 7, 30), ringDate: date(16, 7))],
                                  coveredUntil: date(20, 0), timeZoneID: calendar.timeZone.identifier)
        let planned = status(value, now: afterRing, summary: plan)
        XCTAssertEqual(planned.expectedRingDate, date(16, 7))
        XCTAssertFalse(planned.rainLeadIsCarriedOver)
    }

    func testExpiredDatedCoverageCannotVerifyTomorrow() {
        let value = settings()
        let now = date(15)
        var registered = summary(normal: date(16, 7, 30), ring: date(16, 7, 30))
        registered.calendarPlan = .init(occurrences: [], coveredUntil: date(16, 0), timeZoneID: calendar.timeZone.identifier)
        XCTAssertFalse(status(value, now: now, summary: registered).isScheduleVerified)
        XCTAssertNil(status(value, now: now, summary: registered).registeredRingDate)
    }

    // MARK: - The coming morning (2026-09-29 device finding)

    /// At 00:39 the card described Wednesday while Tuesday — the morning about to be slept
    /// through, skipped for a closure — appeared nowhere. Midnight now changes only the word.
    func testCardFollowsTheComingMorningAcrossMidnight() {
        let value = settings()
        let evening = status(value, now: date(28, 23, 59))
        XCTAssertEqual(evening.normalAlarmDate, date(29, 7, 30))
        XCTAssertFalse(evening.isToday)
        let night = status(value, now: date(29, 0, 39))
        XCTAssertEqual(night.normalAlarmDate, date(29, 7, 30))
        XCTAssertTrue(night.isToday)
        XCTAssertEqual(night.reason, .normal)
        XCTAssertEqual(night.expectedRingDate, date(29, 7, 30))
        XCTAssertEqual(TomorrowWeatherRequest(settings: value, now: date(28, 23, 50), calendar: calendar),
                       TomorrowWeatherRequest(settings: value, now: date(29, 0, 10), calendar: calendar),
                       "The same morning, the same request: the evening's forecast carries over")
        let carried = status(value, now: date(29, 0, 10), weather: record(value, now: date(28, 23, 50)))
        XCTAssertNotNil(carried.weather)
        XCTAssertFalse(carried.weatherIsStale)
        XCTAssertEqual(carried.reason, .rain)
        XCTAssertEqual(carried.expectedRingDate, date(29, 7))
        XCTAssertFalse(carried.hasRung)
    }

    func testCardMovesOnAtTheNormalTimeNotAtMidnightOrTheCheckPoint() {
        let value = settings()
        XCTAssertEqual(status(value, now: date(29, 6, 59)).normalAlarmDate, date(29, 7, 30))
        XCTAssertEqual(status(value, now: date(29, 7, 0)).normalAlarmDate, date(29, 7, 30))
        let last = status(value, now: date(29, 7, 29))
        XCTAssertEqual(last.normalAlarmDate, date(29, 7, 30))
        XCTAssertTrue(last.isToday)
        let moved = status(value, now: date(29, 7, 30))
        XCTAssertEqual(moved.normalAlarmDate, date(30, 7, 30), "Strictly after: at 07:30:00 the card moves on")
        XCTAssertFalse(moved.isToday)
    }

    func testAlarmInsideTheLeadAcrossMidnight() {
        var value = settings()
        value.alarmTime = date(15, 0, 15)
        let before = status(value, now: date(15, 23, 50))
        XCTAssertEqual(before.normalAlarmDate, date(16, 0, 15))
        XCTAssertFalse(before.isToday)
        let after = status(value, now: date(16, 0, 5))
        XCTAssertEqual(after.normalAlarmDate, date(16, 0, 15))
        XCTAssertTrue(after.isToday)
        XCTAssertEqual(status(value, now: date(16, 0, 15)).normalAlarmDate, date(17, 0, 15))
    }

    /// The device case: 9/29 07:30 skipped and committed; at 00:39 the card says so itself.
    func testTodaysCommittedClosureSkipAfterMidnight() {
        let feed = taipeiClosure(id: "notice", sentAt: date(28, 22), checkedAt: date(29, 0, 30), day: "明天")
        let committed = planSummary([(date(30, 7, 30), date(30, 7, 30))],
            skips: [.init(normalDate: date(29, 7, 30), noticeIDs: ["notice"], appliedAt: date(28, 22, 5))],
            coveredUntil: date(30, 23))
        let result = status(closureSettings(), now: date(29, 0, 39), summary: committed, feed: feed)
        XCTAssertEqual(result.day, date(29, 0))
        XCTAssertTrue(result.isToday)
        XCTAssertEqual(result.reason, .disaster)
        XCTAssertNil(result.expectedRingDate)
        XCTAssertNil(result.registeredRingDate)
        XCTAssertTrue(result.isScheduleVerified)
        XCTAssertEqual(result.disasterNoticeIDs, ["notice"])
        XCTAssertTrue(result.hasCommittedClosureSkip)
        XCTAssertFalse(result.hasRung)
    }

    func testTodayAnnouncementBeforeDawnShowsSkipBeforeCommit() {
        let feed = taipeiClosure(id: "dawn", sentAt: date(29, 5), checkedAt: date(29, 5, 1), day: "今天")
        let plan = planSummary([(date(29, 7, 30), date(29, 7, 30)), (date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        let result = status(closureSettings(), now: date(29, 5, 30), summary: plan, feed: feed)
        XCTAssertTrue(result.isToday)
        XCTAssertEqual(result.reason, .disaster)
        XCTAssertNil(result.expectedRingDate)
        XCTAssertEqual(result.registeredRingDate, date(29, 7, 30), "Still armed until the re-registration commits")
        XCTAssertFalse(result.isScheduleVerified)
        XCTAssertFalse(result.hasCommittedClosureSkip)
    }

    func testEarlyRingThatAlreadyRangStaysOnTodayWithoutMismatch() {
        let value = settings()
        let plan = planSummary([(date(29, 7, 30), date(29, 7)), (date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        for probability in [0.8, 0.1] {
            let result = status(value, now: date(29, 7, 10), weather: record(value, now: date(29, 6, 50), probability: probability),
                                summary: plan)
            XCTAssertEqual(result.expectedRingDate, date(29, 7), "\(probability)")
            XCTAssertEqual(result.reason, .rain)
            XCTAssertEqual(result.leadTimeMinutes, 30)
            XCTAssertTrue(result.hasRung)
            XCTAssertEqual(result.registeredRingDate, result.expectedRingDate)
            XCTAssertTrue(result.isScheduleVerified)
            XCTAssertTrue(result.isToday)
        }
    }

    func testPostCheckForecastCannotMoveADryMorning() {
        let value = settings()
        let plan = planSummary([(date(29, 7, 30), date(29, 7, 30))], coveredUntil: date(30, 23))
        let result = status(value, now: date(29, 7, 10), weather: record(value, now: date(29, 7, 5), probability: 0.8), summary: plan)
        XCTAssertEqual(result.expectedRingDate, date(29, 7, 30))
        XCTAssertEqual(result.reason, .normal)
        XCTAssertFalse(result.hasRung)
        XCTAssertEqual(result.registeredRingDate, date(29, 7, 30))
        XCTAssertTrue(result.isScheduleVerified)
    }

    func testClosureAfterTheEarlyRingDoesNotRelabelIt() {
        let feed = taipeiClosure(id: "late", sentAt: date(29, 7, 2), checkedAt: date(29, 7, 3), day: "今天")
        let stillHeld = planSummary([(date(29, 7, 30), date(29, 7)), (date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        var reRegistered = planSummary([(date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        reRegistered.firedEarlyRing = .init(normalDate: date(29, 7, 30), ringDate: date(29, 7))
        for (name, plan) in [("still held", stillHeld), ("re-registered", reRegistered)] {
            let result = status(closureSettings(), now: date(29, 7, 5), summary: plan, feed: feed)
            XCTAssertEqual(result.reason, .rain, name)
            XCTAssertEqual(result.expectedRingDate, date(29, 7), name)
            XCTAssertTrue(result.hasRung, name)
            XCTAssertEqual(result.disasterNoticeIDs, [], name)
            XCTAssertFalse(result.hasCommittedClosureSkip, name)
        }
    }

    /// registerCalendar drops a morning whose early ring already went off and records when
    /// it rang. The card reads that record — not the current lead, which the user may have
    /// changed right after being woken (adversarial review of the first version).
    func testRecordedEarlyRingIsReadWhateverTheLeadIsNow() {
        var plan = planSummary([(date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        plan.firedEarlyRing = .init(normalDate: date(29, 7, 30), ringDate: date(29, 7))
        for (lead, now) in [(30, date(29, 7, 10)), (15, date(29, 7, 6)), (45, date(29, 7, 10))] {
            var value = settings()
            value.rainLeadTimeMinutes = lead
            let result = status(value, now: now, weather: record(value, now: now, probability: 0.8), summary: plan)
            XCTAssertEqual(result.registeredRingDate, date(29, 7), "lead \(lead)")
            XCTAssertEqual(result.expectedRingDate, date(29, 7), "lead \(lead): it rang at 07:00, not at the new lead")
            XCTAssertEqual(result.leadTimeMinutes, 30, "lead \(lead)")
            XCTAssertEqual(result.reason, .rain, "lead \(lead)")
            XCTAssertTrue(result.hasRung, "lead \(lead)")
            XCTAssertFalse(result.ringIsNotRegistered, "lead \(lead)")
        }
    }

    func testAPlanThatLostTheMorningIsFlaggedNotPromised() {
        let value = settings()
        let plan = planSummary([(date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        for now in [date(29, 6, 30), date(29, 7, 10)] {
            let result = status(value, now: now, summary: plan)
            XCTAssertNil(result.registeredRingDate)
            XCTAssertEqual(result.expectedRingDate, date(29, 7, 30))
            XCTAssertTrue(result.ringIsNotRegistered, "The page must warn instead of promising an unarmed 07:30")
            XCTAssertFalse(result.hasRung)
        }
        var silent = value
        silent.calendarSettings = .init(isEnabled: true, source: .taiwan, overrides: ["2026-09-29": .silent])
        let silentResult = status(silent, now: date(29, 7, 10), summary: plan)
        XCTAssertEqual(silentResult.reason, .manual)
        XCTAssertFalse(silentResult.ringIsNotRegistered, "A silent morning is supposed to be missing")
        var skipped = plan
        skipped.disasterSkips = [.init(normalDate: date(29, 7, 30), noticeIDs: ["n"], appliedAt: date(28, 22))]
        let skipResult = status(value, now: date(29, 7, 10), summary: skipped)
        XCTAssertNil(skipResult.registeredRingDate)
        XCTAssertTrue(skipResult.hasCommittedClosureSkip)
        XCTAssertFalse(skipResult.isMissingFromPlan, "A committed skip explains the gap")
        XCTAssertTrue(skipResult.ringIsNotRegistered, "…but the live preview (feature off here) no longer supports it")
    }

    /// Weekly path: a foreground re-registration between today's check point and its normal
    /// time decides tomorrow, and the repeating alarm's new clock time governs today too.
    func testWeeklyReRegisteredInsideTheWindowIsJudgedByItsClockTime() {
        let value = settings()
        let rainyTomorrow = status(value, now: date(29, 7, 10), summary: summary(normal: date(30, 7, 30), ring: date(30, 7)))
        XCTAssertEqual(rainyTomorrow.expectedRingDate, date(29, 7, 30))
        XCTAssertEqual(rainyTomorrow.registeredRingDate, date(30, 7), "Today's 07:00 has passed: nothing is left today")
        XCTAssertNotEqual(rainyTomorrow.registeredRingDate, rainyTomorrow.expectedRingDate, "So the page flags the mismatch")
        XCTAssertFalse(rainyTomorrow.hasRung, "Registered for Wednesday after Tuesday's 07:00: that slot never rang")
        XCTAssertEqual(rainyTomorrow.passedRingDate, date(29, 7), "The widget ends today there (merge with ios/widget)")
        let dryTomorrow = status(value, now: date(29, 7, 10), summary: summary(normal: date(30, 7, 30), ring: date(30, 7, 30)))
        XCTAssertEqual(dryTomorrow.registeredRingDate, date(29, 7, 30), "The weekly 07:30 still rings today")
        XCTAssertEqual(dryTomorrow.expectedRingDate, date(29, 7, 30))
        XCTAssertTrue(dryTomorrow.isScheduleVerified)
    }

    func testSummaryStoredBeforeTheFiredRingFieldStillDecodes() throws {
        let stored = summary(normal: date(29, 7, 30), ring: date(29, 7))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        json.removeValue(forKey: "firedEarlyRing")
        let decoded = try JSONDecoder().decode(ScheduledAlarmSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.firedEarlyRing)
        XCTAssertEqual(decoded.normalAlarmDate, stored.normalAlarmDate)
    }

    func testRolledWeeklySummaryIsMatchedByClockTime() {
        let value = settings()
        var rolled = summary(normal: date(29, 7, 30), ring: date(29, 7))
        rolled.scheduledAlarmDate = date(30, 7)
        let result = status(value, now: date(29, 7, 10), summary: rolled)
        XCTAssertEqual(result.registeredRingDate, date(29, 7))
        XCTAssertEqual(result.expectedRingDate, date(29, 7))
        XCTAssertEqual(result.reason, .rain)
        XCTAssertTrue(result.hasRung)
        var odd = rolled
        odd.scheduledAlarmDate = date(30, 6, 45)
        let oddResult = status(value, now: date(29, 7, 10), summary: odd)
        XCTAssertEqual(oddResult.registeredRingDate, date(30, 6, 45), "An inconsistent registration still surfaces")
        XCTAssertFalse(oddResult.isScheduleVerified)
    }

    func testWeeklySummaryForThisMorningIsUsedAfterMidnight() {
        let result = status(settings(), now: date(29, 0, 39), summary: summary(normal: date(29, 7, 30), ring: date(29, 7)))
        XCTAssertEqual(result.expectedRingDate, date(29, 7))
        XCTAssertEqual(result.reason, .rain)
        XCTAssertEqual(result.registeredRingDate, date(29, 7))
        XCTAssertTrue(result.isToday)
        let yesterdays = status(settings(), now: date(29, 0, 39), summary: summary(normal: date(28, 7, 30), ring: date(28, 7)))
        XCTAssertNil(yesterdays.registeredRingDate)
        XCTAssertEqual(yesterdays.expectedRingDate, date(29, 7, 30))
    }

    func testNoAlarmDayAfterMidnightStaysOnThatDay() {
        var value = settings()
        value.selectedWeekdays = Set(2...6)
        let saturday = status(value, now: date(26, 0, 39))
        XCTAssertEqual(saturday.day, date(26, 0))
        XCTAssertEqual(saturday.reason, .weekend)
        XCTAssertTrue(saturday.isToday)
        let later = status(value, now: date(26, 7, 30))
        XCTAssertEqual(later.day, date(27, 0))
        XCTAssertEqual(later.reason, .weekend)
        XCTAssertFalse(later.isToday)
        let sunday = status(value, now: date(27, 7, 30))
        XCTAssertEqual(sunday.day, date(28, 0))
        XCTAssertEqual(sunday.reason, .normal)
        XCTAssertEqual(sunday.expectedRingDate, date(28, 7, 30))
    }

    /// The widget merge (2026-10-01): one request type, two ways to name the morning. nil is
    /// the card's coming morning (the one forecast the app fetches); 0 and 1 are the widget's
    /// calendar days, which match that forecast only when they name the same morning.
    func testCalendarDayRequestsBesideTheComingMorning() {
        let value = settings()
        func request(_ now: Date, _ offset: Int?) -> TomorrowWeatherRequest {
            TomorrowWeatherRequest(settings: value, now: now, calendar: calendar, dayOffset: offset)
        }
        for (now, coming) in [(date(28, 21), date(29, 7, 30)), (date(29, 3), date(29, 7, 30)), (date(29, 7, 30), date(30, 7, 30))] {
            XCTAssertEqual(request(now, nil).normalAlarmDate, coming, "\(now)")
            XCTAssertEqual(request(now, 0).normalAlarmDate, calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now), "\(now)")
            XCTAssertEqual(request(now, 1).normalAlarmDate,
                           calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now)!),
                           "\(now)")
            XCTAssertEqual(TomorrowWeatherRequest(settings: value, now: now, calendar: calendar), request(now, nil))
        }
        // The evening's fetched forecast serves the widget's tomorrow before midnight and its
        // today after it, never a day it was not fetched for.
        let evening = record(value, now: date(28, 21))
        XCTAssertEqual(evening.request, request(date(28, 21), 1))
        XCTAssertEqual(evening.request, request(date(29, 3), 0))
        XCTAssertNotEqual(evening.request, request(date(29, 3), 1))
    }

    // MARK: - Master switch (1.8.0)

    func testAlarmOffOutranksEveryOtherReason() {
        var value = closureSettings()
        value.isAlarmEnabled = false
        let feed = taipeiClosure(id: "n", sentAt: date(28, 22), checkedAt: date(28, 22, 1), day: "明天")
        for (name, now, setting) in [("closure", date(28, 23), value), ("rain", date(28, 23), value)] {
            let result = status(setting, now: now, weather: record(setting, now: now), feed: feed)
            XCTAssertEqual(result.reason, .alarmOff, name)
            XCTAssertNil(result.expectedRingDate, name)
            XCTAssertFalse(result.ringIsNotRegistered, name)
        }
        var weekend = value
        weekend.selectedWeekdays = [2, 3, 4, 5, 6]
        XCTAssertEqual(status(weekend, now: date(26, 0, 39)).reason, .alarmOff)
        XCTAssertEqual(status(value, now: date(28, 23), routeReady: false).reason, .alarmOff)
    }

    func testACommittedSkipForTheComingMorningIsVerifiedNotMissing() {
        var value = settings()
        value.skippedAlarmDay = "2026-09-29"
        let committed = planSummary([(date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        let result = status(value, now: date(28, 23), summary: committed)
        XCTAssertEqual(result.reason, .skippedOnce)
        XCTAssertNil(result.expectedRingDate)
        XCTAssertFalse(result.isMissingFromPlan)
        XCTAssertFalse(result.ringIsNotRegistered)
        XCTAssertTrue(result.isScheduleVerified)
        let uncommitted = planSummary([(date(29, 7, 30), date(29, 7, 30)), (date(30, 7, 30), date(30, 7, 30))], coveredUntil: date(30, 23))
        let pending = status(value, now: date(28, 23), summary: uncommitted)
        XCTAssertEqual(pending.reason, .skippedOnce)
        XCTAssertEqual(pending.registeredRingDate, date(29, 7, 30), "Still armed until the skip is committed")
        XCTAssertFalse(pending.isScheduleVerified)
    }

    func testASkipNeverHidesAMorePressingReason() {
        var weekend = settings()
        weekend.selectedWeekdays = [2, 3, 4, 5, 6]
        weekend.skippedAlarmDay = "2026-09-26"
        XCTAssertEqual(status(weekend, now: date(25, 23)).reason, .weekend, "A day that would not ring anyway")
        var value = settings()
        value.skippedAlarmDay = "2026-09-29"
        XCTAssertEqual(status(value, now: date(28, 23), routeReady: false).reason, .routeIncomplete)
        var later = settings()
        later.skippedAlarmDay = "2026-10-02"
        XCTAssertEqual(status(later, now: date(28, 23)).reason, .normal, "The coming morning is not the skipped one")
    }

    func testAlarmPageDayStringsExistInBothLocalizations() throws {
        let keys = ["ux_alarm_off_title", "ux_alarm_skip_next", "ux_alarm_turn_off", "ux_alarm_off_message_next",
                    "ux_alarm_off_message_in_progress", "ux_alarm_off_message_only",
                    "ux_alarm_switch_skip_value", "ux_alarm_off", "ux_alarm_off_reason", "ux_skip_once_reason",
                    "ux_skip_once_resume", "ux_skip_later", "alarm_off_failed", "alarm_on_without_forecast",
                    "status_alarm_turned_off", "evening_preview_skip_once", "alarm_renew_title", "alarm_renew_body",
                    "ux_next_alarm", "ux_today_weather", "ux_today_weather_loading", "ux_today_weather_failed",
                    "ux_today_holiday_named", "ux_today_holiday", "ux_today_manual_skip", "ux_today_manual_ring",
                    "ux_today_weekend", "ux_today_unselected", "ux_rang_at", "ux_today_closure_skipped",
                    "ux_tomorrow", "ux_tomorrow_weather",
                    // The widget merge: a carried-over lead (D-D) on the card after midnight.
                    "ux_tomorrow_awaiting_forecast", "ux_today_awaiting_forecast"]
        let bundle = Bundle(for: AlarmViewModel.self)
        for language in ["en", "zh-Hant"] {
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                 forLocalization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
            for key in keys {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertNotEqual(value, key, "\(language): \(key)")
            }
        }
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
        // Twelve hours from now: the card's morning switches at the alarm time, and
        // Date()-based tests must never straddle that moment.
        model.settings.alarmTime = Date().addingTimeInterval(12 * 3_600)
        return model
    }
    private func d(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        AlarmCalendarSettings.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testEveningForecastIsReusedAfterMidnight() async {
        let service = TomorrowWeatherStub(checkedAt: d(28, 23, 50))
        let model = model(service: service, scheduler: TomorrowSchedulerSpy())
        model.settings.alarmTime = d(28, 7, 30)
        await model.refreshTomorrowWeatherIfNeeded(now: d(28, 23, 50))
        var requests = await service.requests
        XCTAssertEqual(requests.map(\.date), [d(29, 7)])
        await model.refreshTomorrowWeatherIfNeeded(now: d(29, 0, 10))
        requests = await service.requests
        XCTAssertEqual(requests.count, 1, "Midnight changes only the day word; the same morning's forecast is reused")
        let status = model.tomorrowStatus(now: d(29, 0, 10))
        XCTAssertNotNil(status.weather)
        XCTAssertTrue(status.isToday)
        XCTAssertEqual(status.normalAlarmDate, d(29, 7, 30))
    }

    func testSwitchAtTheNormalTimeFetchesTheNextMorning() async {
        let service = TomorrowWeatherStub(checkedAt: d(29, 7, 20))
        let model = model(service: service, scheduler: TomorrowSchedulerSpy())
        model.settings.alarmTime = d(28, 7, 30)
        await model.refreshTomorrowWeatherIfNeeded(now: d(29, 7, 20))
        await model.refreshTomorrowWeatherIfNeeded(now: d(29, 7, 30))
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.date), [d(29, 7), d(30, 7)])
        XCTAssertFalse(model.tomorrowStatus(now: d(29, 7, 30)).isToday)
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
    /// A failure outlives the process (2026-10-09): a background run or a closure push builds a
    /// fresh model and publishes without fetching, and must still say the last check failed,
    /// since the widget no longer warns about an old forecast by itself. A success clears it.
    func testFailureSurvivesRelaunchUntilAFetchSucceeds() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now)
        let original = model(service: service, scheduler: TomorrowSchedulerSpy())
        await original.refreshTomorrowWeatherIfNeeded(now: now)
        let good = original.tomorrowStatus(now: now).weather
        XCTAssertNotNil(good)
        XCTAssertNil(storage.data(forKey: TomorrowWeatherFailure.cacheKey))
        await service.setFailure(true)
        await original.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(2), force: true)
        XCTAssertTrue(original.tomorrowStatus(now: now).weatherRefreshFailed)
        XCTAssertNotNil(storage.data(forKey: TomorrowWeatherFailure.cacheKey))

        let relaunched = AlarmViewModel(routeWeatherService: service, notificationScheduler: TomorrowSchedulerSpy(),
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        XCTAssertTrue(relaunched.tomorrowStatus(now: now).weatherRefreshFailed, "Restored before any fetch")
        XCTAssertEqual(relaunched.tomorrowStatus(now: now).weather, good, "Beside the last good forecast")
        // Only for the request it failed: the morning after, or another route, starts clean.
        XCTAssertFalse(relaunched.tomorrowStatus(now: now.addingTimeInterval(86_400)).weatherRefreshFailed)

        await service.setFailure(false)
        await relaunched.refreshTomorrowWeatherIfNeeded(now: now.addingTimeInterval(70), force: true)
        XCTAssertFalse(relaunched.tomorrowStatus(now: now).weatherRefreshFailed)
        XCTAssertNil(storage.data(forKey: TomorrowWeatherFailure.cacheKey), "A success removes it for the next launch too")
        let again = AlarmViewModel(routeWeatherService: service, notificationScheduler: TomorrowSchedulerSpy(),
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        XCTAssertFalse(again.tomorrowStatus(now: now).weatherRefreshFailed)
    }

    func testFailureIsNotRestoredForAnotherRoute() async {
        let now = Date()
        let service = TomorrowWeatherStub(checkedAt: now)
        let original = model(service: service, scheduler: TomorrowSchedulerSpy())
        await service.setFailure(true)
        await original.refreshTomorrowWeatherIfNeeded(now: now, force: true)
        XCTAssertTrue(original.tomorrowStatus(now: now).weatherRefreshFailed)
        original.settings.homeAddress = "Elsewhere"
        XCTAssertFalse(original.tomorrowStatus(now: now).weatherRefreshFailed)
        let relaunched = AlarmViewModel(routeWeatherService: service, notificationScheduler: TomorrowSchedulerSpy(),
            settingsStorage: storage, calendarWeatherTimeout: .seconds(2))
        XCTAssertFalse(relaunched.tomorrowStatus(now: now).weatherRefreshFailed, "The stored failure names the old home")
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
        let calendar = AlarmCalendarSettings.calendar
        // Noon: between 00:00 and the 00:15 alarm the card would describe today's alarm instead.
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        var settings = CommuteAlarmSettings()
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

/// "Today was not re-checked" (owner, 2026-10-09): the evidence log and the rule. A 07:00 alarm
/// with a 30-minute lead has its check point at 06:30 and its re-check window from 21:30 the
/// evening before (`WeatherDecisionLog.recheckWindow`, the nine hours the app asks iOS for).
final class UnrecheckedMorningTests: XCTestCase {
    private var calendar: Calendar { AlarmCalendarSettings.calendar }
    private func d(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func today(_ reason: TomorrowAlarmStatus.Reason = .normal, ring: Date?? = nil) -> TomorrowAlarmStatus {
        TomorrowAlarmStatus(day: d(10, 0), normalAlarmDate: d(10, 7), expectedRingDate: ring ?? d(10, 7), reason: reason,
                            holidayName: nil, leadTimeMinutes: 0, weather: nil, weatherIsStale: false, weatherRefreshFailed: false,
                            registeredRingDate: nil, isScheduleVerified: false, disasterNoticeIDs: [])
    }
    private func evaluate(_ log: WeatherDecisionLog, at now: Date, status: TomorrowAlarmStatus? = nil,
                          lead: Int = 30, enabled: Bool = true) -> UnrecheckedMorning? {
        UnrecheckedMorning.evaluate(today: status ?? today(), isAlarmEnabled: enabled, rainLeadTimeMinutes: lead,
                                    log: log, now: now, calendar: calendar)
    }
    private func log(_ decisions: (morning: Date, checkedAt: Date)...) -> WeatherDecisionLog {
        var value = WeatherDecisionLog()
        for decision in decisions { value.record(morning: decision.morning, checkedAt: decision.checkedAt) }
        return value
    }

    func testTheWindowIsWhatTheAppAsksIOSFor() {
        XCTAssertEqual(WeatherDecisionLog.recheckWindow, 9 * 3_600)
        XCTAssertEqual(WeatherDecisionLog.recheckWindow, BackgroundWeatherRefresh.processingLeadTime)
        XCTAssertEqual(WeatherDecisionLog.retrospective, 3 * 3_600)
    }

    func testAMorningDecidedOnlyTheEveningBeforeIsNotRechecked() {
        let evening = log((d(10, 7), d(9, 20)))
        XCTAssertNil(evaluate(evening, at: d(10, 6, 29)), "Before the check point a re-check can still happen")
        XCTAssertEqual(evaluate(evening, at: d(10, 6, 30)), UnrecheckedMorning(morning: d(10, 7), forecastCheckedAt: d(9, 20)))
        XCTAssertNotNil(evaluate(evening, at: d(10, 7, 0)), "At the ring")
        XCTAssertNotNil(evaluate(evening, at: d(10, 9, 59)), "Retrospective: three hours after the normal time")
        XCTAssertNil(evaluate(evening, at: d(10, 10, 0)))
    }

    func testAnyDecisionInTheNineHoursBeforeTheCheckPointCounts() {
        for checked in [d(9, 21, 30), d(10, 2), d(10, 6, 29)] {
            XCTAssertNil(evaluate(log((d(10, 7), d(9, 20)), (d(10, 7), checked)), at: d(10, 6, 45)), "\(checked)")
        }
        XCTAssertNotNil(evaluate(log((d(10, 7), d(9, 21, 29))), at: d(10, 6, 45)), "Just before the window opened")
        // A forecast fetched after the check point cannot have moved the ring, and must not
        // erase the evening decision the alarm rings on.
        let late = log((d(10, 7), d(9, 20)), (d(10, 7), d(10, 6, 31)))
        XCTAssertEqual(evaluate(late, at: d(10, 6, 45))?.forecastCheckedAt, d(9, 20))
        // A decision in the window for another morning is not this morning's.
        XCTAssertNotNil(evaluate(log((d(9, 7), d(9, 20)), (d(11, 7), d(10, 2))), at: d(10, 6, 45)))
    }

    func testOnlyARingDayAForecastDecidesWithALeadAndAHistory() {
        let evening = log((d(10, 7), d(9, 20)))
        XCTAssertNotNil(evaluate(evening, at: d(10, 6, 45), status: today(.rain, ring: d(10, 6, 30))))
        XCTAssertNotNil(evaluate(evening, at: d(10, 6, 45), status: today(.manual)))
        for reason in [TomorrowAlarmStatus.Reason.holiday, .weekend, .unselectedWeekday, .disaster, .routeIncomplete, .alarmOff, .skippedOnce] {
            XCTAssertNil(evaluate(evening, at: d(10, 6, 45), status: today(reason, ring: .some(nil))), "\(reason)")
        }
        XCTAssertNil(evaluate(evening, at: d(10, 6, 45), status: today(.normal, ring: .some(nil))), "No ring")
        XCTAssertNil(evaluate(evening, at: d(10, 6, 45), enabled: false), "Off")
        XCTAssertNil(evaluate(evening, at: d(10, 6, 45), lead: 0), "Without a lead there is nothing to re-check")
        XCTAssertNil(evaluate(WeatherDecisionLog(), at: d(10, 6, 45)), "Never decided from a forecast: a first install")
        XCTAssertNil(evaluate(log((d(10, 7), d(10, 6, 40))), at: d(10, 6, 45)), "Only decided after the check point")
    }

    func testTheRetrospectiveEndsAtMidnight() {
        // A 22:30 alarm: three hours after it would run past midnight.
        let late = TomorrowAlarmStatus(day: d(10, 0), normalAlarmDate: d(10, 22, 30), expectedRingDate: d(10, 22, 30), reason: .normal,
                                       holidayName: nil, leadTimeMinutes: 0, weather: nil, weatherIsStale: false, weatherRefreshFailed: false,
                                       registeredRingDate: nil, isScheduleVerified: false, disasterNoticeIDs: [])
        let decided = log((d(10, 22, 30), d(10, 12)))
        XCTAssertNotNil(evaluate(decided, at: d(10, 23, 59), status: late))
        XCTAssertNil(evaluate(decided, at: d(11, 0, 0), status: late))
    }

    func testTheLogKeepsRecentDecisionsAndSurvivesStorage() throws {
        var value = WeatherDecisionLog()
        for hour in 0..<20 { value.record(morning: d(10, 7), checkedAt: d(9, hour)) }
        value.record(morning: d(10, 7), checkedAt: d(9, 19))
        XCTAssertEqual(value.decisions.count, WeatherDecisionLog.maximumDecisions)
        XCTAssertEqual(value.decisions.first?.checkedAt, d(9, 4), "The oldest go first")
        XCTAssertEqual(value.latestForecast(before: d(9, 10)), d(9, 9))
        let suite = "UnrecheckedMorningTests.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WeatherDecisionLog.load(from: storage), WeatherDecisionLog())
        value.save(to: storage)
        XCTAssertEqual(WeatherDecisionLog.load(from: storage), value)
    }

    func testOpeningTheAppInsideTheWindowReDecidesOnlyBeforeARingDayWithoutADecisionThere() {
        let coming = today()   // 07:00 on 10/10, check point 06:30, window from 21:30 on 10/9
        func awaits(_ log: WeatherDecisionLog, status: TomorrowAlarmStatus = coming, at now: Date = d(9, 22),
                    lead: Int = 30, enabled: Bool = true) -> Bool {
            UnrecheckedMorning.awaitsRecheck(coming: status, isAlarmEnabled: enabled, rainLeadTimeMinutes: lead, log: log, now: now)
        }
        XCTAssertTrue(awaits(self.log((d(10, 7), d(9, 20)))))
        XCTAssertFalse(awaits(self.log((d(10, 7), d(9, 21, 45)))), "Decided inside the window already")
        XCTAssertFalse(awaits(WeatherDecisionLog(), at: d(9, 20)), "Before the window: the 4-hour rule stands")
        XCTAssertFalse(awaits(WeatherDecisionLog(), at: d(10, 6, 30)), "From the check point nothing re-decides")
        XCTAssertFalse(awaits(WeatherDecisionLog(), lead: 0))
        XCTAssertFalse(awaits(WeatherDecisionLog(), enabled: false))
        // Friday night before a Mon–Fri user's Saturday, a holiday, a skip or a closure: nothing
        // would ever record that morning, so every open would re-fetch for nothing.
        for reason in [TomorrowAlarmStatus.Reason.unselectedWeekday, .weekend, .holiday, .skippedOnce, .disaster] {
            XCTAssertFalse(awaits(WeatherDecisionLog(), status: today(reason, ring: .some(nil))), "\(reason)")
        }
    }

    /// The card names the forecast the alarm rings on: this morning's last decision; on a weekly
    /// registration, which repeats the last decision's time, the last one for any morning; on a
    /// dated plan with none for this morning, no forecast: it rings at its normal time.
    func testTheForecastNamedIsTheOneTheAlarmRingsOn() {
        let mixed = log((d(9, 7), d(9, 6)), (d(10, 7), d(9, 20)), (d(11, 7), d(9, 21)))
        XCTAssertEqual(evaluate(mixed, at: d(10, 6, 45))?.forecastCheckedAt, d(9, 20), "This morning's own decision")
        let otherMorning = log((d(9, 7), d(9, 6)))
        XCTAssertEqual(evaluate(otherMorning, at: d(10, 6, 45))?.forecastCheckedAt, d(9, 6), "Weekly: the repeat carries it")
        let dated = UnrecheckedMorning.evaluate(today: today(), isAlarmEnabled: true, rainLeadTimeMinutes: 30, log: otherMorning,
                                                weekly: false, now: d(10, 6, 45), calendar: calendar)
        XCTAssertEqual(dated, UnrecheckedMorning(morning: d(10, 7), forecastCheckedAt: nil), "Dated: no forecast decided it")
    }

    func testTheCardCaptionNamesWhenTheForecastWasFetched() {
        let format = ClockTimeFormat.twentyFourHour
        func caption(_ fetched: Date?, background: Bool = true) -> String {
            UnrecheckedMorning(morning: d(10, 7), forecastCheckedAt: fetched)
                .captionText(now: d(10, 7, 10), calendar: calendar, format: format, canRefreshInBackground: background)
        }
        func sentence(_ when: String) -> String { String.localizedStringWithFormat(String(localized: "ux_today_not_rechecked"), when) }
        XCTAssertEqual(caption(d(10, 5)), sentence(format.time(d(10, 5))), "This morning: the time alone")
        XCTAssertEqual(caption(d(9, 21)),
                       sentence(String.localizedStringWithFormat(String(localized: "ux_time_yesterday"), format.time(d(9, 21)))))
        XCTAssertEqual(caption(d(8, 21)), sentence(format.dateTime(d(8, 21))), "Older: date and time")
        XCTAssertEqual(caption(nil), String(localized: "ux_today_not_checked"))
        XCTAssertEqual(caption(d(9, 21), background: false),
                       caption(d(9, 21)) + " " + String(localized: "ux_no_background_now"))
        XCTAssertTrue(caption(d(9, 21)).contains("21:00"))
        for key in ["ux_today_not_rechecked", "ux_time_yesterday", "ux_no_background_now", "ux_today_not_checked"] {
            XCTAssertNotEqual(String(localized: String.LocalizationValue(key)), key, "\(key) is translated")
        }
    }
}
