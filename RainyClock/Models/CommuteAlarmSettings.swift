import Foundation

struct CommuteAlarmSettings: Codable, Equatable {
    static let allWeekdays = Set(1...7)

    enum SoundSlot: String, CaseIterable, Identifiable, Sendable {
        case normal
        case early

        var id: String { rawValue }
    }

    enum CommuteMode: String, CaseIterable, Codable, Identifiable, Equatable {
        case car
        case scooter
        case walking
        case publicTransit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .car:
                String(localized: "commute_mode_car")
            case .scooter:
                String(localized: "commute_mode_scooter")
            case .walking:
                String(localized: "commute_mode_walking")
            case .publicTransit:
                String(localized: "commute_mode_public_transit")
            }
        }
    }

    enum AlarmSound: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
        case rainyClock
        case morningBell
        case softPiano
        case brightChime
        case gentleWaves
        case digitalBeep
        case forestBirds
        case energeticPulse
        case deepResonance
        case minimalTap
        /// A clip this app generated and wrote into the container at runtime, rather
        /// than one of the ten shipped tones. The file it names lives in
        /// `settings.aiVoiceFileName`, not here — a raw-value enum cannot carry an
        /// associated value, and `rawValue` is load-bearing in the picker tag, the
        /// settings decoder, the schedule fingerprint and the stored notification plan.
        case aiVoice
        case systemDefault

        static var allCases: [AlarmSound] {
            [
                .rainyClock,
                .morningBell,
                .softPiano,
                .brightChime,
                .gentleWaves,
                .digitalBeep,
                .forestBirds,
                .energeticPulse,
                .deepResonance,
                .minimalTap
            ]
        }

        /// What the sound picker offers. The system alarm tone only appears on
        /// iOS 26+, where AlarmKit's `.default` resolves to it; the notification
        /// fallback has no way to reach the same tone.
        ///
        /// `aiVoice` is deliberately absent: it is chosen by generating a clip, not
        /// by tapping a row, and a picker row with no file behind it would ring
        /// silently. Use `restorableCases` for validating stored values.
        static var selectableCases: [AlarmSound] {
            if #available(iOS 26.0, *) {
                allCases + [.systemDefault]
            } else {
                allCases
            }
        }

        /// What may legitimately come back out of storage. Wider than
        /// `selectableCases`, and the two must not be conflated: the decoder used to
        /// validate against the picker list, which silently reset any sound the
        /// picker does not offer back to `.rainyClock` on every launch. A generated
        /// voice has to survive that round trip.
        static var restorableCases: [AlarmSound] {
            selectableCases + [.aiVoice]
        }

        /// True when the system picks the tone, so there is no bundled file to
        /// preview and nothing for the app to name.
        var usesSystemAlarmTone: Bool {
            self == .systemDefault
        }

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rainyClock:
                String(localized: "alarm_sound_rainy_clock")
            case .morningBell:
                String(localized: "alarm_sound_morning_bell")
            case .softPiano:
                String(localized: "alarm_sound_soft_piano")
            case .brightChime:
                String(localized: "alarm_sound_bright_chime")
            case .gentleWaves:
                String(localized: "alarm_sound_gentle_waves")
            case .digitalBeep:
                String(localized: "alarm_sound_digital_beep")
            case .forestBirds:
                String(localized: "alarm_sound_forest_birds")
            case .energeticPulse:
                String(localized: "alarm_sound_energetic_pulse")
            case .deepResonance:
                String(localized: "alarm_sound_deep_resonance")
            case .minimalTap:
                String(localized: "alarm_sound_minimal_tap")
            case .aiVoice:
                String(localized: "alarm_sound_ai_voice")
            case .systemDefault:
                String(localized: "alarm_sound_system_default")
            }
        }

        var fileName: String {
            switch self {
            case .rainyClock:
                "RainyClock.wav"
            case .morningBell:
                "MorningBell.wav"
            case .softPiano:
                "SoftPiano.wav"
            case .brightChime:
                "BrightChime.wav"
            case .gentleWaves:
                "GentleWaves.wav"
            case .digitalBeep:
                "DigitalBeep.wav"
            case .forestBirds:
                "ForestBirds.wav"
            case .energeticPulse:
                "EnergeticPulse.wav"
            case .deepResonance:
                "DeepResonance.wav"
            case .minimalTap:
                "MinimalTap.wav"
            case .aiVoice:
                // No shipped file. The real name is per-user and lives in
                // `settings.aiVoiceFileName`; resolve through
                // `CommuteAlarmSettings.soundFileNameOverride` instead of reading this.
                ""
            case .systemDefault:
                "AlarmTone.wav"
            }
        }
    }

    var timeFormat: ClockTimeFormat = .twelveHour
    var calendarSettings = AlarmCalendarSettings()
    var observesWorkSuspensions = true
    var observesSchoolSuspensions = false
    // Opt-in, including upgrades from versions that only displayed these choices.
    var isDisasterSuspensionEnabled = false
    var homeSuspensionRegion: DisasterRegion?
    var workSuspensionRegion: DisasterRegion?
    var usesDatedSchedule: Bool { calendarSettings.isActive || isDisasterSuspensionEnabled }

    var homeAddress: String = ""
    var workAddress: String = ""
    var homeResolvedLocation: ResolvedMapLocation?
    var workResolvedLocation: ResolvedMapLocation?
    var confirmedHomeAddressInput: String?
    var confirmedWorkAddressInput: String?
    var commuteMode: CommuteMode = .car
    var alarmTime: Date = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    var rainLeadTimeMinutes: Int = 30
    var rainProbabilityThreshold: Double = 0.5
    var selectedWeekdays: Set<Int> = Self.allWeekdays
    var alarmSound: AlarmSound = .rainyClock
    /// File name of the generated clip inside the container's `Library/Sounds`,
    /// when `alarmSound == .aiVoice`. Kept beside the enum rather than inside it
    /// so `AlarmSound` stays a plain raw-value enum.
    var aiVoiceFileName: String?
    /// What was said and who said it. Kept so the sheet reopens on what the user
    /// last chose rather than a blank page — the clip itself is audio and cannot
    /// be read back into a text field.
    var aiVoicePersona: VoicePersona = .default
    var aiVoiceText: String = ""
    var earlyAlarmSound: AlarmSound = .rainyClock
    var earlyAIVoiceFileName: String?
    var earlyAIVoicePersona: VoicePersona = .default
    var earlyAIVoiceText: String = ""
    var isSnoozeEnabled: Bool = true
    var snoozeDurationMinutes: Int = 5
    /// The 9 p.m. "tomorrow morning" notification before each selected
    /// weekday. Not part of the schedule fingerprint: it changes nothing about
    /// the registered alarm, only what is said the night before.
    var isEveningPreviewEnabled: Bool = true
    /// When, the evening before, the preview arrives. Only the hour and minute
    /// are read. 21:00 by default: late enough that the forecast for the morning
    /// is worth reading, early enough to still change plans.
    var eveningPreviewTime: Date = Self.defaultEveningPreviewTime

    static var defaultEveningPreviewTime: Date {
        Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
    }

    static let snoozeDurationRange = 1...15

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calendarSettings = try values.decodeIfPresent(AlarmCalendarSettings.self, forKey: .calendarSettings) ?? AlarmCalendarSettings()
        observesWorkSuspensions = try values.decodeIfPresent(Bool.self, forKey: .observesWorkSuspensions) ?? true
        observesSchoolSuspensions = try values.decodeIfPresent(Bool.self, forKey: .observesSchoolSuspensions) ?? false
        isDisasterSuspensionEnabled = try values.decodeIfPresent(Bool.self, forKey: .isDisasterSuspensionEnabled) ?? false
        homeSuspensionRegion = try values.decodeIfPresent(DisasterRegion.self, forKey: .homeSuspensionRegion)
        workSuspensionRegion = try values.decodeIfPresent(DisasterRegion.self, forKey: .workSuspensionRegion)
        timeFormat = try values.decodeIfPresent(ClockTimeFormat.self, forKey: .timeFormat) ?? .twelveHour
        homeAddress = try values.decodeIfPresent(String.self, forKey: .homeAddress) ?? ""
        workAddress = try values.decodeIfPresent(String.self, forKey: .workAddress) ?? ""
        homeResolvedLocation = try values.decodeIfPresent(ResolvedMapLocation.self, forKey: .homeResolvedLocation)
        workResolvedLocation = try values.decodeIfPresent(ResolvedMapLocation.self, forKey: .workResolvedLocation)
        confirmedHomeAddressInput = try values.decodeIfPresent(String.self, forKey: .confirmedHomeAddressInput)
        confirmedWorkAddressInput = try values.decodeIfPresent(String.self, forKey: .confirmedWorkAddressInput)
        commuteMode = try values.decodeIfPresent(CommuteMode.self, forKey: .commuteMode) ?? .car
        alarmTime = try values.decodeIfPresent(Date.self, forKey: .alarmTime)
            ?? Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date())
            ?? Date()
        rainLeadTimeMinutes = try values.decodeIfPresent(Int.self, forKey: .rainLeadTimeMinutes) ?? 30
        rainProbabilityThreshold = try values.decodeIfPresent(Double.self, forKey: .rainProbabilityThreshold) ?? 0.5
        selectedWeekdays = try values.decodeIfPresent(Set<Int>.self, forKey: .selectedWeekdays) ?? Self.allWeekdays
        // A stored sound the running system cannot offer (the system alarm tone on
        // iOS 17–25) falls back rather than silently ringing something else.
        let decodedAlarmSound = try values.decodeIfPresent(AlarmSound.self, forKey: .alarmSound) ?? .rainyClock
        alarmSound = AlarmSound.restorableCases.contains(decodedAlarmSound) ? decodedAlarmSound : .rainyClock
        aiVoiceFileName = try values.decodeIfPresent(String.self, forKey: .aiVoiceFileName)
        aiVoicePersona = try values.decodeIfPresent(VoicePersona.self, forKey: .aiVoicePersona) ?? .default
        aiVoiceText = try values.decodeIfPresent(String.self, forKey: .aiVoiceText) ?? ""
        // Before separate sound slots existed, the same clip rang at both times.
        // Preserve that exact choice, including its generated voice, on upgrade.
        let decodedEarlySound = try values.decodeIfPresent(AlarmSound.self, forKey: .earlyAlarmSound) ?? alarmSound
        earlyAlarmSound = AlarmSound.restorableCases.contains(decodedEarlySound) ? decodedEarlySound : .rainyClock
        if values.contains(.earlyAlarmSound) {
            earlyAIVoiceFileName = try values.decodeIfPresent(String.self, forKey: .earlyAIVoiceFileName)
            earlyAIVoicePersona = try values.decodeIfPresent(VoicePersona.self, forKey: .earlyAIVoicePersona) ?? .default
            earlyAIVoiceText = try values.decodeIfPresent(String.self, forKey: .earlyAIVoiceText) ?? ""
        } else {
            earlyAIVoiceFileName = aiVoiceFileName
            earlyAIVoicePersona = aiVoicePersona
            earlyAIVoiceText = aiVoiceText
        }
        isSnoozeEnabled = try values.decodeIfPresent(Bool.self, forKey: .isSnoozeEnabled) ?? true
        let decodedSnoozeDuration = try values.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 5
        snoozeDurationMinutes = min(max(decodedSnoozeDuration, Self.snoozeDurationRange.lowerBound), Self.snoozeDurationRange.upperBound)
        isEveningPreviewEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEveningPreviewEnabled) ?? true
        eveningPreviewTime = try values.decodeIfPresent(Date.self, forKey: .eveningPreviewTime) ?? Self.defaultEveningPreviewTime
    }

    /// The snooze interval to schedule with, or nil when the user turned snooze off.
    var effectiveSnoozeMinutes: Int? {
        isSnoozeEnabled ? snoozeDurationMinutes : nil
    }
}

struct RouteWeatherSnapshot: Codable, Equatable {
    var checkedAt: Date
    var forecastAt: Date
    var segments: [RouteWeatherSegment]

    func exceedsRainThreshold(_ threshold: Double) -> Bool {
        segments.contains { $0.precipitationProbability >= threshold }
    }

    var maximumPrecipitationProbability: Double {
        segments.map(\.precipitationProbability).max() ?? 0
    }
}

struct RouteWeatherSegment: Codable, Identifiable, Equatable {
    enum Condition: String, Codable, Equatable, Sendable {
        case clear
        case cloudy
        case rain
    }

    var id = UUID()
    var name: String
    var condition: Condition
    var precipitationProbability: Double
}

/// Snapshot of every setting the scheduling flow reads. Comparing the stored
/// snapshot against the live settings tells whether the scheduled alarm still
/// matches what the user currently has configured.
struct AlarmScheduleFingerprint: Codable, Equatable {
    var calendarSettings: AlarmCalendarSettings? = nil
    var disasterSettings: DisasterScheduleFingerprint? = nil
    var homeAddress: String
    var workAddress: String
    var commuteMode: CommuteAlarmSettings.CommuteMode
    var alarmHour: Int
    var alarmMinute: Int
    var selectedWeekdays: Set<Int>
    var rainLeadTimeMinutes: Int
    var rainProbabilityThreshold: Double
    var alarmSoundRawValue: String
    /// Part of the fingerprint so regenerating the voice counts as a settings
    /// change: the existing reconcile pass then re-registers the alarm with the new
    /// clip without any extra plumbing.
    var aiVoiceFileName: String?
    var earlyAlarmSoundRawValue: String
    var earlyAIVoiceFileName: String?
    var isSnoozeEnabled: Bool
    var snoozeDurationMinutes: Int
}

extension AlarmScheduleFingerprint {
    /// A fingerprint stored before 1.6.3 has no snooze fields. Filling them with
    /// what that build effectively did — snooze on, 5-minute follow-ups — keeps the
    /// comparison equal for anyone who has not touched the new settings. Letting the
    /// decode fail instead would silently disable the "settings changed, reschedule"
    /// notice for every upgraded install, which is the more dangerous failure: the
    /// user edits the alarm time, sees no warning, and gets woken at the old one.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calendarSettings = try values.decodeIfPresent(AlarmCalendarSettings.self, forKey: .calendarSettings)
        disasterSettings = try values.decodeIfPresent(DisasterScheduleFingerprint.self, forKey: .disasterSettings)
        homeAddress = try values.decode(String.self, forKey: .homeAddress)
        workAddress = try values.decode(String.self, forKey: .workAddress)
        commuteMode = try values.decode(CommuteAlarmSettings.CommuteMode.self, forKey: .commuteMode)
        alarmHour = try values.decode(Int.self, forKey: .alarmHour)
        alarmMinute = try values.decode(Int.self, forKey: .alarmMinute)
        selectedWeekdays = try values.decode(Set<Int>.self, forKey: .selectedWeekdays)
        rainLeadTimeMinutes = try values.decode(Int.self, forKey: .rainLeadTimeMinutes)
        rainProbabilityThreshold = try values.decode(Double.self, forKey: .rainProbabilityThreshold)
        alarmSoundRawValue = try values.decode(String.self, forKey: .alarmSoundRawValue)
        aiVoiceFileName = try values.decodeIfPresent(String.self, forKey: .aiVoiceFileName)
        earlyAlarmSoundRawValue = try values.decodeIfPresent(String.self, forKey: .earlyAlarmSoundRawValue) ?? alarmSoundRawValue
        earlyAIVoiceFileName = values.contains(.earlyAlarmSoundRawValue)
            ? try values.decodeIfPresent(String.self, forKey: .earlyAIVoiceFileName)
            : aiVoiceFileName
        isSnoozeEnabled = try values.decodeIfPresent(Bool.self, forKey: .isSnoozeEnabled) ?? true
        snoozeDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 5
    }
}

extension CommuteAlarmSettings {
    func scheduleFingerprint(calendar: Calendar = .current) -> AlarmScheduleFingerprint {
        let time = calendar.dateComponents([.hour, .minute], from: alarmTime)
        return AlarmScheduleFingerprint(
            calendarSettings: calendarSettings.isActive ? calendarSettings : nil,
            disasterSettings: isDisasterSuspensionEnabled ? DisasterScheduleFingerprint(
                home: homeSuspensionRegion, destination: workSuspensionRegion,
                observesWork: observesWorkSuspensions, observesSchool: observesSchoolSuspensions) : nil,
            homeAddress: homeAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            workAddress: workAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            commuteMode: commuteMode,
            alarmHour: time.hour ?? 7,
            alarmMinute: time.minute ?? 30,
            selectedWeekdays: selectedWeekdays,
            rainLeadTimeMinutes: rainLeadTimeMinutes,
            rainProbabilityThreshold: rainProbabilityThreshold,
            alarmSoundRawValue: alarmSound.rawValue,
            aiVoiceFileName: alarmSound == .aiVoice ? aiVoiceFileName : nil,
            earlyAlarmSoundRawValue: earlyAlarmSound.rawValue,
            earlyAIVoiceFileName: earlyAlarmSound == .aiVoice ? earlyAIVoiceFileName : nil,
            isSnoozeEnabled: isSnoozeEnabled,
            snoozeDurationMinutes: snoozeDurationMinutes
        )
    }

    /// The file the alarm should actually play, or `nil` to let the system choose
    /// its own alarm tone.
    ///
    /// A generated clip can go missing between being chosen and being needed — the
    /// user clears storage, restores to a new device, or generation half-failed — so
    /// this falls back to a shipped tone rather than naming a file that is not there.
    /// A wrong-sounding alarm is recoverable; a silent one is not.
    var soundFileNameOverride: String? {
        soundFileNameOverride(for: .normal)
    }

    func sound(for slot: SoundSlot) -> AlarmSound {
        slot == .early ? earlyAlarmSound : alarmSound
    }

    mutating func setSound(_ sound: AlarmSound, for slot: SoundSlot) {
        if slot == .early { earlyAlarmSound = sound } else { alarmSound = sound }
    }

    func voiceFileName(for slot: SoundSlot) -> String? {
        slot == .early ? earlyAIVoiceFileName : aiVoiceFileName
    }

    func voicePersona(for slot: SoundSlot) -> VoicePersona {
        slot == .early ? earlyAIVoicePersona : aiVoicePersona
    }

    func voiceText(for slot: SoundSlot) -> String {
        slot == .early ? earlyAIVoiceText : aiVoiceText
    }

    mutating func setVoice(fileName: String, persona: VoicePersona, text: String, for slot: SoundSlot) {
        if slot == .early {
            earlyAIVoiceFileName = fileName
            earlyAIVoicePersona = persona
            earlyAIVoiceText = text
            earlyAlarmSound = .aiVoice
        } else {
            aiVoiceFileName = fileName
            aiVoicePersona = persona
            aiVoiceText = text
            alarmSound = .aiVoice
        }
    }

    var generatedVoiceFileNames: Set<String> {
        Set([aiVoiceFileName, earlyAIVoiceFileName].compactMap { $0 })
    }

    func soundFileNameOverride(for slot: SoundSlot) -> String? {
        switch sound(for: slot) {
        case .systemDefault:
            nil
        case .aiVoice:
            voiceFileName(for: slot).flatMap(GeneratedVoiceStore.existingFileName(named:))
                ?? AlarmSound.rainyClock.fileName
        default:
            sound(for: slot).fileName
        }
    }

    /// Use the time actually registered, not just a wet forecast: a zero lead
    /// time or a missed early time still rings with the normal sound.
    func soundSelection(ringDate: Date, normalDate: Date) -> AlarmSoundSelection {
        let slot: SoundSlot = ringDate < normalDate ? .early : .normal
        return AlarmSoundSelection(sound: sound(for: slot), fileNameOverride: soundFileNameOverride(for: slot))
    }
}

struct AlarmSoundSelection: Codable, Equatable, Sendable {
    var sound: CommuteAlarmSettings.AlarmSound
    var fileNameOverride: String?
}

struct ScheduledAlarmSummary: Codable, Equatable {
    var normalAlarmDate: Date
    var scheduledAlarmDate: Date
    var weatherRefreshDate: Date
    var exceedsRainThreshold: Bool
    var leadTimeMinutes: Int
    var rainProbabilityThreshold: Double
    var maximumPrecipitationProbability: Double
    /// Where along the route `maximumPrecipitationProbability` was read —
    /// "住家", "路程 ½", "公司" — so the evening preview can say which part of the
    /// commute moved the alarm. Absent in summaries stored before 1.6.9.
    var wettestSegmentName: String?
    var calendarPlan: CalendarAlarmPlan?
    var calendarForecastDate: Date?
    /// Published only after the corresponding system schedule was committed.
    var disasterSkips: [AppliedDisasterSkip]? = nil
}

extension ScheduledAlarmSummary {
    /// Returns the summary with past dates advanced to their next weekly occurrence,
    /// so a summary reloaded after relaunch still describes the upcoming ring.
    func rollingForward(
        selectedWeekdays: Set<Int>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledAlarmSummary {
        var summary = self
        if let plan = calendarPlan {
            if let next = plan.occurrences.first(where: { $0.ringDate > now }) {
                let checkOffset = weatherRefreshDate.timeIntervalSince(normalAlarmDate)
                summary.normalAlarmDate = next.normalDate
                summary.scheduledAlarmDate = next.ringDate
                summary.weatherRefreshDate = next.normalDate.addingTimeInterval(checkOffset)
                summary.exceedsRainThreshold = next.ringDate < next.normalDate
                summary.leadTimeMinutes = Int(next.normalDate.timeIntervalSince(next.ringDate) / 60)
                if calendarForecastDate != next.normalDate {
                    summary.maximumPrecipitationProbability = 0
                    summary.wettestSegmentName = nil
                    summary.calendarForecastDate = nil
                }
            }
            return summary
        }
        let weekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        summary.scheduledAlarmDate = Self.nextOccurrence(
            of: scheduledAlarmDate,
            weekdays: Self.shiftedWeekdays(weekdays, from: normalAlarmDate, to: scheduledAlarmDate, calendar: calendar),
            after: now,
            calendar: calendar
        )
        summary.weatherRefreshDate = Self.nextOccurrence(
            of: weatherRefreshDate,
            weekdays: Self.shiftedWeekdays(weekdays, from: normalAlarmDate, to: weatherRefreshDate, calendar: calendar),
            after: now,
            calendar: calendar
        )
        summary.normalAlarmDate = Self.nextOccurrence(
            of: normalAlarmDate,
            weekdays: weekdays,
            after: now,
            calendar: calendar
        )
        return summary
    }

    /// `rollingForward`, except that a weekly summary's ring and normal time move as the
    /// pair AlarmKit's weekly repeat rings: the next ring after `now`, and the normal time
    /// that ring serves. For display (`AlarmViewModel.tomorrowStatus`) only.
    ///
    /// `rollingForward` moves each date on its own, so between an early ring and its normal
    /// time it pairs the NEXT ring with TODAY's normal time — for a lead that crosses
    /// midnight, a mismatch that reads as "update needed". `init` and the background
    /// refresh guard depend on that unrolled normal time, so they keep `rollingForward`.
    ///
    /// Works on a summary that was already rolled one date at a time (a relaunch between
    /// the ring and the normal time): each date keeps its wall-clock time, so the lead and
    /// its day shift are recovered from the times of day, not from the stored dates.
    func rollingForwardAsPair(
        selectedWeekdays: Set<Int>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledAlarmSummary {
        var summary = rollingForward(selectedWeekdays: selectedWeekdays, now: now, calendar: calendar)
        guard calendarPlan == nil else { return summary }

        let day: TimeInterval = 86_400
        func secondOfDay(_ date: Date) -> TimeInterval {
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            return TimeInterval((time.hour ?? 0) * 3_600 + (time.minute ?? 0) * 60 + (time.second ?? 0))
        }
        let ringTime = secondOfDay(scheduledAlarmDate)
        let lead = (secondOfDay(normalAlarmDate) - ringTime + day).truncatingRemainder(dividingBy: day)
        let dayShift = ringTime + lead >= day ? 1 : 0
        let weekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        let ringWeekdays = dayShift == 0 ? weekdays
            : Set(weekdays.map { AlarmTimeCalculator.shiftedWeekday($0, byDays: -dayShift) })
        let ring = Self.nextOccurrence(of: scheduledAlarmDate, weekdays: ringWeekdays, after: now, calendar: calendar)

        // An upcoming ring still paired with its own normal time: nothing to re-pair.
        let storedLead = normalAlarmDate.timeIntervalSince(scheduledAlarmDate)
        if ring == scheduledAlarmDate, storedLead >= 0, storedLead < day { return summary }

        let normalTime = calendar.dateComponents([.hour, .minute, .second], from: normalAlarmDate)
        guard let normalDay = calendar.date(byAdding: .day, value: dayShift, to: calendar.startOfDay(for: ring)),
              let normal = calendar.date(bySettingHour: normalTime.hour ?? 0, minute: normalTime.minute ?? 0,
                                         second: normalTime.second ?? 0, of: normalDay) else { return summary }
        summary.scheduledAlarmDate = ring
        summary.normalAlarmDate = normal
        return summary
    }

    /// A ring that sits on an earlier day than the normal alarm (rain lead time
    /// crossing midnight) rings on every selected weekday shifted by that delta.
    private static func shiftedWeekdays(
        _ weekdays: Set<Int>,
        from reference: Date,
        to date: Date,
        calendar: Calendar
    ) -> Set<Int> {
        let dayShift = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: reference),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        guard dayShift != 0 else {
            return weekdays
        }

        return Set(weekdays.map { AlarmTimeCalculator.shiftedWeekday($0, byDays: dayShift) })
    }

    private static func nextOccurrence(
        of date: Date,
        weekdays: Set<Int>,
        after now: Date,
        calendar: Calendar
    ) -> Date {
        guard date < now else {
            return date
        }

        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
                  let candidate = calendar.date(
                      bySettingHour: time.hour ?? 0,
                      minute: time.minute ?? 0,
                      second: time.second ?? 0,
                      of: day
                  ),
                  candidate > now,
                  weekdays.contains(calendar.component(.weekday, from: candidate)) else {
                continue
            }

            return candidate
        }

        return date
    }
}
