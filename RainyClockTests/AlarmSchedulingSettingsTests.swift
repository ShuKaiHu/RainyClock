import XCTest
@testable import RainyClock

/// Covers the pieces 1.6.3 introduced that carry real branching: the weekday shift
/// both schedulers rely on, the snooze settings, and the migration paths for data
/// written by earlier builds.
final class AlarmSchedulingSettingsTests: XCTestCase {

    // MARK: - Weekday shift

    func testShiftedWeekdayIsIdentityWithoutAShift() {
        for weekday in 1...7 {
            XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(weekday, byDays: 0), weekday)
        }
    }

    func testShiftedWeekdayWrapsBackwardsAcrossTheWeekStart() {
        // Sunday minus a day is Saturday: a rain lead time that crosses midnight
        // moves the ring onto the previous weekday.
        XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(1, byDays: -1), 7)
        XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(2, byDays: -1), 1)
    }

    func testShiftedWeekdayWrapsForwardsPastSaturday() {
        XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(7, byDays: 1), 1)
        XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(6, byDays: 2), 1)
    }

    func testShiftedWeekdayHandlesShiftsLargerThanAWeek() {
        for weekday in 1...7 {
            XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(weekday, byDays: 7), weekday)
            XCTAssertEqual(AlarmTimeCalculator.shiftedWeekday(weekday, byDays: -14), weekday)
            XCTAssertEqual(
                AlarmTimeCalculator.shiftedWeekday(weekday, byDays: 9),
                AlarmTimeCalculator.shiftedWeekday(weekday, byDays: 2)
            )
        }
    }

    func testShiftedWeekdayIsABijectionSoSelectedDaysCannotCollapse() {
        // Every scheduler maps a Set of weekdays through this; a collision would
        // silently drop a day the user picked.
        for dayShift in -7...7 {
            let shifted = Set((1...7).map { AlarmTimeCalculator.shiftedWeekday($0, byDays: dayShift) })
            XCTAssertEqual(shifted, CommuteAlarmSettings.allWeekdays)
        }
    }

    // MARK: - Snooze settings

    func testSnoozeDefaultsMatchThePreviousFixedBehaviour() {
        let settings = CommuteAlarmSettings()

        XCTAssertTrue(settings.isSnoozeEnabled)
        XCTAssertEqual(settings.snoozeDurationMinutes, 5)
        XCTAssertEqual(settings.effectiveSnoozeMinutes, 5)
    }

    func testDisablingSnoozeRemovesTheInterval() {
        var settings = CommuteAlarmSettings()
        settings.isSnoozeEnabled = false

        XCTAssertNil(settings.effectiveSnoozeMinutes)
    }

    func testSettingsStoredBeforeSnoozeExistedKeepTheOldBehaviour() throws {
        // A 1.6.2 payload: no snooze keys at all.
        let stored = #"{"homeAddress":"A","workAddress":"B","rainLeadTimeMinutes":30}"#
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(stored.utf8))

        XCTAssertTrue(settings.isSnoozeEnabled)
        XCTAssertEqual(settings.snoozeDurationMinutes, 5)
    }

    func testDecodedSnoozeDurationIsClampedIntoRange() throws {
        let tooLong = #"{"snoozeDurationMinutes":999}"#
        let tooShort = #"{"snoozeDurationMinutes":-3}"#

        XCTAssertEqual(
            try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(tooLong.utf8)).snoozeDurationMinutes,
            CommuteAlarmSettings.snoozeDurationRange.upperBound
        )
        XCTAssertEqual(
            try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(tooShort.utf8)).snoozeDurationMinutes,
            CommuteAlarmSettings.snoozeDurationRange.lowerBound
        )
    }

    // MARK: - Alarm sound

    func testSystemAlarmToneIsOnlyOfferedWhereAlarmKitCanPlayIt() {
        let selectable = CommuteAlarmSettings.AlarmSound.selectableCases

        if #available(iOS 26.0, *) {
            XCTAssertTrue(selectable.contains(.systemDefault))
        } else {
            XCTAssertFalse(selectable.contains(.systemDefault))
        }
        XCTAssertTrue(selectable.contains(.rainyClock))
        XCTAssertEqual(Set(selectable).count, selectable.count)
    }

    func testOnlyTheSystemToneSkipsTheBundledFile() {
        for sound in CommuteAlarmSettings.AlarmSound.selectableCases where sound != .systemDefault {
            XCTAssertFalse(sound.usesSystemAlarmTone, "\(sound.rawValue) should name a bundled file")
        }
        XCTAssertTrue(CommuteAlarmSettings.AlarmSound.systemDefault.usesSystemAlarmTone)
    }

    func testStoredSoundTheSystemCannotOfferFallsBack() throws {
        let stored = #"{"alarmSound":"systemDefault"}"#
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(stored.utf8))

        if #available(iOS 26.0, *) {
            XCTAssertEqual(settings.alarmSound, .systemDefault)
        } else {
            XCTAssertEqual(settings.alarmSound, .rainyClock)
        }
    }

    // MARK: - Schedule fingerprint

    func testLegacyGeneratedVoiceMigratesIntoBothSoundSlots() throws {
        let stored = #"{"alarmSound":"aiVoice","aiVoiceFileName":"ai-old.wav","aiVoicePersona":"mom","aiVoiceText":"Time to wake up"}"#
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(stored.utf8))
        for slot in CommuteAlarmSettings.SoundSlot.allCases {
            XCTAssertEqual(settings.sound(for: slot), .aiVoice)
            XCTAssertEqual(settings.voiceFileName(for: slot), "ai-old.wav")
            XCTAssertEqual(settings.voicePersona(for: slot), .mom)
            XCTAssertEqual(settings.voiceText(for: slot), "Time to wake up")
        }
        XCTAssertEqual(settings.generatedVoiceFileNames, ["ai-old.wav"])
    }

    func testSeparateSoundAndVoiceChoicesSurviveStorageIndependently() throws {
        var settings = CommuteAlarmSettings()
        settings.setVoice(fileName: "ai-normal.wav", persona: .gentle, text: "Normal", for: .normal)
        settings.setVoice(fileName: "ai-early.wav", persona: .sergeant, text: "Early", for: .early)
        settings.setSound(.brightChime, for: .early)
        let restored = try JSONDecoder().decode(CommuteAlarmSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.sound(for: .normal), .aiVoice)
        XCTAssertEqual(restored.voiceText(for: .normal), "Normal")
        XCTAssertEqual(restored.sound(for: .early), .brightChime)
        XCTAssertEqual(restored.voiceFileName(for: .early), "ai-early.wav")
        XCTAssertEqual(restored.voicePersona(for: .early), .sergeant)
        XCTAssertEqual(restored.generatedVoiceFileNames, ["ai-normal.wav", "ai-early.wav"])
    }

    func testSoundUsesActualRingTimeIncludingZeroLeadAndMidnightCrossing() {
        var settings = CommuteAlarmSettings()
        settings.alarmSound = .softPiano
        settings.earlyAlarmSound = .digitalBeep
        let normal = Date(timeIntervalSince1970: 86_400)
        XCTAssertEqual(settings.soundSelection(ringDate: normal, normalDate: normal).sound, .softPiano)
        XCTAssertEqual(settings.soundSelection(ringDate: normal.addingTimeInterval(-1_800), normalDate: normal).sound, .digitalBeep)
        // A delayed ring also belongs to the normal slot.
        XCTAssertEqual(settings.soundSelection(ringDate: normal.addingTimeInterval(60), normalDate: normal).sound, .softPiano)
    }

    func testMissingEarlyVoiceFallsBackWithoutChangingTheNormalSound() {
        var settings = CommuteAlarmSettings()
        settings.alarmSound = .softPiano
        settings.setVoice(fileName: "missing-\(UUID()).wav", persona: .mom, text: "Early", for: .early)
        XCTAssertEqual(settings.soundFileNameOverride(for: .early), CommuteAlarmSettings.AlarmSound.rainyClock.fileName)
        XCTAssertEqual(settings.soundFileNameOverride(for: .normal), CommuteAlarmSettings.AlarmSound.softPiano.fileName)
    }

    func testChangingEitherSoundSlotInvalidatesTheScheduleFingerprint() {
        var settings = CommuteAlarmSettings()
        let original = settings.scheduleFingerprint()
        settings.earlyAlarmSound = .morningBell
        XCTAssertNotEqual(settings.scheduleFingerprint(), original)
        let withEarly = settings.scheduleFingerprint()
        settings.setVoice(fileName: "ai-early.wav", persona: .steady, text: "Early", for: .early)
        XCTAssertNotEqual(settings.scheduleFingerprint(), withEarly)
        let voice = settings.scheduleFingerprint()
        settings.earlyAIVoiceFileName = "ai-early-replacement.wav"
        XCTAssertNotEqual(settings.scheduleFingerprint(), voice)
    }

    func testLegacyVoiceFingerprintMatchesMigratedTwoSlotSettings() throws {
        let legacySettings = #"{"alarmSound":"aiVoice","aiVoiceFileName":"ai-old.wav"}"#
        let settings = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data(legacySettings.utf8))
        var oldFingerprint = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.scheduleFingerprint())) as? [String: Any])
        oldFingerprint.removeValue(forKey: "earlyAlarmSoundRawValue")
        oldFingerprint.removeValue(forKey: "earlyAIVoiceFileName")
        let restored = try JSONDecoder().decode(AlarmScheduleFingerprint.self, from: JSONSerialization.data(withJSONObject: oldFingerprint))
        XCTAssertEqual(restored, settings.scheduleFingerprint())
    }

    func testDatedPlanPersistsOneEarlySoundAndNormalSoundsForLaterDays() throws {
        var settings = CommuteAlarmSettings()
        settings.alarmSound = .softPiano
        settings.earlyAlarmSound = .digitalBeep
        let firstNormal = Date(timeIntervalSince1970: 86_400)
        let secondNormal = firstNormal.addingTimeInterval(86_400)
        var plan = CalendarAlarmPlan(occurrences: [
            .init(normalDate: firstNormal, ringDate: firstNormal.addingTimeInterval(-1_800)),
            .init(normalDate: secondNormal, ringDate: secondNormal)
        ], coveredUntil: secondNormal.addingTimeInterval(86_400))
        plan.applySounds(from: settings)
        let restored = try JSONDecoder().decode(CalendarAlarmPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(restored.occurrences[0].soundSelection?.sound, .digitalBeep)
        XCTAssertEqual(restored.occurrences[0].soundSelection?.fileNameOverride, "DigitalBeep.wav")
        XCTAssertEqual(restored.occurrences[1].soundSelection?.sound, .softPiano)
        XCTAssertEqual(restored.occurrences[1].soundSelection?.fileNameOverride, "SoftPiano.wav")
    }

    func testLegacyDatedOccurrenceKeepsItsOriginalPlanSound() throws {
        let occurrence = try JSONDecoder().decode(CalendarAlarmPlan.Occurrence.self,
            from: Data(#"{"normalDate":86400,"ringDate":84600}"#.utf8))
        let legacySound = AlarmSoundSelection(sound: .aiVoice, fileNameOverride: "ai-existing.wav")
        XCTAssertEqual(occurrence.resolvedSound(fallback: legacySound), legacySound)
    }

    func testFingerprintStoredBeforeSnoozeExistedStillDecodes() throws {
        // Regression guard: if this throws, the "settings changed — reschedule"
        // notice silently stops working for every upgraded install.
        let stored = """
        {"homeAddress":"A","workAddress":"B","commuteMode":"car","alarmHour":7,\
        "alarmMinute":30,"selectedWeekdays":[2,3,4,5,6],"rainLeadTimeMinutes":30,\
        "rainProbabilityThreshold":0.5,"alarmSoundRawValue":"rainyClock"}
        """
        let fingerprint = try JSONDecoder().decode(AlarmScheduleFingerprint.self, from: Data(stored.utf8))

        XCTAssertTrue(fingerprint.isSnoozeEnabled)
        XCTAssertEqual(fingerprint.snoozeDurationMinutes, 5)
    }

    func testUntouchedSettingsStillMatchAFingerprintStoredBeforeSnoozeExisted() throws {
        var settings = CommuteAlarmSettings()
        settings.homeAddress = "A"
        settings.workAddress = "B"
        settings.selectedWeekdays = [2, 3, 4, 5, 6]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        settings.alarmTime = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 7, minute: 30))!

        let stored = """
        {"homeAddress":"A","workAddress":"B","commuteMode":"car","alarmHour":7,\
        "alarmMinute":30,"selectedWeekdays":[2,3,4,5,6],"rainLeadTimeMinutes":30,\
        "rainProbabilityThreshold":0.5,"alarmSoundRawValue":"rainyClock"}
        """
        let legacyFingerprint = try JSONDecoder().decode(AlarmScheduleFingerprint.self, from: Data(stored.utf8))

        XCTAssertEqual(settings.scheduleFingerprint(calendar: calendar), legacyFingerprint)
    }

    func testChangingSnoozeSettingsChangesTheFingerprint() {
        var settings = CommuteAlarmSettings()
        let before = settings.scheduleFingerprint()

        settings.snoozeDurationMinutes = 12
        XCTAssertNotEqual(settings.scheduleFingerprint(), before)

        settings.snoozeDurationMinutes = 5
        settings.isSnoozeEnabled = false
        XCTAssertNotEqual(settings.scheduleFingerprint(), before)
    }
}

/// The master switch (1.8.0): what is stored, what the plan leaves out, and which ring
/// the system holds. Pure; the view-model flows are in AlarmViewModelSchedulingTests and
/// CalendarSchedulingTests.
final class AlarmSwitchModelTests: XCTestCase {
    private var calendar: Calendar { DisasterNoticeParser.taipeiCalendar }
    /// 2026-09-29 is a Tuesday.
    private func date(_ day: Int, _ hour: Int = 7, _ minute: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    private func settings(weekdays: Set<Int> = Set(1...7)) -> CommuteAlarmSettings {
        var value = CommuteAlarmSettings()
        value.homeAddress = "Home"; value.workAddress = "Work"
        value.alarmTime = date(15)
        value.selectedWeekdays = weekdays
        value.rainLeadTimeMinutes = 30
        return value
    }

    func testSettingsStoredBefore180DecodeAsOnWithoutSkip() throws {
        let decoded = try JSONDecoder().decode(CommuteAlarmSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.isAlarmEnabled)
        XCTAssertNil(decoded.skippedAlarmDay)
        var value = settings()
        value.isAlarmEnabled = false
        value.skippedAlarmDay = "2026-09-30"
        let roundTrip = try JSONDecoder().decode(CommuteAlarmSettings.self, from: JSONEncoder().encode(value))
        XCTAssertFalse(roundTrip.isAlarmEnabled)
        XCTAssertEqual(roundTrip.skippedAlarmDay, "2026-09-30")
    }

    func testFingerprintStoredBeforeTheSkipEqualsUntouchedSettings() throws {
        let value = settings()
        let stored = try JSONEncoder().encode(value.scheduleFingerprint(calendar: calendar))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("skippedAlarmDay"), "Nil is not written")
        XCTAssertEqual(try JSONDecoder().decode(AlarmScheduleFingerprint.self, from: stored), value.scheduleFingerprint(calendar: calendar))
    }

    func testSkipIsInTheFingerprintAndTheSwitchIsNot() {
        let base = settings()
        var off = base
        off.isAlarmEnabled = false
        XCTAssertEqual(off.scheduleFingerprint(calendar: calendar), base.scheduleFingerprint(calendar: calendar),
                       "Off removes the registration instead of changing it")
        var skipping = base
        skipping.skippedAlarmDay = "2026-09-30"
        XCTAssertNotEqual(skipping.scheduleFingerprint(calendar: calendar), base.scheduleFingerprint(calendar: calendar))
        XCTAssertFalse(base.usesDatedSchedule)
        XCTAssertTrue(skipping.usesDatedSchedule, "A repeating weekly alarm cannot leave out one morning")
    }

    func testDayForKeyRoundTripsAndRejectsGarbage() {
        XCTAssertEqual(AlarmCalendarSettings.day(forKey: "2026-09-30", calendar: calendar), date(30, 0, 0))
        for bad in ["", "2026-9", "2026-02-31", "abcd-ef-gh", "2026-09-30-01"] {
            XCTAssertNil(AlarmCalendarSettings.day(forKey: bad, calendar: calendar), bad)
        }
    }

    private func oct(_ day: Int, _ hour: Int = 7, _ minute: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testPlanLeavesOutExactlyTheSkippedDay() {
        var free = settings()
        free.skippedAlarmDay = "2026-09-30"
        let plan = CalendarAlarmPlan.make(settings: free, holidays: .init(), rain: false, now: date(29, 12), days: 5, calendar: calendar)
        XCTAssertEqual(plan.occurrences.map(\.normalDate), [oct(1), oct(2), oct(3)], "9/29 has passed and 9/30 is skipped")
        var ringOverride = free
        ringOverride.calendarSettings = .init(isEnabled: true, source: .weekly, overrides: ["2026-09-30": .ring])
        XCTAssertFalse(CalendarAlarmPlan.make(settings: ringOverride, holidays: .init(), rain: false, now: date(29, 12), days: 5,
                                              calendar: calendar).occurrences.contains { $0.normalDate == date(30) },
                       "The newer, explicit skip outranks a paid manual ring")
        var midnight = free
        midnight.alarmTime = date(15, 0, 15)
        let rainy = CalendarAlarmPlan.make(settings: midnight, holidays: .init(), rain: true, now: date(29, 12), days: 3, calendar: calendar)
        XCTAssertFalse(rainy.occurrences.contains { $0.normalDate == date(30, 0, 15) },
                       "Keyed by the normal day even when the rain ring falls the evening before")
    }

    func testSkippedNormalDateNeedsARingingFutureMorning() {
        var value = settings()
        value.skippedAlarmDay = "2026-09-30"
        XCTAssertEqual(CalendarAlarmPlan.skippedNormalDate(settings: value, holidays: .init(), now: date(29, 21), calendar: calendar), date(30))
        XCTAssertNil(CalendarAlarmPlan.skippedNormalDate(settings: value, holidays: .init(), now: date(30, 7, 30), calendar: calendar),
                     "Spent at the normal time")
        var weekend = settings(weekdays: [2, 3, 5, 6, 7])
        weekend.skippedAlarmDay = "2026-09-30" // a Wednesday, deselected
        XCTAssertNil(CalendarAlarmPlan.skippedNormalDate(settings: weekend, holidays: .init(), now: date(29, 21), calendar: calendar))
        XCTAssertNil(CalendarAlarmPlan.skippedNormalDate(settings: settings(), holidays: .init(), now: date(29, 21), calendar: calendar))
    }

    func testClosureOnTheSkippedDayRecordsNoClosureSkipAndRebuildsEqual() {
        var value = settings()
        value.skippedAlarmDay = "2026-09-30"
        value.isDisasterSuspensionEnabled = true
        value.homeSuspensionRegion = .init(county: "臺北市", district: "信義區")
        let now = date(29, 21)
        let feed = DisasterFeed(checkedAt: now, notices: [.init(id: "n", sentAt: now,
            description: "[停班停課通知]臺北市:明天停止上班、停止上課。行政院人事行政總處。", severity: "Extreme")])
        let first = DisasterAlarmPlan.filtering(CalendarAlarmPlan.make(settings: value, holidays: .init(), rain: false, now: now,
                                                                       days: 5, calendar: calendar), settings: value, feed: feed, now: now)
        let again = DisasterAlarmPlan.filtering(CalendarAlarmPlan.make(settings: value, holidays: .init(), rain: false, now: now,
                                                                       days: 5, calendar: calendar), settings: value, feed: feed, now: now)
        XCTAssertTrue(first.skips.isEmpty, "The user already turned that morning off; no closure skip to re-apply")
        XCTAssertEqual(first.skips, again.skips)
        XCTAssertEqual(first.plan, again.plan)
    }

    func testNextRegisteredRingForDatedAndWeeklyRegistrations() {
        var dated = ScheduledAlarmSummary(normalAlarmDate: date(30), scheduledAlarmDate: date(30, 7, 0), weatherRefreshDate: date(30, 7, 0),
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8)
        dated.calendarPlan = .init(occurrences: [.init(normalDate: date(29), ringDate: date(29, 7, 0)), .init(normalDate: date(30), ringDate: date(30))],
                                   coveredUntil: oct(20, 0, 0), timeZoneID: calendar.timeZone.identifier)
        XCTAssertEqual(dated.nextRegisteredRing(settings: settings(), holidays: .init(), now: date(29, 7, 10), calendar: calendar)?.normalDate,
                       date(30), "Today's early ring already went off")
        let rainyWeekly = ScheduledAlarmSummary(normalAlarmDate: date(29), scheduledAlarmDate: date(29, 7, 0), weatherRefreshDate: date(29, 7, 0),
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8)
        let next = rainyWeekly.nextRegisteredRing(settings: settings(), holidays: .init(), now: date(29, 7, 10), calendar: calendar)
        XCTAssertEqual(next?.normalDate, date(30))
        XCTAssertEqual(next?.ringDate, date(30, 7, 0), "The repeating alarm keeps one clock time")
        let dryWeekly = ScheduledAlarmSummary(normalAlarmDate: date(29), scheduledAlarmDate: date(29), weatherRefreshDate: date(29, 7, 0),
            exceedsRainThreshold: false, leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.1)
        XCTAssertEqual(dryWeekly.nextRegisteredRing(settings: settings(), holidays: .init(), now: date(29, 7, 10), calendar: calendar)?.ringDate,
                       date(29), "Dry: today's 07:30 is still ahead")
        let tuesdaysOnly = dryWeekly.nextRegisteredRing(settings: settings(weekdays: [3]), holidays: .init(), now: date(29, 8), calendar: calendar)
        XCTAssertEqual(tuesdaysOnly?.normalDate, oct(6), "Next week's Tuesday")
    }

    func testFiredEarlyRingForWeeklyDatedAndRecordedRings() {
        let rainyWeekly = ScheduledAlarmSummary(normalAlarmDate: date(29), scheduledAlarmDate: date(29, 7, 0), weatherRefreshDate: date(29, 7, 0),
            exceedsRainThreshold: true, leadTimeMinutes: 30, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0.8)
        XCTAssertTrue(rainyWeekly.hasFiredEarlyRing(forMorning: date(29), now: date(29, 7, 10)))
        XCTAssertFalse(rainyWeekly.hasFiredEarlyRing(forMorning: date(29), now: date(29, 6, 50)))
        XCTAssertFalse(rainyWeekly.hasFiredEarlyRing(forMorning: date(30), now: date(29, 7, 10)), "A summary for another morning")
        var recorded = rainyWeekly
        recorded.calendarPlan = .init(occurrences: [], coveredUntil: oct(20, 0, 0), timeZoneID: calendar.timeZone.identifier)
        recorded.firedEarlyRing = .init(normalDate: date(29), ringDate: date(29, 7, 0))
        XCTAssertTrue(recorded.hasFiredEarlyRing(forMorning: date(29), now: date(29, 7, 10)))
        var dated = rainyWeekly
        dated.calendarPlan = .init(occurrences: [.init(normalDate: date(29), ringDate: date(29, 7, 0))], coveredUntil: oct(20, 0, 0),
                                   timeZoneID: calendar.timeZone.identifier)
        XCTAssertTrue(dated.hasFiredEarlyRing(forMorning: date(29), now: date(29, 7, 10)))
    }

    func testUserSkipIsMirroredApartFromClosureSkips() {
        var summary = ScheduledAlarmSummary(normalAlarmDate: oct(1), scheduledAlarmDate: oct(1), weatherRefreshDate: oct(1, 7),
            exceedsRainThreshold: false, leadTimeMinutes: 0, rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: 0)
        summary.calendarPlan = .init(occurrences: [.init(normalDate: oct(1), ringDate: oct(1))], coveredUntil: oct(20, 0, 0),
                                     timeZoneID: calendar.timeZone.identifier)
        summary.userSkippedNormalDate = date(30)
        let dates = summary.dayOffAlarmDates(after: date(29, 21))
        XCTAssertEqual(dates.userSkipped, [date(30)])
        XCTAssertEqual(dates.skipped, [])
        XCTAssertEqual(dates.upcoming, [date(30), oct(1)])
    }

    func testFreePlanKeepsTheSwitchAndTheSkip() {
        var value = settings()
        value.isAlarmEnabled = false
        value.skippedAlarmDay = "2026-09-30"
        let free = MembershipEntitlements(removeBanner: false, calendar: false, temporaryClosures: false,
                                          dailyAI: false, subscriptionActive: false, lifetimeActive: false)
        let effective = MembershipSchedulingAccess.effectiveSettings(value, entitlements: free)
        XCTAssertFalse(effective.isAlarmEnabled)
        XCTAssertEqual(effective.skippedAlarmDay, "2026-09-30")
    }
}
