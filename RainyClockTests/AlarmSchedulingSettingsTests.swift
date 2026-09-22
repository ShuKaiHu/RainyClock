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
