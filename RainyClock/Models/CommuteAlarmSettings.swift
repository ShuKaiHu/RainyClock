import Foundation

struct CommuteAlarmSettings: Codable, Equatable {
    static let allWeekdays = Set(1...7)

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

struct RouteWeatherSnapshot: Equatable {
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

struct RouteWeatherSegment: Identifiable, Equatable {
    enum Condition: String, Equatable, Sendable {
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
        isSnoozeEnabled = try values.decodeIfPresent(Bool.self, forKey: .isSnoozeEnabled) ?? true
        snoozeDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 5
    }
}

extension CommuteAlarmSettings {
    func scheduleFingerprint(calendar: Calendar = .current) -> AlarmScheduleFingerprint {
        let time = calendar.dateComponents([.hour, .minute], from: alarmTime)
        return AlarmScheduleFingerprint(
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
        switch alarmSound {
        case .systemDefault:
            nil
        case .aiVoice:
            aiVoiceFileName.flatMap(GeneratedVoiceStore.existingFileName(named:))
                ?? AlarmSound.rainyClock.fileName
        default:
            alarmSound.fileName
        }
    }
}

struct ScheduledAlarmSummary: Codable, Equatable {
    var normalAlarmDate: Date
    var scheduledAlarmDate: Date
    var weatherRefreshDate: Date
    var exceedsRainThreshold: Bool
    var leadTimeMinutes: Int
    var rainProbabilityThreshold: Double
    var maximumPrecipitationProbability: Double
}

extension ScheduledAlarmSummary {
    /// Returns the summary with past dates advanced to their next weekly occurrence,
    /// so a summary reloaded after relaunch still describes the upcoming ring.
    func rollingForward(
        selectedWeekdays: Set<Int>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledAlarmSummary {
        let weekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        var summary = self
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
