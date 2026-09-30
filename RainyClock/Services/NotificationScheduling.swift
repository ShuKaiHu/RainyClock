import Foundation
import OSLog
import UserNotifications

protocol NotificationScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func scheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        /// The file to play, from `CommuteAlarmSettings.soundFileNameOverride`.
        /// Carried alongside `sound` rather than derived from it because a generated
        /// clip's name is per-user and cannot come out of the enum, and because that
        /// property is where the "file went missing, fall back to a shipped tone"
        /// rule lives. `nil` means the system picks its own alarm tone.
        soundFileNameOverride: String?,
        /// Minutes before the alarm rings again, or nil when the user turned
        /// snooze off. On iOS 26 this is AlarmKit's snooze; on older systems it is
        /// the follow-up ring interval, which is the same "how long until it nags
        /// again" number without the tap.
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws
    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws
    /// Removes every alarm this scheduler owns without arming a replacement. Used
    /// when an address change invalidates the scheduled route.
    func cancelScheduledAlarms() async
}

enum CalendarSchedulingError: Error { case unsupported }
extension NotificationScheduling {
    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        throw CalendarSchedulingError.unsupported
    }
}

/// Routes scheduling to AlarmKit where it exists and to local notifications
/// everywhere else. AlarmKit alarms override silent mode and Focus; the
/// notification fallback cannot, and stays the behaviour on iOS 17–25.
struct SystemAlarmScheduler: NotificationScheduling {
    /// An alarm is ringing or snoozing. Only AlarmKit exposes that; below iOS 26 it is
    /// unknown and reported as false.
    static func hasAlarmInProgress() -> Bool {
        if #available(iOS 26.0, *) { return AlarmKitScheduler.hasAlarmInProgress() }
        return false
    }

    /// The system still holds alarms of ours — used after turning the alarm off, to say
    /// so instead of showing "off" over alarms that would still ring.
    static func holdsRegisteredAlarms() -> Bool {
        if #available(iOS 26.0, *) {
            return AlarmKitScheduler.mayHoldAlarms() || LocalNotificationScheduler.hasScheduledAlarmPlan
        }
        return LocalNotificationScheduler.hasScheduledAlarmPlan
    }

    func requestAuthorization() async throws -> Bool {
        if #available(iOS 26.0, *) {
            return try await AlarmKitScheduler().requestAuthorization()
        }

        return try await LocalNotificationScheduler().requestAuthorization()
    }

    func scheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        soundFileNameOverride: String?,
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws {
        if #available(iOS 26.0, *) {
            try await AlarmKitScheduler().scheduleAlarm(
                at: date,
                normalAlarmDate: normalAlarmDate,
                weekdays: weekdays,
                sound: sound,
                soundFileNameOverride: soundFileNameOverride,
                snoozeMinutes: snoozeMinutes,
                title: title,
                body: body
            )
            return
        }

        try await LocalNotificationScheduler().scheduleAlarm(
            at: date,
            normalAlarmDate: normalAlarmDate,
            weekdays: weekdays,
            sound: sound,
            soundFileNameOverride: soundFileNameOverride,
            snoozeMinutes: snoozeMinutes,
            title: title,
            body: body
        )
    }

    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        if #available(iOS 26.0, *) {
            try await AlarmKitScheduler().scheduleCalendar(plan, sound: sound, soundFileNameOverride: soundFileNameOverride,
                                                         snoozeMinutes: snoozeMinutes, title: title, body: body)
        } else {
            try await LocalNotificationScheduler().scheduleCalendar(plan, sound: sound, soundFileNameOverride: soundFileNameOverride,
                                                                  snoozeMinutes: snoozeMinutes, title: title, body: body)
        }
    }

    func cancelScheduledAlarms() async {
        // Both paths, not either: an install that upgraded to iOS 26 without
        // rescheduling still owns notification alarms alongside AlarmKit's.
        if #available(iOS 26.0, *) {
            await AlarmKitScheduler().cancelScheduledAlarms()
        }
        await LocalNotificationScheduler().cancelScheduledAlarms()
    }
}

/// Serializes every pending-notification mutation: schedule/acknowledge/re-arm run to
/// completion one at a time, so concurrent entry points (the notification delegate and
/// the scenePhase activation handler) cannot interleave their remove/add sequences.
actor AlarmRegistrationQueue {
    private var lastTask: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let previous = lastTask
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        lastTask = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// The part of `UNUserNotificationCenter` the notification alarms use, so tests can run
/// `LocalNotificationScheduler` against a fake queue instead of the simulator's own.
protocol AlarmNotificationCenter: Sendable {
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func deliveredNotificationIdentifiers() async -> [String]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

struct SystemNotificationCenter: AlarmNotificationCenter {
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

struct LocalNotificationScheduler: NotificationScheduling {
    static let categoryIdentifier = "RAINY_CLOCK_ALARM"
    static let stopActionIdentifier = "RAINY_CLOCK_STOP"
    private static let identifierPrefix = "commute-rain-alarm"
    /// Used for plans stored before the interval became configurable in 1.6.3.
    private static let legacyFollowUpIntervalMinutes = 5
    private static let maximumFollowUpCount = 10
    /// iOS allows 64 pending requests per app. Seven are left for the
    /// evening previews (`EveningPreviewPlanner.horizonDays`), so with all seven
    /// weekdays selected the alarm gets 8 requests a day instead of 9.
    private static let pendingNotificationLimit = 56
    private static let storedPlanKey = "scheduledAlarmPlan"
    private static let rearmAfterKey = "scheduledAlarmRearmAfter"
    private static let acknowledgedAtKey = "scheduledAlarmAcknowledgedAt"
    private static let registrationQueue = AlarmRegistrationQueue()

    private let center: any AlarmNotificationCenter
    /// UserDefaults is thread-safe but not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(center: any AlarmNotificationCenter = SystemNotificationCenter(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    static func registerNotificationCategories() {
        // Stop stays a background action (no .foreground): it must silence the alarm
        // even when the user cannot or will not unlock the device. Tapping the
        // notification body still opens the app and acknowledges the alarm.
        let stopAction = UNNotificationAction(
            identifier: stopActionIdentifier,
            title: String(localized: "stop_alarm"),
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [stopAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func cancelScheduledAlarms() async {
        try? await Self.registrationQueue.run {
            await removeAllPendingAlarmRequests()
            defaults.removeObject(forKey: Self.storedPlanKey)
            clearRearmFlag()
        }
    }

    /// True while this install is still relying on notification alarms. On iOS 26
    /// that means the user upgraded without rescheduling, so AlarmKit has not taken
    /// over yet and the alarm still cannot pierce silent mode.
    static var hasScheduledAlarmPlan: Bool {
        UserDefaults.standard.data(forKey: storedPlanKey) != nil
    }

    /// Drops every armed alarm notification and the bookkeeping behind it. Used when
    /// AlarmKit takes over on iOS 26, so an upgraded install cannot ring twice.
    static func cancelScheduledAlarms() async {
        await LocalNotificationScheduler().cancelScheduledAlarms()
    }

    func scheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        soundFileNameOverride: String?,
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws {
        let selectedWeekdays = weekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : weekdays
        let plan = StoredAlarmPlan(
            scheduledAt: Date(),
            ringDate: date,
            normalAlarmDate: normalAlarmDate,
            weekdays: selectedWeekdays,
            soundRawValue: sound.rawValue,
            soundFileNameOverride: soundFileNameOverride,
            followUpIntervalMinutes: snoozeMinutes ?? 0,
            title: title,
            body: body
        )

        try await Self.registrationQueue.run {
            // Re-registered while a morning the user already stopped would still be
            // following up (a refresh, a settings change, the calendar switched off):
            // that morning stays stopped.
            try await register(plan: plan, silencingRingsDueBy: acknowledgedAt())
            storePlan(plan)
        }
    }

    func scheduleCalendar(_ plan: CalendarAlarmPlan, sound: CommuteAlarmSettings.AlarmSound,
                          soundFileNameOverride: String?, snoozeMinutes: Int?, title: String, body: String) async throws {
        let stored = StoredAlarmPlan(scheduledAt: Date(), ringDate: plan.occurrences.first?.ringDate ?? plan.coveredUntil,
            normalAlarmDate: plan.occurrences.first?.normalDate ?? plan.coveredUntil,
            weekdays: [], soundRawValue: sound.rawValue, soundFileNameOverride: soundFileNameOverride,
            followUpIntervalMinutes: snoozeMinutes ?? 0, title: title, body: body, calendarPlan: plan)
        try await Self.registrationQueue.run {
            try await registerDated(plan: stored)
            storePlan(stored)
        }
    }

    /// Each date has stable request identifiers: replacing one is atomic in UN.
    /// Snapshot old requests for rollback if any add fails. Retire superseded
    /// requests first to avoid iOS silently dropping alarms over its 64 limit.
    private func registerDated(plan: StoredAlarmPlan) async throws {
        guard let dated = plan.calendarPlan else { return }
        let identifierPrefix = Self.identifierPrefix
        let previous = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: previous.map(\.identifier))
        var added: [String] = []
        do {
            for occurrence in dated.occurrences {
                var offsets = [0]
                if let interval = plan.followUpIntervalMinutes, interval > 0 { offsets.append(interval * 60) }
                for offset in offsets {
                    let fire = occurrence.ringDate.addingTimeInterval(Double(offset))
                    guard fire > Date() else { continue }
                    let id = "\(identifierPrefix)-date-\(AlarmCalendarSettings.key(for: occurrence.normalDate))-\(offset)"
                    let content = UNMutableNotificationContent()
                    content.title = plan.title; content.body = plan.body
                    let selectedSound = occurrence.resolvedSound(fallback: .init(
                        sound: CommuteAlarmSettings.AlarmSound(rawValue: plan.soundRawValue) ?? .rainyClock,
                        fileNameOverride: plan.soundFileNameOverride))
                    content.sound = Self.notificationSound(for: selectedSound); content.categoryIdentifier = Self.categoryIdentifier
                    content.userInfo = ["normalDay": AlarmCalendarSettings.key(for: occurrence.normalDate)]
                    let trigger = UNCalendarNotificationTrigger(dateMatching: AlarmCalendarSettings.calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: fire), repeats: false)
                    try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                    added.append(id)
                }
            }
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: added)
            for old in previous { try? await center.add(old) }
            throw error
        }
        let keep = Set(added)
        center.removePendingNotificationRequests(withIdentifiers: previous.map(\.identifier).filter { !keep.contains($0) })
        clearRearmFlag()
    }

    /// Silences the remainder of the ring session the tapped notification belongs to,
    /// while keeping the weekly schedule armed. The session is anchored to the
    /// notification's delivery time — the rings due by then — so tapping yesterday's stale
    /// banner cannot cancel an upcoming ring. That time is kept for later registrations.
    func acknowledgeAlarm(notificationDeliveredAt deliveredAt: Date) async {
        try? await Self.registrationQueue.run {
            let deliveredAlarmIdentifiers = await center.deliveredNotificationIdentifiers()
                .filter { $0.hasPrefix(Self.identifierPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: deliveredAlarmIdentifiers)

            guard let plan = loadPlan() else {
                await silenceLegacyRequests(deliveredAt: deliveredAt)
                return
            }

            // A notification delivered before the current plan existed still silences
            // only rings due by its delivery, so it cannot suppress a later ring the user
            // just scheduled — and a re-registration mid-chain cannot make Stop a no-op.
            if let dated = plan.calendarPlan {
                let interval = Double((plan.followUpIntervalMinutes ?? 0) * 60 + 60)
                if let occurrence = dated.occurrences.last(where: { $0.ringDate <= deliveredAt && deliveredAt < $0.ringDate.addingTimeInterval(interval) }) {
                    let prefix = "\(Self.identifierPrefix)-date-\(AlarmCalendarSettings.key(for: occurrence.normalDate))-"
                    let pending = await center.pendingNotificationRequests()
                    center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
                    // Switching back to the weekly alarm this morning must not bring
                    // its follow-ups back.
                    recordAcknowledgement(deliveredAt)
                }
                return
            }
            let window = Self.followUpWindow(for: plan)
            let windowEnd = deliveredAt.addingTimeInterval(window)
            guard windowEnd > Date() else {
                return
            }

            recordAcknowledgement(deliveredAt)
            try await register(plan: plan, silencingRingsDueBy: acknowledgedAt())
        }
    }

    /// Converts any fallback triggers left behind by acknowledgeAlarm back into
    /// precise weekly calendar triggers, once their silence window has passed.
    /// Called on app activation.
    func rearmAlarmsIfNeeded() async {
        try? await Self.registrationQueue.run {
            guard let rearmAfter = rearmAfterDate(),
                  Date() >= rearmAfter,
                  let plan = loadPlan() else {
                return
            }

            try await register(plan: plan, silencingRingsDueBy: acknowledgedAt())
        }
    }

    /// - Parameter acknowledged: when the last alarm the user stopped was delivered. A
    ///   ring due by then was answered, so its follow-ups still ahead are held back for
    ///   this week. A ring due later — the alarm moved past it — rings with its own. Only
    ///   a chain still running can match, so an old acknowledgement holds nothing back.
    private func register(plan: StoredAlarmPlan, silencingRingsDueBy acknowledged: Date?) async throws {
        let identifierPrefix = Self.identifierPrefix
        let previous = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(identifierPrefix) }
        await removeAllPendingAlarmRequests()
        do {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = Self.notificationSound(for: plan)
            content.categoryIdentifier = Self.categoryIdentifier

            // The ring date may sit on an earlier day than the normal alarm (rain lead time
            // crossing midnight), so every selected weekday shifts by the same day delta.
            let calendar = Calendar.current
            let dayShift = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: plan.normalAlarmDate),
                to: calendar.startOfDay(for: plan.ringDate)
            ).day ?? 0
            let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: plan.ringDate)
            let offsets = Self.ringOffsets(for: plan)
            var lastSilencedFireDate: Date?

            for weekday in plan.weekdays.sorted() {
                for offset in offsets {
                    let components = Self.normalizedComponents(
                        weekday: weekday,
                        dayShift: dayShift,
                        timeComponents: timeComponents,
                        offset: offset
                    )
                    let repeatingTrigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                    var trigger: UNNotificationTrigger = repeatingTrigger

                    if let acknowledged,
                       let nextFireDate = repeatingTrigger.nextTriggerDate(),
                       nextFireDate.addingTimeInterval(-Double(offset)) <= acknowledged {
                        // A follow-up of a ring already answered: re-registering this
                        // repeating trigger would ring again this morning. Fall back to a
                        // weekly time-interval trigger anchored at next week's occurrence —
                        // it keeps repeating (with minor drift) even if the app is never
                        // activated again, and rearmAlarmsIfNeeded restores the precise
                        // calendar version.
                        lastSilencedFireDate = max(lastSilencedFireDate ?? nextFireDate, nextFireDate)
                        guard let nextWeekFireDate = calendar.date(byAdding: .day, value: 7, to: nextFireDate),
                              nextWeekFireDate.timeIntervalSinceNow > 60 else {
                            continue
                        }
                        trigger = UNTimeIntervalNotificationTrigger(
                            timeInterval: nextWeekFireDate.timeIntervalSinceNow,
                            repeats: true
                        )
                    }

                    let request = UNNotificationRequest(
                        identifier: Self.alarmIdentifier(for: weekday, offset: offset),
                        content: content,
                        trigger: trigger
                    )
                    try await center.add(request)
                }
            }

            if let lastSilencedFireDate {
                setRearmFlag(after: lastSilencedFireDate.addingTimeInterval(60))
            } else {
                clearRearmFlag()
            }
        } catch {
            await removeAllPendingAlarmRequests()
            for request in previous { try? await center.add(request) }
            throw error
        }
    }

    /// Legacy installs (upgraded with pending requests from the old two-ring design but
    /// no stored plan): silence only the requests firing inside the old ring window and
    /// leave the rest of the weekly schedule untouched.
    private func silenceLegacyRequests(deliveredAt: Date) async {
        let windowEnd = deliveredAt.addingTimeInterval(120)
        guard windowEnd > Date() else {
            return
        }

        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
            .filter { request in
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let nextFireDate = trigger.nextTriggerDate() else {
                    return false
                }
                return nextFireDate < windowEnd
            }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// The main ring plus follow-ups at the user's snooze interval until acknowledged
    /// — this path cannot offer a real snooze button, so it re-rings on its own. iOS
    /// keeps at most 64 pending notification requests per app, so the follow-up count
    /// shrinks when many weekdays are selected (all 7 days -> 8 follow-ups instead of
    /// 10). With snooze off the alarm rings exactly once.
    private static func ringOffsets(for plan: StoredAlarmPlan) -> [Int] {
        let intervalMinutes = plan.followUpIntervalMinutes ?? legacyFollowUpIntervalMinutes
        guard intervalMinutes > 0 else {
            return [0]
        }

        let perWeekdayLimit = max(2, pendingNotificationLimit / max(1, plan.weekdays.count))
        let followUpCount = min(maximumFollowUpCount, perWeekdayLimit - 1)
        return [0] + (1...followUpCount).map { $0 * intervalMinutes * 60 }
    }

    /// How long after a weekly ring its follow-ups keep firing (plus a minute) — the same
    /// rule as `ringOffsets`, for callers that must not re-register the weekly plan while
    /// today's chain is still pending.
    static func weeklyFollowUpWindow(weekdayCount: Int, snoozeMinutes: Int?) -> TimeInterval {
        guard let interval = snoozeMinutes, interval > 0 else { return 60 }
        let perWeekdayLimit = max(2, pendingNotificationLimit / max(1, weekdayCount))
        return TimeInterval(min(maximumFollowUpCount, perWeekdayLimit - 1) * interval * 60 + 60)
    }

    private static func followUpWindow(for plan: StoredAlarmPlan) -> TimeInterval {
        TimeInterval((ringOffsets(for: plan).last ?? 0) + 60)
    }

    /// `UNNotificationSound(named:)` searches the container's `Library/Sounds` before
    /// the bundle, so a generated clip and a shipped tone are named the same way.
    /// A file longer than 30 seconds, or one that is not there, is swapped for the
    /// default tone silently — hence `GeneratedVoiceStore.assembledDuration` and the
    /// existence check behind `soundFileNameOverride`.
    private static func notificationSound(for plan: StoredAlarmPlan) -> UNNotificationSound {
        notificationSound(for: .init(sound: CommuteAlarmSettings.AlarmSound(rawValue: plan.soundRawValue) ?? .rainyClock,
                                      fileNameOverride: plan.soundFileNameOverride))
    }

    private static func notificationSound(for selection: AlarmSoundSelection) -> UNNotificationSound {
        if selection.sound == .systemDefault {
            return .default
        }

        let fileName = selection.fileNameOverride ?? selection.sound.fileName
        guard !fileName.isEmpty else {
            return UNNotificationSound(named: UNNotificationSoundName(CommuteAlarmSettings.AlarmSound.rainyClock.fileName))
        }
        return UNNotificationSound(named: UNNotificationSoundName(fileName))
    }

    private static func alarmIdentifier(for weekday: Int, offset: Int) -> String {
        "\(identifierPrefix)-\(weekday)-\(offset)"
    }

    private func removeAllPendingAlarmRequests() async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func normalizedComponents(
        weekday: Int,
        dayShift: Int,
        timeComponents: DateComponents,
        offset: Int
    ) -> DateComponents {
        let hour = timeComponents.hour ?? 0
        let minute = timeComponents.minute ?? 0
        let second = timeComponents.second ?? 0
        let secondsPerDay = 24 * 60 * 60
        let totalSeconds = hour * 60 * 60 + minute * 60 + second + offset
        let dayOffset = totalSeconds / secondsPerDay
        let secondsInDay = totalSeconds % secondsPerDay
        let normalizedWeekday = AlarmTimeCalculator.shiftedWeekday(weekday, byDays: dayShift + dayOffset)

        var components = DateComponents()
        components.weekday = normalizedWeekday
        components.hour = secondsInDay / 3_600
        components.minute = (secondsInDay % 3_600) / 60
        components.second = secondsInDay % 60
        return components
    }

    private struct StoredAlarmPlan: Codable, Sendable {
        var scheduledAt: Date
        var ringDate: Date
        var normalAlarmDate: Date
        var weekdays: Set<Int>
        var soundRawValue: String
        /// Absent in plans stored before generated voices existed, and for those the
        /// name still resolves from `soundRawValue`. Present, it wins — it is the
        /// only way to name a per-user clip.
        var soundFileNameOverride: String?
        /// Minutes between follow-up rings; `0` means the user turned snooze off.
        /// Absent in plans stored before 1.6.3, which used a fixed 5-minute interval.
        var followUpIntervalMinutes: Int?
        var title: String
        var body: String
        var calendarPlan: CalendarAlarmPlan?
    }

    private func storePlan(_ plan: StoredAlarmPlan) {
        guard let data = try? JSONEncoder().encode(plan) else {
            return
        }

        defaults.set(data, forKey: Self.storedPlanKey)
    }

    private func loadPlan() -> StoredAlarmPlan? {
        guard let data = defaults.data(forKey: Self.storedPlanKey) else {
            return nil
        }

        return try? JSONDecoder().decode(StoredAlarmPlan.self, from: data)
    }

    private func setRearmFlag(after date: Date) {
        defaults.set(date, forKey: Self.rearmAfterKey)
    }

    private func clearRearmFlag() {
        defaults.removeObject(forKey: Self.rearmAfterKey)
    }

    private func rearmAfterDate() -> Date? {
        defaults.object(forKey: Self.rearmAfterKey) as? Date
    }

    /// Kept through re-registrations, a switch to the dated plan and turning the alarm
    /// off and on: it only ever matches a chain that is still running.
    private func recordAcknowledgement(_ deliveredAt: Date) {
        defaults.set(max(acknowledgedAt() ?? deliveredAt, deliveredAt), forKey: Self.acknowledgedAtKey)
    }

    private func acknowledgedAt() -> Date? {
        defaults.object(forKey: Self.acknowledgedAtKey) as? Date
    }
}

final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static let shared = NotificationPresentationDelegate()
    private let logger = Logger(subsystem: "com.shukaihu.RainyClock", category: "Notifications")

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        logger.info("Received notification response action=\(response.actionIdentifier, privacy: .public) request=\(response.notification.request.identifier, privacy: .public)")

        Self.handleResponse(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            deliveredAt: response.notification.date,
            completion: completionHandler
        )
    }

    /// UIKit restores the scene when this completion runs. The synthesized
    /// Objective-C completion for an async delegate method can run on a worker
    /// thread (build 34's TestFlight crash), so finish explicitly on MainActor.
    /// Copy only value types from UNNotificationResponse across the task boundary.
    static func handleResponse(
        actionIdentifier: String,
        categoryIdentifier: String,
        deliveredAt: Date,
        acknowledge: @escaping @MainActor (Date) async -> Void = {
            await LocalNotificationScheduler().acknowledgeAlarm(notificationDeliveredAt: $0)
        },
        completion: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            if categoryIdentifier == LocalNotificationScheduler.categoryIdentifier,
               actionIdentifier == UNNotificationDefaultActionIdentifier ||
               actionIdentifier == LocalNotificationScheduler.stopActionIdentifier {
                // Silence this ring session while keeping the weekly schedule.
                await acknowledge(deliveredAt)
            }
            // Unknown actions and non-alarm notifications must also finish once.
            completion()
        }
    }
}
