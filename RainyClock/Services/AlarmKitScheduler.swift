import Foundation
import OSLog

/// Persisted identity is useful only together with an unchanged configuration and
/// a still-scheduled alarm observed in AlarmKit. A saved UUID alone is not proof
/// that the system still owns a future alarm.
struct CalendarAlarmRegistration: Codable, Equatable, Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        var normalDate: Date
        var ringDate: Date
        var soundRawValue: String
        var soundFileNameOverride: String?
        var snoozeMinutes: Int?
        var timeZoneID: String
        var presentationVersion = 1
    }

    var id: UUID
    var configuration: Configuration

    /// Pure reconciliation. The caller verifies the live system state before
    /// including an ID in `reusableIdentifiers`; this cannot resurrect a paused,
    /// snoozing, ringing, deleted, or expired alarm from its stored UUID.
    static func reconcile(_ configurations: [Configuration], previous: [Self],
                          reusableIdentifiers: Set<UUID>, now: Date) -> [Self] {
        var result: [Self] = []
        var retained: Set<UUID> = []
        for configuration in configurations where configuration.ringDate > now {
            guard !result.contains(where: { $0.configuration == configuration }) else { continue }
            if let existing = previous.first(where: {
                $0.configuration == configuration && reusableIdentifiers.contains($0.id) && !retained.contains($0.id)
            }) {
                result.append(existing)
                retained.insert(existing.id)
            } else {
                result.append(Self(id: UUID(), configuration: configuration))
            }
        }
        return result
    }
}

#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import SwiftUI

/// What the scheduler reads of one of its system alarms. `Alarm` has no public
/// initializer, so a fake alarm list is written in these instead.
@available(iOS 26.0, *)
struct AlarmSnapshot: Equatable, Sendable {
    var id: UUID
    var state: Alarm.State
    var schedule: Alarm.Schedule?
    var countdownDuration: Alarm.CountdownDuration?
}

/// An alarm to register. `AlarmManager.AlarmConfiguration` does not expose what it
/// holds, so the scheduler hands over the parts and the system side assembles it.
@available(iOS 26.0, *)
struct AlarmRequest: Sendable {
    var schedule: Alarm.Schedule
    var countdownDuration: Alarm.CountdownDuration?
    var attributes: AlarmAttributes<CommuteAlarmMetadata>
    var sound: AlertConfiguration.AlertSound
}

/// The part of `AlarmManager` the scheduler uses, so tests can run `AlarmKitScheduler`
/// against a fake alarm list instead of the system's.
@available(iOS 26.0, *)
protocol AlarmKitManaging: Sendable {
    /// Throws when the list cannot be read, never an empty list in its place.
    func alarms() throws -> [AlarmSnapshot]
    func schedule(id: UUID, request: AlarmRequest) async throws
    func cancel(id: UUID) throws
}

@available(iOS 26.0, *)
struct SystemAlarmManager: AlarmKitManaging {
    func alarms() throws -> [AlarmSnapshot] {
        try AlarmManager.shared.alarms.map {
            AlarmSnapshot(id: $0.id, state: $0.state, schedule: $0.schedule, countdownDuration: $0.countdownDuration)
        }
    }

    func schedule(id: UUID, request: AlarmRequest) async throws {
        _ = try await AlarmManager.shared.schedule(id: id, configuration: AlarmManager.AlarmConfiguration(
            countdownDuration: request.countdownDuration, schedule: request.schedule,
            attributes: request.attributes, sound: request.sound))
    }

    func cancel(id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }
}

/// Schedules the commute alarm through AlarmKit (iOS 26+).
///
/// Unlike a `UNNotificationRequest`, an AlarmKit alarm overrides silent mode and
/// Focus, keeps alerting until the user acts, and offers a native snooze — so this
/// path needs none of the follow-up-notification bookkeeping that
/// `LocalNotificationScheduler` carries for older systems.
@available(iOS 26.0, *)
struct AlarmKitScheduler: NotificationScheduling {
    private static let registrationQueue = AlarmRegistrationQueue()
    private static let logger = Logger(subsystem: "com.shukaihu.RainyClock", category: "AlarmKit")
    private static let calendarRegistrationsKey = "alarmKitCalendarRegistrations.v1"
    /// Replaced alarms not cancelled yet — ringing or snoozing when they were replaced,
    /// or a cancel that failed. See `retire(_:)`.
    private static let supersededAlarmsKey = "alarmKitSupersededAlarms.v1"

    private enum RegistrationError: Error {
        case systemStateChanged
    }

    private let manager: any AlarmKitManaging
    /// UserDefaults is thread-safe but not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    /// Retires the pre-26 notification alarms once AlarmKit has taken over.
    private let cancelNotificationAlarms: @Sendable () async -> Void

    init(manager: any AlarmKitManaging = SystemAlarmManager(), defaults: UserDefaults = .standard,
         cancelNotificationAlarms: @escaping @Sendable () async -> Void = { await LocalNotificationScheduler.cancelScheduledAlarms() }) {
        self.manager = manager
        self.defaults = defaults
        self.cancelNotificationAlarms = cancelNotificationAlarms
    }

    func requestAuthorization() async throws -> Bool {
        let manager = AlarmManager.shared
        if manager.authorizationState == .authorized {
            return true
        }

        return try await manager.requestAuthorization() == .authorized
    }

    func scheduleAlarm(at date: Date, normalAlarmDate: Date, weekdays: Set<Int>,
                       sound: CommuteAlarmSettings.AlarmSound, soundFileNameOverride: String?,
                       snoozeMinutes: Int?, title: String, body: String) async throws {
        try await Self.registrationQueue.run {
            try await performScheduleAlarm(at: date, normalAlarmDate: normalAlarmDate, weekdays: weekdays,
                sound: sound, soundFileNameOverride: soundFileNameOverride, snoozeMinutes: snoozeMinutes, title: title, body: body)
        }
    }

    private func performScheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        soundFileNameOverride: String?,
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws {
        let calendar = Calendar.current
        let selectedWeekdays = weekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : weekdays

        // The ring may land on an earlier day than the normal alarm (rain lead time
        // crossing midnight), so every selected weekday shifts by the same day delta.
        let dayShift = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: normalAlarmDate),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let ringWeekdays = selectedWeekdays.map { AlarmTimeCalculator.shiftedWeekday($0, byDays: dayShift) }

        let ringTime = calendar.dateComponents([.hour, .minute], from: date)
        let normalTime = calendar.dateComponents([.hour, .minute], from: normalAlarmDate)
        // A ring that differs from the configured alarm time is one rain moved earlier.
        // `title`/`body` from the protocol go unused: the alert renders in system UI
        // that takes a LocalizedStringResource, so the presentation below builds its
        // own copy from keys instead of pre-resolved strings.
        let adjustedForRain = abs(date.timeIntervalSince(normalAlarmDate)) >= 60

        let metadata = CommuteAlarmMetadata(
            adjustedForRain: adjustedForRain,
            normalAlarmHour: normalTime.hour ?? 0,
            normalAlarmMinute: normalTime.minute ?? 0
        )
        let attributes = AlarmAttributes(
            presentation: Self.presentation(adjustedForRain: adjustedForRain, snoozeMinutes: snoozeMinutes),
            metadata: metadata,
            tintColor: Color.accentColor
        )
        let schedule = Alarm.Schedule.relative(
            Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(
                    hour: ringTime.hour ?? 0,
                    minute: ringTime.minute ?? 0
                ),
                repeats: .weekly(ringWeekdays.sorted().compactMap(Self.localeWeekday))
            )
        )
        let request = AlarmRequest(
            schedule: schedule,
            countdownDuration: snoozeMinutes.map { Alarm.CountdownDuration(preAlert: nil, postAlert: TimeInterval($0 * 60)) },
            attributes: attributes,
            sound: Self.alertSound(fileNamed: soundFileNameOverride)
        )

        // Register the replacement before retiring what is already armed: if
        // scheduling throws, the user keeps the alarm they had instead of silently
        // ending up with none.
        let identifier = UUID()
        try Task.checkCancellation()
        var retiringOldAlarms = false
        var superseded: [AlarmSnapshot] = []
        do {
            try await manager.schedule(id: identifier, request: request)
            try Task.checkCancellation()
            // Read after that await, during which an old alarm may have started ringing.
            superseded = try manager.alarms().filter { $0.id != identifier }
            retiringOldAlarms = true
            try retire(superseded)
        } catch {
            if !retiringOldAlarms { try? manager.cancel(id: identifier) }
            throw error
        }
        defaults.removeObject(forKey: Self.calendarRegistrationsKey)
        // An upgraded install can still hold pending notification requests from the
        // pre-26 path; leaving them armed would ring twice.
        await cancelNotificationAlarms()
        Self.logger.info("Scheduled AlarmKit alarm \(identifier.uuidString, privacy: .public) on \(ringWeekdays.count, privacy: .public) weekdays, superseding \(superseded.count, privacy: .public)")
    }

    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        try await Self.registrationQueue.run {
            try await performCalendar(plan, sound: sound, soundFileNameOverride: soundFileNameOverride,
                                      snoozeMinutes: snoozeMinutes, title: title, body: body)
        }
    }

    private func performCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        // A read failure must not be mistaken for an empty alarm set.
        let liveAlarms = try manager.alarms()
        let liveByID = Dictionary(uniqueKeysWithValues: liveAlarms.map { ($0.id, $0) })
        let previous = loadCalendarRegistrations()
        let now = Date()
        let reusable = Set(previous.compactMap { registration -> UUID? in
            guard let alarm = liveByID[registration.id],
                  Self.matchesScheduledAlarm(alarm, registration: registration, now: now) else { return nil }
            return registration.id
        })
        let configurations = plan.occurrences.map {
            let selectedSound = $0.resolvedSound(fallback: .init(sound: sound, fileNameOverride: soundFileNameOverride))
            return CalendarAlarmRegistration.Configuration(normalDate: $0.normalDate, ringDate: $0.ringDate,
                soundRawValue: selectedSound.sound.rawValue, soundFileNameOverride: selectedSound.fileNameOverride,
                snoozeMinutes: snoozeMinutes, timeZoneID: plan.timeZoneID)
        }
        let registrations = CalendarAlarmRegistration.reconcile(configurations, previous: previous,
            reusableIdentifiers: reusable, now: now)
        let retainedIDs = Set(registrations.map(\.id))
        // Encode before any mutation: serialization failure must preserve the
        // old schedule, just like a failed system registration does.
        let storedRegistrations = try JSONEncoder().encode(registrations)
        var registered: [UUID] = []
        var retiringOldAlarms = false
        do {
            for registration in registrations where !reusable.contains(registration.id) {
                try Task.checkCancellation()
                let configuration = registration.configuration
                let adjusted = abs(configuration.ringDate.timeIntervalSince(configuration.normalDate)) >= 60
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: configuration.timeZoneID) ?? .current
                let time = calendar.dateComponents([.hour, .minute], from: configuration.normalDate)
                let attributes = AlarmAttributes(
                    presentation: Self.presentation(adjustedForRain: adjusted, snoozeMinutes: snoozeMinutes),
                    metadata: CommuteAlarmMetadata(adjustedForRain: adjusted, normalAlarmHour: time.hour ?? 7, normalAlarmMinute: time.minute ?? 30),
                    tintColor: Color.accentColor)
                let request = AlarmRequest(
                    schedule: .fixed(configuration.ringDate),
                    countdownDuration: snoozeMinutes.map { Alarm.CountdownDuration(preAlert: nil, postAlert: TimeInterval($0 * 60)) },
                    attributes: attributes,
                    sound: Self.alertSound(fileNamed: configuration.soundFileNameOverride))
                // Record the attempted ID before awaiting so cancellation or an
                // uncertain error can still retire a partially registered alarm.
                registered.append(registration.id)
                try await manager.schedule(id: registration.id, request: request)
            }
            try Task.checkCancellation()
            // A reused alarm can start ringing, be snoozed, or be deleted while
            // another schedule() call suspends us. Recheck before retiring old IDs.
            let confirmedAlarms = try manager.alarms()
            let confirmed = Dictionary(uniqueKeysWithValues: confirmedAlarms.map { ($0.id, $0) })
            let confirmedAt = Date()
            guard registrations.allSatisfy({ registration in
                guard let alarm = confirmed[registration.id] else { return false }
                return Self.matchesScheduledAlarm(alarm, registration: registration, now: confirmedAt)
            }) else { throw RegistrationError.systemStateChanged }
            // An empty plan intentionally cancels the period. A cancellation
            // error leaves the saved mapping untouched and is reported upstream.
            retiringOldAlarms = true
            try retire(confirmedAlarms.filter { !retainedIDs.contains($0.id) })
            defaults.set(storedRegistrations, forKey: Self.calendarRegistrationsKey)
        } catch {
            if retiringOldAlarms {
                // Some old IDs may already be gone. Preserve their replacements
                // and retain identities for a later repair; the UI receives an
                // error and does not claim a completed skip.
                defaults.set(storedRegistrations, forKey: Self.calendarRegistrationsKey)
            } else {
                for id in registered { try? manager.cancel(id: id) }
            }
            throw error
        }
        await cancelNotificationAlarms()
    }

    /// Cancels the alarms a registration replaced, except one ringing or snoozing: that
    /// is left to finish, since only turning the alarm off ends a snooze. What is not
    /// cancelled is remembered until it is, and `retireSupersededAlarms` cancels it once
    /// it is merely scheduled again — a weekly one would otherwise ring at its old time
    /// on its next weekday. Replaces the whole record: every alarm it still covers is in
    /// `superseded`.
    private func retire(_ superseded: [AlarmSnapshot]) throws {
        var remaining = Set(superseded.map(\.id))
        defer { defaults.set(remaining.map(\.uuidString), forKey: Self.supersededAlarmsKey) }
        for alarm in superseded where alarm.state == .scheduled {
            try manager.cancel(id: alarm.id)
            remaining.remove(alarm.id)
        }
    }

    /// Cancels what `retire` had to leave once it has finished ringing and snoozing.
    /// Called on activation and from background refresh; every registration does the
    /// same for all the alarms it replaces.
    func retireSupersededAlarms() async {
        try? await Self.registrationQueue.run {
            let superseded = Set((defaults.stringArray(forKey: Self.supersededAlarmsKey) ?? []).compactMap(UUID.init(uuidString:)))
            guard !superseded.isEmpty else { return }
            // A list that cannot be read keeps the record for the next pass.
            try retire(manager.alarms().filter { superseded.contains($0.id) })
        }
    }

    private func loadCalendarRegistrations() -> [CalendarAlarmRegistration] {
        guard let data = defaults.data(forKey: Self.calendarRegistrationsKey),
              let registrations = try? JSONDecoder().decode([CalendarAlarmRegistration].self, from: data) else { return [] }
        return registrations
    }

    private static func matchesScheduledAlarm(_ alarm: AlarmSnapshot, registration: CalendarAlarmRegistration, now: Date) -> Bool {
        let configuration = registration.configuration
        let expectedCountdown = configuration.snoozeMinutes.map {
            Alarm.CountdownDuration(preAlert: nil, postAlert: TimeInterval($0 * 60))
        }
        return configuration.ringDate > now && alarm.state == .scheduled
            && alarm.schedule == .fixed(configuration.ringDate)
            && alarm.countdownDuration == expectedCountdown
    }

    /// AlarmKit only exposes the calling app's alarms, so this can never see — or
    /// cancel — another app's or the system's.
    static func scheduledAlarmIdentifiers() -> [Alarm.ID] {
        ((try? AlarmManager.shared.alarms) ?? []).map(\.id)
    }

    /// An alarm of ours is alerting, counting down a snooze, or paused — anything but
    /// merely scheduled. A weekly relative alarm in that state survives a calendar
    /// re-registration (which retires `.scheduled` only), so a one-time skip waits.
    static func hasAlarmInProgress() -> Bool {
        ((try? AlarmManager.shared.alarms) ?? []).contains { $0.state != .scheduled }
    }

    /// Whether any alarm of ours may still be registered. A list that cannot be read
    /// counts as "yes": turning the alarm off must never claim success it cannot see.
    static func mayHoldAlarms() -> Bool {
        do { return try !AlarmManager.shared.alarms.isEmpty } catch { return true }
    }

    /// Cancels every alarm this app owns — a ringing or snoozing one too. One failed cancel
    /// must not leave the rest armed — turning the alarm off depends on this — so each is
    /// tried, and a second pass catches what the first missed.
    func cancelScheduledAlarms() async {
        try? await Self.registrationQueue.run {
            try Task.checkCancellation()
            var unreadable = false
            for _ in 0..<2 {
                guard let identifiers = try? manager.alarms().map(\.id) else { unreadable = true; break }
                if identifiers.isEmpty { break }
                for identifier in identifiers { try? manager.cancel(id: identifier) }
            }
            // Keep the bookkeeping while the list could not be read: a later pass needs it.
            if !unreadable {
                defaults.removeObject(forKey: Self.calendarRegistrationsKey)
                defaults.removeObject(forKey: Self.supersededAlarmsKey)
            }
        }
    }

    /// Pins the containing app's bundle by URL. These resources are decoded in the
    /// widget extension's process to render the snooze Live Activity, where `.main`
    /// would resolve to the appex — which ships no strings — and the UI would show
    /// the raw key.
    private static func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.main.bundleURL))
    }

    /// The system alarm tone is only reachable through `.default`; every other
    /// choice names a file, either one this app ships or one it generated into the
    /// container's `Library/Sounds` — AlarmKit resolves both by bare name, and an
    /// empty name would ring nothing.
    private static func alertSound(fileNamed fileName: String?) -> AlertConfiguration.AlertSound {
        guard let fileName, !fileName.isEmpty else {
            return .default
        }
        return .named(fileName)
    }

    private static func presentation(adjustedForRain: Bool, snoozeMinutes: Int?) -> AlarmPresentation {
        // Localized keys rather than resolved strings: AlarmKit renders the alert in
        // the system UI, so it resolves them in whatever locale is current when the
        // alarm fires instead of the one that was active when it was scheduled.
        let title = adjustedForRain
            ? localized("alarm_alert_title_adjusted")
            : localized("alarm_alert_title_normal")
        let snoozeButton = snoozeMinutes.map { _ in
            AlarmButton(
                text: localized("alarm_snooze_button"),
                textColor: .white,
                systemImageName: "zzz"
            )
        }
        // iOS 26.0 requires an explicit stop button; 26.1 supplies its own and
        // deprecated the parameter.
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(
                title: title,
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: snoozeButton.map { _ in .countdown }
            )
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(
                    text: localized("stop_alarm"),
                    textColor: .white,
                    systemImageName: "stop.circle"
                ),
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: snoozeButton.map { _ in .countdown }
            )
        }
        // AlarmKit expects a countdown presentation whenever an alarm can enter the
        // countdown state, which only the snooze button does.
        let countdown = snoozeMinutes.map { _ in
            AlarmPresentation.Countdown(title: localized("alarm_snoozing_title"))
        }
        return AlarmPresentation(alert: alert, countdown: countdown)
    }

    /// Maps `Calendar`'s 1-based weekday (1 = Sunday) onto `Locale.Weekday`.
    private static func localeWeekday(_ weekday: Int) -> Locale.Weekday? {
        switch weekday {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}
#endif
