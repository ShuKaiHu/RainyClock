import Foundation
import UserNotifications

/// One "tomorrow morning" notification, planned for 9 p.m. the evening before a
/// selected weekday's alarm.
///
/// Two kinds, because only one occurrence has a decision behind it. The armed
/// alarm was decided against the forecast for its *next* ring, so that ring's
/// preview can say what will happen and when the forecast was checked. Every
/// later selected weekday is re-decided by the background refresh on its own
/// morning, so its preview can only say that an alarm exists and what decides
/// it. Both are replaced whenever the alarm is re-registered — a foreground
/// open, a background refresh — so the text is as current as the alarm itself.
struct EveningPreview: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The armed decision for this ring: whether rain moved it, from when to
        /// when, and when the forecast behind it was fetched.
        case decision(rain: Bool, normalAlarmDate: Date, scheduledAlarmDate: Date, leadTimeMinutes: Int, checkedAt: Date)
        /// A later selected weekday; the morning's refresh will decide it.
        case upcoming(normalAlarmDate: Date)
    }

    let identifier: String
    let fireDate: Date
    let kind: Kind
    /// Whether a background refresh can run on this phone at all. When it
    /// cannot — Background App Refresh off, or Low Power Mode — the preview
    /// says so, because then nothing but opening the app brings the decision
    /// up to date. This is the only place the app tells those users.
    let canRefreshInBackground: Bool
}

enum EveningPreviewPlanner {
    /// Nine in the evening, local time. Fixed rather than relative to the alarm:
    /// "the night before" is when people decide about tomorrow, and it lands
    /// before the overnight background window opens (nine hours before the
    /// lead-time point), so a refresh that does run replaces this with fresher
    /// text rather than racing it.
    static let previewHour = 21
    /// A week of previews at most, one per selected weekday. The notification
    /// alarms on iOS 17–25 share the 64-request budget with these — see
    /// `LocalNotificationScheduler.pendingNotificationLimit`.
    static let horizonDays = 7
    static let identifierPrefix = "commute-rain-preview"

    static func plan(
        summary: ScheduledAlarmSummary,
        selectedWeekdays: Set<Int>,
        checkedAt: Date,
        now: Date,
        canRefreshInBackground: Bool,
        calendar: Calendar = .current
    ) -> [EveningPreview] {
        let weekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        let time = calendar.dateComponents([.hour, .minute], from: summary.normalAlarmDate)
        let todayStart = calendar.startOfDay(for: now)
        var previews: [EveningPreview] = []

        for dayOffset in 0...horizonDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: todayStart),
                  let alarm = calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: day),
                  alarm > now,
                  weekdays.contains(calendar.component(.weekday, from: alarm)),
                  let eve = calendar.date(byAdding: .day, value: -1, to: alarm),
                  let fireDate = calendar.date(bySettingHour: previewHour, minute: 0, second: 0, of: eve),
                  // An evening already gone gets nothing: the person is either in
                  // the app right now or past the point a preview helps.
                  fireDate > now.addingTimeInterval(60) else {
                continue
            }

            let isArmedRing = calendar.isDate(alarm, equalTo: summary.normalAlarmDate, toGranularity: .minute)
            let kind: EveningPreview.Kind = isArmedRing
                ? .decision(
                    rain: summary.exceedsRainThreshold,
                    normalAlarmDate: summary.normalAlarmDate,
                    scheduledAlarmDate: summary.scheduledAlarmDate,
                    leadTimeMinutes: summary.leadTimeMinutes,
                    checkedAt: checkedAt
                )
                : .upcoming(normalAlarmDate: alarm)

            previews.append(EveningPreview(
                identifier: identifier(forAlarmOn: alarm, calendar: calendar),
                fireDate: fireDate,
                kind: kind,
                canRefreshInBackground: canRefreshInBackground
            ))
        }

        return previews
    }

    /// One identifier per alarm day, so re-planning replaces rather than
    /// duplicates, and a cancelled day's request is addressable.
    static func identifier(forAlarmOn date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@-%04d%02d%02d", identifierPrefix, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The words, kept apart from the planning so the planner can be tested
/// without a locale and the copy can change without touching the dates.
enum EveningPreviewText {
    static var title: String {
        String(localized: "evening_preview_title")
    }

    static func body(for preview: EveningPreview) -> String {
        switch preview.kind {
        case let .decision(rain, normalAlarmDate, scheduledAlarmDate, leadTimeMinutes, checkedAt):
            let decision = rain
                ? String.localizedStringWithFormat(
                    String(localized: "evening_preview_rain"),
                    time(normalAlarmDate),
                    time(scheduledAlarmDate),
                    leadTimeMinutes,
                    checkedAt.formatted(date: .abbreviated, time: .shortened)
                )
                : String.localizedStringWithFormat(
                    String(localized: "evening_preview_clear"),
                    time(normalAlarmDate),
                    checkedAt.formatted(date: .abbreviated, time: .shortened)
                )
            return preview.canRefreshInBackground
                ? decision
                : decision + " " + String(localized: "evening_preview_no_background")

        case let .upcoming(normalAlarmDate):
            let key = preview.canRefreshInBackground
                ? "evening_preview_upcoming"
                : "evening_preview_upcoming_no_background"
            return String.localizedStringWithFormat(
                String(localized: String.LocalizationValue(key)),
                time(normalAlarmDate)
            )
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

enum EveningPreviewAuthorization: Sendable {
    case notDetermined
    case authorized
    case denied
}

/// Where the previews go. A protocol so the view model's tests can run the
/// scheduling flow without a notification centre behind it.
protocol EveningPreviewScheduling: Sendable {
    func authorizationStatus() async -> EveningPreviewAuthorization
    /// Shows the system prompt. Only meaningful while the app is in the
    /// foreground; an unattended run checks `authorizationStatus()` instead.
    func requestAuthorization() async -> Bool
    /// Drops every pending preview and registers these instead.
    func replacePreviews(_ previews: [EveningPreview]) async
    func cancelPreviews() async
}

/// Local notifications, one calendar trigger per preview. Separate from the
/// alarm notifications on purpose: those carry the alarm category and its Stop
/// action and are silenced as a session when tapped; a preview is plain
/// information and tapping it just opens the app.
///
/// On iOS 26 the alarm itself is AlarmKit, whose permission is not notification
/// permission, so this is the first thing in the app that asks for the latter
/// there. On iOS 17–25 the alarm already asked, and the answer covers both.
struct UserNotificationEveningPreviewScheduler: EveningPreviewScheduling {
    func authorizationStatus() async -> EveningPreviewAuthorization {
        guard !AppEnvironment.isRunningTests else {
            return .denied
        }

        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        guard !AppEnvironment.isRunningTests else {
            return false
        }

        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func replacePreviews(_ previews: [EveningPreview]) async {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        let center = UNUserNotificationCenter.current()
        await Self.removePending(center: center)

        let calendar = Calendar.current
        for preview in previews {
            let content = UNMutableNotificationContent()
            content.title = EveningPreviewText.title
            content.body = EveningPreviewText.body(for: preview)
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: preview.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: preview.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    func cancelPreviews() async {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        await Self.removePending(center: UNUserNotificationCenter.current())
    }

    private static func removePending(center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(EveningPreviewPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
