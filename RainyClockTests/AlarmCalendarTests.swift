import XCTest
@testable import RainyClock

final class AlarmCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    func testManualRingOverridesHolidayAndUnselectedWeekday() {
        var rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan)
        let day = date(2026, 1, 1)
        rules.overrides["2026-01-01"] = .ring
        let holidays = HolidayCalendar(days: ["2026-01-01": .init(isOff: true, name: "元旦")])
        XCTAssertTrue(rules.decision(on: day, weekdays: [], holidays: holidays, calendar: calendar).rings)
        rules.overrides.removeAll()
        XCTAssertFalse(rules.decision(on: day, weekdays: Set(1...7), holidays: holidays, calendar: calendar).rings)
    }
    func testManualSilenceOverridesAWorkingDayAndOnlyAppliesToThatYear() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .weekly, overrides: ["2026-09-11": .silent])
        XCTAssertFalse(rules.decision(on: date(2026, 9, 11), weekdays: Set(1...7), holidays: .init(), calendar: calendar).rings)
        XCTAssertTrue(rules.decision(on: date(2027, 9, 11), weekdays: Set(1...7), holidays: .init(), calendar: calendar).rings)
    }
    func testMissingHolidayDataFallsBackToWeeklyRule() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan)
        let day = date(2030, 1, 1)
        let weekday = calendar.component(.weekday, from: day)
        XCTAssertTrue(rules.decision(on: day, weekdays: [weekday], holidays: .init(), calendar: calendar).rings)
        XCTAssertFalse(rules.decision(on: day, weekdays: [], holidays: .init(), calendar: calendar).rings)
    }
    func testUnitedStatesSourceSurvivesSettingsRoundTrip() throws {
        let original = AlarmCalendarSettings(isEnabled: true, source: .unitedStates,
            overrides: ["2026-11-26": .ring])
        let restored = try JSONDecoder().decode(AlarmCalendarSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.isActive)
    }
    func testUnitedStates2026MatchesOPMObservedHolidayScheduleOffline() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .unitedStates)
        // OPM's published 2026 schedule (July 4 is observed Friday, July 3).
        let dates = [(1,1), (1,19), (2,16), (5,25), (6,19), (7,3), (9,7), (10,12), (11,11), (11,26), (12,25)]
        for (month, day) in dates {
            XCTAssertEqual(rules.decision(on: date(2026, month, day), weekdays: Set(1...7),
                holidays: .init(), calendar: calendar), DayDecision(rings: false, reason: .holiday), "\(month)-\(day)")
        }
        let expected = Set(dates.map { AlarmCalendarSettings.key(for: date(2026, $0.0, $0.1), calendar: calendar) })
        let observed = Set((0..<365).compactMap { offset -> String? in
            let day = calendar.date(byAdding: .day, value: offset, to: date(2026,1,1))!
            guard (2...6).contains(calendar.component(.weekday, from: day)),
                  HolidayCalendar().day(on: day, source: .unitedStates, calendar: calendar)?.isOff == true else { return nil }
            return AlarmCalendarSettings.key(for: day, calendar: calendar)
        })
        XCTAssertEqual(observed, expected, "No extra weekday closures beyond OPM's schedule")
        XCTAssertEqual(rules.decision(on: date(2026, 11, 27), weekdays: Set(1...7),
            holidays: .init(), calendar: calendar), DayDecision(rings: true, reason: .weekday),
            "The Friday after Thanksgiving is not a recurring federal holiday")
    }
    func testUnitedStatesActualAndObservedDatesIncludingCrossYear() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .unitedStates)
        for day in [date(2026,7,3), date(2026,7,4), date(2027,6,18), date(2027,6,19),
                    date(2027,7,4), date(2027,7,5), date(2027,12,24), date(2027,12,25),
                    date(2027,12,31), date(2028,1,1)] {
            XCTAssertEqual(rules.decision(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar),
                DayDecision(rings: false, reason: .holiday), AlarmCalendarSettings.key(for: day, calendar: calendar))
        }
        XCTAssertTrue(rules.decision(on: date(2027,12,30), weekdays: Set(1...7), holidays: .init(), calendar: calendar).rings)
        XCTAssertTrue(rules.decision(on: date(2028,1,3), weekdays: Set(1...7), holidays: .init(), calendar: calendar).rings)
    }
    func testUnitedStatesWeekdayFormulasAndJuneteenthStart() {
        let holidays = HolidayCalendar()
        for day in [date(2027,1,18), date(2027,2,15), date(2027,5,31), date(2027,9,6),
                    date(2027,10,11), date(2027,11,25), date(2021,6,18), date(2021,6,19)] {
            XCTAssertEqual(holidays.day(on: day, source: .unitedStates, calendar: calendar)?.isOff, true)
        }
        for day in [date(2020,6,19), date(2027,5,24), date(2027,11,18), date(2028,2,29)] {
            XCTAssertEqual(holidays.day(on: day, source: .unitedStates, calendar: calendar)?.isOff, false)
        }
    }
    func testUnitedStatesDoesNotUseTaiwanCacheOrInventUnselectedWeekdays() {
        let cached = HolidayCalendar(days: ["2026-07-03": .init(isOff: false, name: ""),
            "2026-07-06": .init(isOff: true, name: "Taiwan-only closure")])
        let rules = AlarmCalendarSettings(isEnabled: true, source: .unitedStates)
        XCTAssertFalse(rules.decision(on: date(2026,7,3), weekdays: Set(1...7), holidays: cached, calendar: calendar).rings)
        XCTAssertTrue(rules.decision(on: date(2026,7,6), weekdays: Set(1...7), holidays: cached, calendar: calendar).rings)
        XCTAssertFalse(rules.decision(on: date(2026,7,6), weekdays: [], holidays: cached, calendar: calendar).rings)
        let taiwan = AlarmCalendarSettings(isEnabled: true, source: .taiwan)
        XCTAssertTrue(taiwan.decision(on: date(2026,7,3), weekdays: Set(1...7), holidays: cached, calendar: calendar).rings)
    }
    func testUnitedStatesManualOverrideMarkerComparesAgainstSelectedSource() {
        let day = date(2026, 11, 26)
        var rules = AlarmCalendarSettings(isEnabled: true, source: .unitedStates)
        rules.toggleDay(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar)
        XCTAssertTrue(rules.decision(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar).rings)
        XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar))
        rules.source = .taiwan
        XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar))
        rules.source = .unitedStates
        rules.toggleDay(on: day, weekdays: Set(1...7), holidays: .init(), calendar: calendar)
        XCTAssertNil(rules.overrides["2026-11-26"])
    }
    func testUnitedStatesCoverageFallbackDoesNotSilenceUnknownYears() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .unitedStates)
        for year in [1999, 2101] {
            XCTAssertEqual(rules.decision(on: date(year,1,1), weekdays: Set(1...7), holidays: .init(), calendar: calendar),
                DayDecision(rings: true, reason: .unavailable))
        }
        for year in [2000, 2100] {
            XCTAssertEqual(rules.decision(on: date(year,1,1), weekdays: Set(1...7), holidays: .init(), calendar: calendar),
                DayDecision(rings: false, reason: .holiday))
        }
    }
    func testUnitedStatesUsesUsersCivilDateAcrossTimeZones() {
        let instant = date(2026, 7, 4, 3)
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(AlarmCalendarSettings.key(for: instant, calendar: losAngeles), "2026-07-03")
        XCTAssertEqual(HolidayCalendar().day(on: instant, source: .unitedStates, calendar: losAngeles)?.name,
            "Independence Day (observed)")
        XCTAssertEqual(HolidayCalendar().day(on: instant, source: .unitedStates, calendar: calendar)?.name, "Independence Day")
    }
    func testUnitedStatesPlanSkipsThanksgivingAndKeepsFridayOffline() {
        var settings = CommuteAlarmSettings()
        settings.selectedWeekdays = [2,3,4,5,6]
        settings.alarmTime = date(2026,11,25,7,30)
        settings.calendarSettings = .init(isEnabled: true, source: .unitedStates)
        let plan = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false,
            now: date(2026,11,25,10), days: 3, calendar: calendar)
        XCTAssertEqual(plan.occurrences.map(\.normalDate), [date(2026,11,27,7,30)])
    }
    func testMakeUpDayDoesNotInventAnUnselectedWeekday() {
        let rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan)
        let day = date(2026, 9, 12)
        let holidays = HolidayCalendar(days: ["2026-09-12": .init(isOff: false, name: "補班")])
        XCTAssertFalse(rules.decision(on: day, weekdays: [2,3,4,5,6], holidays: holidays, calendar: calendar).rings)
    }
    func testEditMarkerComparesHolidayWorkingDayAndUnselectedWeekdayOutcomes() {
        let holidays = HolidayCalendar(days: [
            "2026-01-01": .init(isOff: true, name: "元旦"),
            "2026-01-02": .init(isOff: false, name: ""),
            "2026-09-12": .init(isOff: false, name: "補班")
        ])
        let rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan, overrides: [
            "2026-01-01": .ring, "2026-01-02": .silent, "2026-09-12": .ring
        ])
        for day in [date(2026, 1, 1), date(2026, 1, 2), date(2026, 9, 12)] {
            XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: [2,3,4,5,6], holidays: holidays, calendar: calendar))
        }
        XCTAssertFalse(rules.hasEffectiveOverride(on: date(2026, 1, 5), weekdays: [2], holidays: holidays, calendar: calendar))
    }
    func testTogglingAwayAndBackRemovesOverrideForEachBaseOutcome() {
        let holidays = HolidayCalendar(days: ["2026-01-01": .init(isOff: true, name: "元旦")])
        let weekdays: Set<Int> = [2,3,4,5,6]
        for day in [date(2026, 1, 1), date(2026, 1, 2), date(2026, 9, 12)] {
            var rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan)
            let original = rules.decision(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar)
            rules.toggleDay(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar)
            XCTAssertNotEqual(rules.decision(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar).rings, original.rings)
            XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar))
            rules.toggleDay(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar)
            XCTAssertNil(rules.overrides[AlarmCalendarSettings.key(for: day, calendar: calendar)])
            XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar))
            XCTAssertEqual(rules.decision(on: day, weekdays: weekdays, holidays: holidays, calendar: calendar), original)
        }
    }
    func testLegacyRedundantOverridesAreNotMarkedAndStayStoredUntilUserEdits() throws {
        let rules = try JSONDecoder().decode(AlarmCalendarSettings.self, from: Data(
            #"{"isEnabled":true,"source":"taiwan","overrides":{"2026-01-01":"silent","2026-01-02":"ring","2026-09-12":"silent"}}"#.utf8))
        let holidays = HolidayCalendar(days: ["2026-01-01": .init(isOff: true, name: "元旦")])
        for day in [date(2026, 1, 1), date(2026, 1, 2), date(2026, 9, 12)] {
            XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: [2,3,4,5,6], holidays: holidays, calendar: calendar))
        }
        XCTAssertEqual(rules.overrides.count, 3)
        var edited = rules
        let workingDay = date(2026, 1, 2)
        edited.toggleDay(on: workingDay, weekdays: [6], holidays: holidays, calendar: calendar)
        edited.toggleDay(on: workingDay, weekdays: [6], holidays: holidays, calendar: calendar)
        XCTAssertNil(edited.overrides["2026-01-02"], "Returning to normal removes latent manual-ring priority")
        XCTAssertEqual(edited.overrides["2026-01-01"], .silent)
    }
    func testEditMarkerRespondsToSourceAndHolidayChangesWithoutErasingIntent() {
        let day = date(2026, 1, 1)
        let holiday = HolidayCalendar(days: ["2026-01-01": .init(isOff: true, name: "元旦")])
        let workday = HolidayCalendar(days: ["2026-01-01": .init(isOff: false, name: "")])
        var rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan, overrides: ["2026-01-01": .ring])
        XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: [5], holidays: holiday, calendar: calendar))
        rules.source = .weekly
        XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: [5], holidays: holiday, calendar: calendar))
        rules.source = .taiwan
        XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: [5], holidays: workday, calendar: calendar))
        XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: [5], holidays: holiday, calendar: calendar))
        XCTAssertEqual(rules.overrides["2026-01-01"], .ring)
    }
    func testEditMarkerRespondsToWeekdayChangesAndDisabledCalendarPreservesIntent() {
        let day = date(2026, 1, 2)
        var rules = AlarmCalendarSettings(isEnabled: true, source: .taiwan, overrides: ["2026-01-02": .silent])
        XCTAssertTrue(rules.hasEffectiveOverride(on: day, weekdays: [6], holidays: .init(), calendar: calendar))
        XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: [], holidays: .init(), calendar: calendar))
        XCTAssertEqual(rules.overrides["2026-01-02"], .silent)
        rules.isEnabled = false
        XCTAssertFalse(rules.hasEffectiveOverride(on: day, weekdays: [6], holidays: .init(), calendar: calendar))
        rules.toggleDay(on: day, weekdays: [6], holidays: .init(), calendar: calendar)
        XCTAssertEqual(rules.overrides["2026-01-02"], .silent)
    }
    func testLegacySettingsAndFingerprintMigrateWithoutCreatingCalendarChanges() throws {
        let data = Data(#"{"homeAddress":"A","workAddress":"B"}"#.utf8)
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: data)
        XCTAssertFalse(settings.calendarSettings.isActive)
        XCTAssertTrue(settings.observesWorkSuspensions)
        XCTAssertFalse(settings.observesSchoolSuspensions)
        XCTAssertNil(settings.scheduleFingerprint().calendarSettings)
        let restored = try JSONDecoder().decode(CommuteAlarmSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }
    func testPreferencesAreIndependentAndDoNotChangeAlarmFingerprint() {
        var settings = CommuteAlarmSettings()
        let original = settings.scheduleFingerprint()
        settings.observesSchoolSuspensions = true
        settings.observesWorkSuspensions = false
        settings.timeFormat = .twentyFourHour
        XCTAssertEqual(settings.scheduleFingerprint(), original)
        settings.calendarSettings.isEnabled = true
        settings.calendarSettings.source = .weekly
        settings.calendarSettings.overrides["2026-10-10"] = .ring
        XCTAssertNotEqual(settings.scheduleFingerprint(), original)
    }
    func testBundledYearsAreCompleteAndNewYearIsOff() throws {
        let holidays = HolidayCalendar.load(storage: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(holidays.days.count, 730)
        XCTAssertEqual(holidays.days["2026-01-01"]?.isOff, true)
        XCTAssertEqual(holidays.days["2027-01-01"]?.isOff, true)
        XCTAssertEqual(holidays.days["2026-01-02"]?.isOff, false)
    }
    func testHTMLIncompleteYearAndDuplicatesAreRejected() throws {
        XCTAssertThrowsError(try HolidayCalendar.parseCSV(Data("<html>error</html>".utf8), year: 2026, encoding: "UTF-8"))
        XCTAssertThrowsError(try HolidayCalendar.parseCSV(Data("西元日期,星期,是否放假,備註\n20260101,四,2,元旦\n".utf8), year: 2026, encoding: "UTF-8"))
        let url = try XCTUnwrap(Bundle.main.url(forResource: "holidays-2026", withExtension: "csv"))
        var data = try Data(contentsOf: url)
        data.append(Data("20260101,四,2,重複\r\n".utf8))
        XCTAssertThrowsError(try HolidayCalendar.parseCSV(data, year: 2026, encoding: "UTF-8"))
    }
    func testRainCrossingMidnightUsesTheNormalDayOverride() {
        var settings = CommuteAlarmSettings()
        settings.alarmTime = date(2026, 9, 10, 0, 15)
        settings.rainLeadTimeMinutes = 30
        settings.calendarSettings.isEnabled = true
        settings.calendarSettings.source = .weekly
        settings.calendarSettings.overrides["2026-09-11"] = .silent
        let plan = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: true,
            now: date(2026, 9, 10, 22), days: 4, calendar: calendar)
        XCTAssertEqual(plan.occurrences.first?.normalDate, date(2026, 9, 12, 0, 15))
        XCTAssertEqual(plan.occurrences.first?.ringDate, date(2026, 9, 11, 23, 45))
    }
    func testOneYearPlanIncludesLeapDayAndNeverSchedulesInThePast() {
        var settings = CommuteAlarmSettings()
        settings.alarmTime = date(2028, 1, 1, 7, 30)
        let now = date(2028, 1, 1, 10)
        let plan = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: now, days: 366, calendar: calendar)
        XCTAssertEqual(plan.occurrences.count, 365)
        XCTAssertTrue(plan.occurrences.allSatisfy { $0.ringDate > now })
        XCTAssertTrue(plan.occurrences.contains { $0.normalDate == date(2028, 2, 29, 7, 30) })
        XCTAssertEqual(plan.coveredUntil, date(2029, 1, 1))
    }
    func testNoRingingDaysStillHasACoverageBoundary() {
        var settings = CommuteAlarmSettings()
        settings.selectedWeekdays = []
        let plan = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: date(2026, 9, 10), days: 27, calendar: calendar)
        XCTAssertTrue(plan.occurrences.isEmpty)
        XCTAssertEqual(plan.coveredUntil, date(2026, 10, 7))
    }
    func testRestoredSummaryAdvancesOverSilentDatesUsingTheActualRegisteredPlan() {
        var settings = CommuteAlarmSettings()
        settings.alarmTime = date(2026, 9, 10, 7, 30)
        settings.calendarSettings.isEnabled = true
        settings.calendarSettings.source = .weekly
        settings.calendarSettings.overrides["2026-09-11"] = .silent
        let plan = CalendarAlarmPlan.make(settings: settings, holidays: .init(), rain: false, now: date(2026, 9, 10), days: 4, calendar: calendar)
        let first = plan.occurrences[0]
        let summary = ScheduledAlarmSummary(normalAlarmDate: first.normalDate, scheduledAlarmDate: first.ringDate,
            weatherRefreshDate: first.normalDate.addingTimeInterval(-1800), exceedsRainThreshold: false,
            leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.1, calendarPlan: plan)
        let restored = summary.rollingForward(selectedWeekdays: Set(1...7), now: date(2026, 9, 10, 10), calendar: calendar)
        XCTAssertEqual(restored.normalAlarmDate, date(2026, 9, 12, 7, 30))
    }
    func testEveningPreviewSaysDayOffAndIncludesManualWeekendRing() throws {
        var settings = CommuteAlarmSettings()
        settings.selectedWeekdays = [2,3,4,5,6]
        settings.alarmTime = date(2026, 9, 10, 7, 30)
        settings.calendarSettings.isEnabled = true
        settings.calendarSettings.source = .weekly
        settings.calendarSettings.overrides = ["2026-09-11": .silent, "2026-09-12": .ring]
        let summary = ScheduledAlarmSummary(normalAlarmDate: date(2026, 9, 12, 7, 30), scheduledAlarmDate: date(2026, 9, 12, 7, 30),
            weatherRefreshDate: date(2026, 9, 12, 7), exceedsRainThreshold: false, leadTimeMinutes: 0,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.1)
        let previews = EveningPreviewPlanner.plan(summary: summary, selectedWeekdays: settings.selectedWeekdays,
            previewTime: date(2026, 9, 10, 21), checkedAt: date(2026, 9, 10), now: date(2026, 9, 10, 12),
            canRefreshInBackground: true, calendar: calendar, calendarSettings: settings.calendarSettings)
        XCTAssertTrue(previews.contains { if case .dayOff(normalAlarmDate: date(2026, 9, 11, 7, 30)) = $0.kind { true } else { false } })
        XCTAssertTrue(previews.contains { $0.identifier.hasSuffix("20260912") })
        XCTAssertLessThanOrEqual(previews.count, 7)
    }
}

@MainActor
final class CalendarSchedulingTests: XCTestCase {
    // Calendar scheduling tests must not depend on the host app's cached
    // StoreKit purchases or membership startup timing. Rights enforcement is
    // covered separately by MembershipSchedulingTests.
    private static let calendarEntitlements = MembershipEntitlements(
        removeBanner: true, calendar: true, temporaryClosures: false,
        dailyAI: true, subscriptionActive: false, lifetimeActive: true)

    func testRainOnlyUsesEarlySoundOnTheForecastedCalendarOccurrence() async throws {
        let suite = "CalendarSoundTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let scheduler = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: scheduler,
            settingsStorage: storage, holidayCalendar: .init(),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Rain Street"; vm.settings.workAddress = "Office"
        vm.settings.alarmTime = Date().addingTimeInterval(3 * 3_600)
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        vm.settings.alarmSound = .softPiano
        vm.settings.earlyAlarmSound = .digitalBeep
        await vm.evaluateRouteAndScheduleAlarm()
        let plan = try XCTUnwrap(scheduler.plans.first)
        XCTAssertGreaterThan(plan.occurrences.count, 1)
        XCTAssertEqual(plan.occurrences.first?.soundSelection?.sound, .digitalBeep)
        XCTAssertTrue(plan.occurrences.dropFirst().allSatisfy { $0.soundSelection?.sound == .softPiano })
        let restored = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            membershipEntitlements: { Self.calendarEntitlements })
        XCTAssertEqual(restored.scheduledAlarmSummary?.calendarPlan, plan)
    }

    func testViewModelToggleBackRestoresBaseFingerprintAndPersistsNoOverride() throws {
        let suite = "CalendarToggleTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let vm = AlarmViewModel(notificationScheduler: CalendarSchedulerSpy(), settingsStorage: storage, holidayCalendar: .init(),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.calendarSettings = .init(isEnabled: true, source: .taiwan)
        vm.settings.selectedWeekdays = Set(1...7)
        let day = AlarmCalendarSettings.calendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 12))!
        let original = vm.settings.scheduleFingerprint()
        vm.toggleCalendarDay(day)
        XCTAssertTrue(vm.calendarDayIsEdited(day))
        XCTAssertFalse(vm.dayDecision(on: day).rings)
        vm.toggleCalendarDay(day)
        XCTAssertFalse(vm.calendarDayIsEdited(day))
        XCTAssertTrue(vm.dayDecision(on: day).rings)
        XCTAssertEqual(vm.settings.scheduleFingerprint(), original)
        let restored = AlarmViewModel(notificationScheduler: CalendarSchedulerSpy(), settingsStorage: storage, holidayCalendar: .init(),
            membershipEntitlements: { Self.calendarEntitlements })
        XCTAssertTrue(restored.settings.calendarSettings.overrides.isEmpty)
        XCTAssertFalse(restored.calendarDayIsEdited(day))
    }

    func testSlowForecastDoesNotPreventCalendarRegistration() async throws {
        let suite = "CalendarSchedulingTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let scheduler = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: SlowCalendarWeather(), notificationScheduler: scheduler,
            settingsStorage: storage, calendarWeatherTimeout: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        await vm.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(scheduler.plans.count, 1)
        XCTAssertTrue(vm.hasScheduledAlarm)
        XCTAssertNil(vm.scheduledAlarmSummary?.calendarForecastDate)
        XCTAssertFalse(vm.isScheduling)
    }

    func testEditingCalendarReRegistersOfflineAndSurvivesRelaunch() async throws {
        let suite = "CalendarSchedulingTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let scheduler = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: scheduler,
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        await vm.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(vm.hasScheduledAlarm)
        let next = try XCTUnwrap(vm.scheduledAlarmSummary?.normalAlarmDate)
        vm.toggleCalendarDay(next)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(scheduler.plans.count, 2)
        XCTAssertFalse(scheduler.plans.last!.occurrences.contains { $0.normalDate == next })
        XCTAssertFalse(vm.isScheduleStale)
        let restored = AlarmViewModel(notificationScheduler: scheduler, settingsStorage: storage,
            membershipEntitlements: { Self.calendarEntitlements })
        XCTAssertEqual(restored.settings.calendarSettings, vm.settings.calendarSettings)
    }
    func testReturningToWeeklyScheduleWorksOffline() async throws {
        let suite = "CalendarSchedulingTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let scheduler = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: scheduler,
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        await vm.evaluateRouteAndScheduleAlarm()
        vm.settings.calendarSettings.source = .weekly
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(scheduler.weeklyCalls, 1)
        XCTAssertNil(vm.scheduledAlarmSummary?.calendarPlan)
        XCTAssertFalse(vm.isScheduleStale)
    }

    func testOfflineCalendarNeverClaimsToHaveFetchedADryForecast() async throws {
        let suite = "CalendarSchedulingTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: CalendarSchedulerSpy(), settingsStorage: storage,
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        await vm.evaluateRouteAndScheduleAlarm()
        let summary = try XCTUnwrap(vm.scheduledAlarmSummary)
        XCTAssertNil(summary.calendarForecastDate)
        XCTAssertEqual(summary.normalAlarmDate, summary.scheduledAlarmDate)
    }

    func testRegistrationFailureKeepsOldSummaryAndMarksChangesUnapplied() async throws {
        let suite = "CalendarSchedulingTests-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let scheduler = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: scheduler,
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings.isEnabled = true
        vm.settings.calendarSettings.source = .taiwan
        await vm.evaluateRouteAndScheduleAlarm()
        let old = try XCTUnwrap(vm.scheduledAlarmSummary)
        scheduler.fails = true
        vm.toggleCalendarDay(old.normalAlarmDate)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vm.scheduledAlarmSummary, old)
        XCTAssertTrue(vm.isScheduleStale)
        XCTAssertTrue(vm.hasScheduledAlarm)
    }
}

/// "Turn off only the next alarm" (1.8.0): free, offline, and back to one weekly alarm after.
@MainActor
final class SkipNextAlarmTests: XCTestCase {
    private static let free = MembershipEntitlements(removeBanner: false, calendar: false, temporaryClosures: false,
                                                    dailyAI: false, subscriptionActive: false, lifetimeActive: false)
    private var storage: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "SkipNextAlarmTests-\(UUID())"
        storage = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        storage.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func weeklyModel(_ scheduler: CalendarSchedulerSpy, inProgress: @escaping @MainActor () -> Bool = { false },
                             home: String = "Clear Street", notificationAlarms: Bool = false) async -> AlarmViewModel {
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: scheduler,
            settingsStorage: storage, holidayCalendar: .init(), autoRefreshDebounce: .seconds(60),
            membershipEntitlements: { Self.free }, alarmInProgress: inProgress, usesNotificationAlarms: notificationAlarms)
        model.settings.homeAddress = home; model.settings.workAddress = "Office"
        model.settings.selectedWeekdays = Set(1...7)
        model.settings.alarmTime = Date().addingTimeInterval(3 * 3_600)
        await model.evaluateRouteAndScheduleAlarm()
        return model
    }

    func testSkipNextOnAWeeklyAlarmRegistersADatedPlanWithoutThatMorning() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler)
        XCTAssertEqual(scheduler.weeklyCalls, 1)
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail("\(model.skipAvailability())") }

        let skipped = await model.skipNextAlarm(target)
        XCTAssertTrue(skipped)
        XCTAssertEqual(scheduler.weeklyCalls, 1)
        let plan = try XCTUnwrap(scheduler.plans.last)
        XCTAssertEqual(scheduler.plans.count, 1)
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == target.normalDate })
        XCTAssertTrue(plan.occurrences.contains { $0.normalDate > target.normalDate }, "Later mornings stay registered")
        XCTAssertEqual(model.scheduledAlarmSummary?.userSkippedNormalDate, target.normalDate)
        XCTAssertEqual(model.liveSkippedAlarmDate(), target.normalDate)
        XCTAssertFalse(model.isAlarmSwitchOn())
        XCTAssertFalse(model.isScheduleStale)
        XCTAssertNotNil(model.ringAfterSkip())
        let status = model.tomorrowStatus()
        if AlarmCalendarSettings.calendar.isDate(status.normalAlarmDate, equalTo: target.normalDate, toGranularity: .minute) {
            XCTAssertEqual(status.reason, .skippedOnce)
            XCTAssertFalse(status.ringIsNotRegistered)
        }
    }

    func testTurningTheSwitchBackOnUndoesTheSkip() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        _ = await model.skipNextAlarm(target)
        await model.turnAlarmOn()
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertEqual(scheduler.weeklyCalls, 2, "A free weekly user is back on one repeating alarm")
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
        XCTAssertTrue(model.isAlarmSwitchOn())
    }

    func testASpentSkipIsRetiredBackToTheWeeklyAlarm() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        _ = await model.skipNextAlarm(target)
        // The skipped morning has passed (any time of day: a stored key for yesterday).
        model.settings.skippedAlarmDay = AlarmCalendarSettings.key(for: Date().addingTimeInterval(-86_400))
        await model.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertGreaterThanOrEqual(scheduler.weeklyCalls, 2)
        XCTAssertNil(model.scheduledAlarmSummary?.calendarPlan)
    }

    func testSkipWaitsWhileAWeeklyAlarmRings() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler, inProgress: { true })
        XCTAssertEqual(model.skipAvailability(), .alarmInProgress)
        let target = CalendarAlarmPlan.Occurrence(normalDate: Date().addingTimeInterval(3 * 3_600),
                                                  ringDate: Date().addingTimeInterval(3 * 3_600))
        let skipped = await model.skipNextAlarm(target)
        XCTAssertFalse(skipped)
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertTrue(scheduler.plans.isEmpty)
    }

    func testASkipForAMorningThatIsNoLongerNextIsRejected() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        let stale = CalendarAlarmPlan.Occurrence(normalDate: target.normalDate.addingTimeInterval(86_400),
                                                 ringDate: target.ringDate.addingTimeInterval(86_400))
        let skipped = await model.skipNextAlarm(stale)
        XCTAssertFalse(skipped)
        XCTAssertNil(model.settings.skippedAlarmDay)
    }

    /// Skipping a rainy morning and turning the switch straight back on must bring back
    /// its rain-advanced ring, not the normal time (adversarial review).
    func testUndoingASkipRestoresTheSkippedMorningsRainDecision() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler, home: "Rain Street")
        let armed = try XCTUnwrap(model.scheduledAlarmSummary)
        XCTAssertTrue(armed.exceedsRainThreshold)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        XCTAssertEqual(target.normalDate, armed.normalAlarmDate)
        _ = await model.skipNextAlarm(target)
        XCTAssertEqual(model.scheduledAlarmSummary?.skippedMorningForecast?.normalDate, target.normalDate)
        await model.turnAlarmOn()
        let restored = try XCTUnwrap(model.scheduledAlarmSummary)
        XCTAssertEqual(restored.normalAlarmDate, armed.normalAlarmDate)
        XCTAssertEqual(restored.scheduledAlarmDate, armed.scheduledAlarmDate, "Still the rain-advanced ring")
        XCTAssertEqual(restored.leadTimeMinutes, armed.leadTimeMinutes)
    }

    /// The widget merge (D-D with the skip's saved forecast): after a relaunch past an early
    /// ring the stored weekly summary names the NEXT morning, but its lead was decided for the
    /// morning that rang. Skipping that next morning must not save the carried lead as its
    /// decision, or undoing the skip would register a rain-advanced ring no forecast decided.
    func testUndoingASkipDoesNotRestoreALeadCarriedOntoTheSkippedMorning() async throws {
        let calendar = AlarmCalendarSettings.calendar
        let minute = try XCTUnwrap(calendar.dateInterval(of: .minute, for: Date())).start
        let decided = minute.addingTimeInterval(-2 * 3_600)
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: decided))
        var settings = CommuteAlarmSettings()
        settings.homeAddress = "Clear Street"; settings.workAddress = "Office"
        settings.selectedWeekdays = Set(1...7)
        settings.alarmTime = decided
        settings.rainLeadTimeMinutes = 30
        settings.rainProbabilityThreshold = 0.5
        // Decided two hours ago for that morning's rain; its early ring has gone off.
        let summary = ScheduledAlarmSummary(normalAlarmDate: decided, scheduledAlarmDate: decided.addingTimeInterval(-1_800),
            weatherRefreshDate: decided.addingTimeInterval(-1_800), exceedsRainThreshold: true, leadTimeMinutes: 30,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8, decisionNormalAlarmDate: decided)
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        storage.set(try JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try JSONEncoder().encode(settings.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let scheduler = CalendarSchedulerSpy()
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: scheduler,
            settingsStorage: storage, holidayCalendar: .init(), autoRefreshDebounce: .seconds(60),
            membershipEntitlements: { Self.free }, alarmInProgress: { false }, usesNotificationAlarms: false)
        XCTAssertEqual(model.scheduledAlarmSummary?.normalAlarmDate, next, "The relaunch rolled it on")
        XCTAssertEqual(model.scheduledAlarmSummary?.decisionNormalAlarmDate, decided)
        XCTAssertTrue(model.tomorrowStatus().rainLeadIsCarriedOver, "The card waits for the next morning's own forecast")

        guard case .available(let target) = model.skipAvailability() else { return XCTFail("\(model.skipAvailability())") }
        XCTAssertEqual(target.normalDate, next)
        let skipped = await model.skipNextAlarm(target)
        XCTAssertTrue(skipped)
        XCTAssertNil(model.scheduledAlarmSummary?.skippedMorningForecast, "No forecast decided the skipped morning")

        await model.turnAlarmOn()
        let restored = try XCTUnwrap(model.scheduledAlarmSummary)
        XCTAssertNil(restored.calendarPlan, "A free user is back on the weekly alarm")
        XCTAssertEqual(restored.normalAlarmDate, next)
        XCTAssertEqual(restored.scheduledAlarmDate, next, "The normal time, as a live process would register it")
        XCTAssertFalse(restored.exceedsRainThreshold)
        XCTAssertEqual(restored.decisionNormalAlarmDate, next)
    }

    /// iOS 17–25: going back to the weekly plan while today's follow-up chain would still
    /// fire re-adds those follow-ups, so retiring waits (adversarial review).
    func testRetireWaitsWhileTodaysNotificationFollowUpsWouldRevive() async throws {
        for notificationAlarms in [true, false] {
            try await retireRightAfterTodaysRing(notificationAlarms: notificationAlarms)
        }
    }

    /// Today's skipped morning rang (would have rung) ten minutes ago, so the skip is spent.
    /// On notification alarms its follow-ups would still be firing: retire waits. AlarmKit
    /// has no follow-up chain to revive: retire proceeds.
    private func retireRightAfterTodaysRing(notificationAlarms: Bool) async throws {
        let hour = AlarmCalendarSettings.calendar.component(.hour, from: Date())
        try XCTSkipIf(hour == 0, "Near midnight 'ten minutes ago' is yesterday")
        storage.removePersistentDomain(forName: suite)
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler, notificationAlarms: notificationAlarms)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        _ = await model.skipNextAlarm(target)
        model.settings.alarmTime = Date().addingTimeInterval(-10 * 60)
        model.settings.skippedAlarmDay = AlarmCalendarSettings.key(for: Date())
        XCTAssertNil(model.liveSkippedAlarmDate(), "Spent")
        await model.refreshScheduledAlarmIfWeatherIsStale()
        if notificationAlarms {
            XCTAssertNotNil(model.settings.skippedAlarmDay, "Retire waits for today's follow-ups to end")
        } else {
            XCTAssertNil(model.settings.skippedAlarmDay, "Nothing to revive on AlarmKit")
        }
    }

    /// Owner decision, 2026-09-30: once this morning has rung early, "turn off only the next
    /// alarm" is offered at once — for tomorrow — instead of waiting for this morning's
    /// normal time. Neither the skip nor undoing it may bring this morning's normal ring back.
    func testAfterTodaysEarlyRingTheNextAlarmCanBeSkippedAtOnce() async throws {
        let calendar = AlarmCalendarSettings.calendar
        let now = Date()
        var settings = CommuteAlarmSettings()
        settings.homeAddress = "Clear Street"; settings.workAddress = "Office"
        settings.selectedWeekdays = Set(1...7)
        settings.alarmTime = now.addingTimeInterval(10 * 60)
        settings.rainLeadTimeMinutes = 30
        let normal = TomorrowWeatherRequest(settings: settings, now: now).normalAlarmDate
        let early = normal.addingTimeInterval(-30 * 60)
        try XCTSkipUnless(calendar.isDate(early, inSameDayAs: normal) && calendar.isDate(now, inSameDayAs: normal),
                          "The window must sit inside one calendar day")
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: normal))
        // Registered last night for a rainy morning; the 30-minutes-early ring has gone off.
        let summary = ScheduledAlarmSummary(normalAlarmDate: normal, scheduledAlarmDate: early, weatherRefreshDate: early,
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.72)
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        storage.set(try JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try JSONEncoder().encode(settings.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let scheduler = CalendarSchedulerSpy()
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: scheduler,
            settingsStorage: storage, holidayCalendar: .init(), autoRefreshDebounce: .seconds(60),
            membershipEntitlements: { Self.free }, alarmInProgress: { false }, usesNotificationAlarms: false)

        guard case .available(let target) = model.skipAvailability() else { return XCTFail("\(model.skipAvailability())") }
        XCTAssertEqual(target.normalDate, tomorrow, "This morning already rang, so the next alarm is tomorrow's")
        let skipped = await model.skipNextAlarm(target)
        XCTAssertTrue(skipped)
        let plan = try XCTUnwrap(scheduler.plans.last)
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == normal }, "This morning must not ring again")
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == tomorrow })
        XCTAssertEqual(model.liveSkippedAlarmDate(), tomorrow)
        XCTAssertTrue(model.tomorrowStatus().hasRung, "The card still says this morning rang")

        await model.turnAlarmOn()
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertEqual(scheduler.weeklyCalls, 1)
        XCTAssertEqual(model.scheduledAlarmSummary?.scheduledAlarmDate, early,
                       "Undoing the skip keeps the weekly clock on the ring that already went off")
    }

    /// A process that stays alive across mornings holds its weekly registration as it was
    /// registered; only a relaunch rolls it forward (merge review, 2026-10-01). Registered for
    /// yesterday's rain (07:00 for 07:30) and never re-registered since, AlarmKit's weekly
    /// repeat rang 07:00 again this morning. The model sits ~10 minutes after that ring, 20
    /// before the normal time, reading yesterday's summary.
    private func liveModelAfterACarriedEarlyRing(_ scheduler: CalendarSchedulerSpy, weather: RouteWeatherService)
        throws -> (model: AlarmViewModel, normal: Date, early: Date) {
        let calendar = AlarmCalendarSettings.calendar
        let now = Date()
        var settings = CommuteAlarmSettings()
        settings.homeAddress = "Clear Street"; settings.workAddress = "Office"
        settings.selectedWeekdays = Set(1...7)
        settings.alarmTime = now.addingTimeInterval(20 * 60)
        settings.rainLeadTimeMinutes = 30
        let normal = TomorrowWeatherRequest(settings: settings, now: now).normalAlarmDate
        let early = normal.addingTimeInterval(-30 * 60)
        try XCTSkipUnless(calendar.isDate(early, inSameDayAs: normal) && calendar.isDate(now, inSameDayAs: normal),
                          "The window must sit inside one calendar day")
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: normal))
        let yesterdayEarly = yesterday.addingTimeInterval(-30 * 60)
        let held = ScheduledAlarmSummary(normalAlarmDate: yesterday, scheduledAlarmDate: yesterdayEarly,
            weatherRefreshDate: yesterdayEarly, exceedsRainThreshold: true, leadTimeMinutes: 30,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8, wettestSegmentName: "路程 ½",
            decisionNormalAlarmDate: yesterday)
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        storage.set(try JSONEncoder().encode(settings.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let model = AlarmViewModel(routeWeatherService: weather, notificationScheduler: scheduler,
            settingsStorage: storage, holidayCalendar: .init(), autoRefreshDebounce: .seconds(60),
            membershipEntitlements: { Self.free }, alarmInProgress: { false }, usesNotificationAlarms: false)
        model.holdRegistrationForTesting(held)
        // The card already reads it as a relaunch does: this morning rang at the carried 07:00.
        let card = model.tomorrowStatus()
        XCTAssertEqual(card.normalAlarmDate, normal)
        XCTAssertTrue(card.hasRung)
        XCTAssertEqual(card.expectedRingDate, early)
        XCTAssertFalse(card.ringIsNotRegistered)
        return (model, normal, early)
    }

    /// The scheduler must read what the card reads. An unattended run inside this morning's
    /// window (no network) re-armed the normal time, and the one-time skip kept this morning's
    /// 07:30 in its dated plan: either way this morning rang a second time.
    func testALiveProcessNeverRingsACarriedEarlyMorningAgain() async throws {
        let scheduler = CalendarSchedulerSpy()
        let (model, normal, early) = try liveModelAfterACarriedEarlyRing(scheduler, weather: OfflineCalendarWeather())
        let tomorrow = try XCTUnwrap(AlarmCalendarSettings.calendar.date(byAdding: .day, value: 1, to: normal))

        let changed = await model.refreshScheduledAlarmUnattended()
        XCTAssertFalse(changed)
        XCTAssertFalse(scheduler.weeklyRings.contains { $0.ringDate == normal }, "This morning's 07:30 must not be armed")
        XCTAssertEqual(scheduler.weeklyCalls, 0, "Inside this morning's window an unattended run leaves the alarm alone")
        XCTAssertTrue(scheduler.plans.isEmpty)

        guard case .available(let target) = model.skipAvailability() else { return XCTFail("\(model.skipAvailability())") }
        XCTAssertEqual(target.normalDate, tomorrow, "This morning already rang, so the next alarm is tomorrow's")
        let skipped = await model.skipNextAlarm(target)
        XCTAssertTrue(skipped)
        let plan = try XCTUnwrap(scheduler.plans.last)
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == normal }, "This morning must not ring again")
        XCTAssertFalse(plan.occurrences.contains { $0.normalDate == tomorrow })
        XCTAssertEqual(model.scheduledAlarmSummary?.firedEarlyRing, .init(normalDate: normal, ringDate: early),
                       "The carried ring is recorded as this morning's")
        XCTAssertTrue(model.tomorrowStatus().hasRung)

        await model.turnAlarmOn()
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertEqual(scheduler.weeklyRings.last, .init(normalDate: normal, ringDate: early),
                       "Undoing the skip keeps the weekly clock on the 07:00 that already went off")
        XCTAssertFalse(scheduler.weeklyRings.contains { $0.ringDate == normal })
    }

    /// The foreground path (an edit, Retry, opening the app with an old decision) registers
    /// this morning's own decision inside its window; it too must see the carried ring.
    func testALiveProcessKeepsTheCarriedRingOnAForegroundRun() async throws {
        let scheduler = CalendarSchedulerSpy()
        let (model, normal, early) = try liveModelAfterACarriedEarlyRing(scheduler, weather: MockRouteWeatherService())
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(scheduler.weeklyRings, [.init(normalDate: normal, ringDate: early)],
                       "The weekly clock stays on the 07:00 that already went off")
        XCTAssertEqual(model.scheduledAlarmSummary?.firedEarlyRing, .init(normalDate: normal, ringDate: early))
        XCTAssertEqual(model.scheduledAlarmSummary?.decisionNormalAlarmDate, normal)
        let card = model.tomorrowStatus()
        XCTAssertTrue(card.hasRung)
        XCTAssertEqual(card.expectedRingDate, early)
        XCTAssertFalse(card.ringIsNotRegistered)
    }

    func testTurningOffWhileSkippingClearsTheSkip() async throws {
        let scheduler = CalendarSchedulerSpy()
        let model = await weeklyModel(scheduler)
        guard case .available(let target) = model.skipAvailability() else { return XCTFail() }
        _ = await model.skipNextAlarm(target)
        await model.turnAlarmOff()
        XCTAssertNil(model.settings.skippedAlarmDay)
        XCTAssertFalse(model.hasScheduledAlarm)
        XCTAssertGreaterThanOrEqual(scheduler.cancellations, 1)
    }
}

private final class CalendarSchedulerSpy: NotificationScheduling, @unchecked Sendable {
    var plans: [CalendarAlarmPlan] = []
    var fails = false
    var weeklyCalls = 0
    /// Each weekly registration's ring and the normal time it serves, in order.
    var weeklyRings: [CalendarAlarmPlan.Occurrence] = []
    func requestAuthorization() async throws -> Bool { true }
    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>, sound: CommuteAlarmSettings.AlarmSound,
                       soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        weeklyCalls += 1
        weeklyRings.append(.init(normalDate: normalAlarmDate, ringDate: date))
    }
    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound, soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        if fails { throw URLError(.cannotConnectToHost) }
        plans.append(plan)
    }
    var cancellations = 0
    func cancelScheduledAlarms() async { cancellations += 1 }
}
private struct OfflineCalendarWeather: RouteWeatherService {
    func fetchRouteWeather(from homeAddress: String, homeLocation: ResolvedMapLocation?, to workAddress: String,
                           workLocation: ResolvedMapLocation?, mode: CommuteAlarmSettings.CommuteMode, around commuteTime: Date) async throws -> RouteWeatherSnapshot {
        throw URLError(.notConnectedToInternet)
    }
}

private struct SlowCalendarWeather: RouteWeatherService {
    func fetchRouteWeather(from homeAddress: String, homeLocation: ResolvedMapLocation?, to workAddress: String,
                           workLocation: ResolvedMapLocation?, mode: CommuteAlarmSettings.CommuteMode, around commuteTime: Date) async throws -> RouteWeatherSnapshot {
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
    }
}

final class SettingsPreferenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return value
    }
    func testCalendarOffIgnoresAndPreservesManualDatesAndHolidays() {
        var rules = AlarmCalendarSettings(isEnabled: true, overrides: ["2026-09-11": .silent, "2026-09-12": .ring])
        let friday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let saturday = calendar.date(byAdding: .day, value: 1, to: friday)!
        let holidays = HolidayCalendar(days: ["2026-09-11": .init(isOff: true, name: "Holiday")])
        XCTAssertFalse(rules.decision(on: friday, weekdays: [6], holidays: holidays, calendar: calendar).rings)
        rules.isEnabled = false
        XCTAssertTrue(rules.decision(on: friday, weekdays: [6], holidays: holidays, calendar: calendar).rings)
        XCTAssertFalse(rules.decision(on: saturday, weekdays: [6], holidays: holidays, calendar: calendar).rings)
        XCTAssertEqual(rules.overrides.count, 2)
        rules.isEnabled = true
        XCTAssertTrue(rules.decision(on: saturday, weekdays: [6], holidays: holidays, calendar: calendar).rings)
    }
    func testExistingCalendarChoiceMigratesAndExplicitOffSurvivesRelaunch() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(AlarmCalendarSettings.self, from: Data(#"{"source":"taiwan","overrides":{}}"#.utf8))
        XCTAssertTrue(old.isEnabled)
        let weekly = try decoder.decode(AlarmCalendarSettings.self, from: Data(#"{"source":"weekly","overrides":{}}"#.utf8))
        XCTAssertFalse(weekly.isEnabled)
        var settings = CommuteAlarmSettings()
        settings.calendarSettings = old
        settings.calendarSettings.isEnabled = false
        settings.timeFormat = .twentyFourHour
        let restored = try decoder.decode(CommuteAlarmSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.calendarSettings.isEnabled)
        XCTAssertEqual(restored.calendarSettings.source, .taiwan)
        XCTAssertEqual(restored.timeFormat, .twentyFourHour)
        XCTAssertNil(restored.scheduleFingerprint().calendarSettings)
    }
    func testHourCycleUsesOnlyAMPMAtMidnightNoonAndNight() {
        let locale = Locale(identifier: "zh_Hant_TW")
        for (hour, twelve, twentyFour) in [(0,"上午 12:05","00:05"),(7,"上午 7:05","07:05"),(12,"下午 12:05","12:05"),(23,"下午 11:05","23:05")] {
            let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: hour, minute: 5))!
            XCTAssertEqual(ClockTimeFormat.twelveHour.time(date, locale: locale, timeZone: calendar.timeZone), twelve)
            XCTAssertEqual(ClockTimeFormat.twentyFourHour.time(date, locale: locale, timeZone: calendar.timeZone), twentyFour)
        }
    }
    func testPreviewFormatChangesTextWithoutChangingFireDate() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 13, minute: 5))!
        var preview = EveningPreview(identifier: "test", fireDate: date, kind: .upcoming(normalAlarmDate: date), canRefreshInBackground: true, timeFormat: .twelveHour)
        XCTAssertTrue(EveningPreviewText.body(for: preview).contains(ClockTimeFormat.twelveHour.time(date)))
        let originalBody = EveningPreviewText.body(for: preview)
        preview.timeFormat = .twentyFourHour
        XCTAssertTrue(EveningPreviewText.body(for: preview).contains(ClockTimeFormat.twentyFourHour.time(date)))
        XCTAssertNotEqual(EveningPreviewText.body(for: preview), originalBody)
        XCTAssertEqual(preview.fireDate, date)
    }
    func testMapDistrictUsesStructuredCountyAndDistrictAndNormalizesTai() {
        XCTAssertEqual(TaiwanMapDistrict.match(countryCode: "TW", components: ["台南市", "善化區"]), "臺南市善化區")
        XCTAssertEqual(TaiwanMapDistrict.match(countryCode: "TW", components: ["台南市", "新市區"]), "臺南市新市區")
        XCTAssertEqual(TaiwanMapDistrict.match(countryCode: "TW", components: ["臺北市", "信義區"]), "臺北市信義區")
        XCTAssertNil(TaiwanMapDistrict.match(countryCode: "TW", components: ["東區"]))
        XCTAssertNil(TaiwanMapDistrict.match(countryCode: "US", components: ["臺北市", "信義區"]))
        XCTAssertNil(TaiwanMapDistrict.match(countryCode: "TW", components: ["臺北市", "臺南市", "東區", "信義區"]))
    }
    func testOldMapCoordinatesDecodeWithoutInventingDistrict() throws {
        let old = ResolvedMapLocation(latitude: 23.1, longitude: 120.3, displayAddress: "Map point", resolution: .exact)
        let restored = try JSONDecoder().decode(ResolvedMapLocation.self, from: JSONEncoder().encode(old))
        XCTAssertNil(restored.districtName)
    }
}

@MainActor
final class SettingsPreferenceSchedulingTests: XCTestCase {
    // These preference transitions require calendar access regardless of what
    // an earlier StoreKit test purchased, refunded, or left in the host cache.
    private static let calendarEntitlements = MembershipEntitlements(
        removeBanner: true, calendar: true, temporaryClosures: false,
        dailyAI: true, subscriptionActive: false, lifetimeActive: true)
    private var storage: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SettingsPreferenceTests-\(UUID())"
        storage = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        storage.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testCalendarSwitchOffRestoresWeeklyAndRetainsOverrides() async throws {
        let spy = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: spy,
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings = .init(isEnabled: true, overrides: ["2027-01-01": .ring])
        await vm.evaluateRouteAndScheduleAlarm()
        vm.settings.calendarSettings.isEnabled = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(spy.weeklyCalls, 1)
        XCTAssertNil(vm.scheduledAlarmSummary?.calendarPlan)
        XCTAssertEqual(vm.settings.calendarSettings.overrides["2027-01-01"], .ring)
        XCTAssertFalse(vm.isScheduleStale)
        vm.settings.calendarSettings.isEnabled = true
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(spy.plans.count, 2)
        XCTAssertNotNil(vm.scheduledAlarmSummary?.calendarPlan)
    }
    func testDisablingManualOnlyCalendarDoesNotEnableAllWeekdays() async throws {
        let spy = CalendarSchedulerSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: spy,
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(20),
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.selectedWeekdays = []
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        vm.settings.calendarSettings = .init(isEnabled: true, overrides: [AlarmCalendarSettings.key(for: tomorrow): .ring])
        await vm.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(vm.hasScheduledAlarm)
        vm.settings.calendarSettings.isEnabled = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(vm.hasScheduledAlarm)
        XCTAssertEqual(spy.weeklyCalls, 0)
    }
    func testFormatChangeReplacesPendingPreviewsWithoutReschedulingAlarm() async throws {
        let spy = CalendarSchedulerSpy()
        let previews = TimeFormatPreviewSpy()
        let vm = AlarmViewModel(routeWeatherService: OfflineCalendarWeather(), notificationScheduler: spy,
            previewScheduler: previews, settingsStorage: storage,
            membershipEntitlements: { Self.calendarEntitlements })
        vm.settings.homeAddress = "Home"; vm.settings.workAddress = "Office"
        vm.settings.calendarSettings = .init(isEnabled: true)
        await vm.evaluateRouteAndScheduleAlarm()
        let originalDates = previews.previews.map(\.fireDate)
        let originalCalls = spy.plans.count
        XCTAssertFalse(originalDates.isEmpty)
        vm.settings.timeFormat = .twentyFourHour
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(spy.plans.count, originalCalls)
        XCTAssertEqual(previews.previews.map(\.fireDate), originalDates)
        XCTAssertTrue(previews.previews.allSatisfy { $0.timeFormat == .twentyFourHour })
    }
    func testMapDistrictClearsWhenAddressChanges() {
        let vm = AlarmViewModel(settingsStorage: storage)
        XCTAssertNil(vm.homeMapDistrict)
        let mapped = ResolvedMapLocation(latitude: 23.1, longitude: 120.3, displayAddress: "Home", resolution: .exact, districtName: "臺南市善化區")
        vm.setAddressFromSuggestion("Home", location: mapped, field: .home)
        XCTAssertEqual(vm.homeMapDistrict, "臺南市善化區")
        vm.settings.homeAddress = "Different point"
        XCTAssertNil(vm.homeMapDistrict)
    }
}
private final class TimeFormatPreviewSpy: EveningPreviewScheduling, @unchecked Sendable {
    var previews: [EveningPreview] = []
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async { self.previews = previews }
    func cancelPreviews() async { previews = [] }
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}
