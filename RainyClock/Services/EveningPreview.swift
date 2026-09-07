import Foundation
import UserNotifications

/// One "tomorrow morning" notification, planned for the evening before a
/// selected weekday's alarm at a time the person chose (21:00 by default).
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
        /// when, the reading that decided it (where on the route, how likely,
        /// against what threshold), and when the forecast behind it was fetched.
        case decision(
            rain: Bool,
            normalAlarmDate: Date,
            scheduledAlarmDate: Date,
            leadTimeMinutes: Int,
            maximumProbability: Double,
            threshold: Double,
            place: String?,
            checkedAt: Date
        )
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

/// A ring the evening preview announced that a later unattended run moved.
///
/// The preview said 07:00 because the evening forecast said rain; the morning
/// forecast said otherwise, the alarm went back to 07:30, and nobody would
/// know why they were allowed to sleep on unless something said so. This is
/// that something. Silent by design: it lands minutes before an alarm.
struct AlarmDecisionChange: Equatable, Sendable {
    let normalAlarmDate: Date
    let previousRingDate: Date
    let newRingDate: Date
    let maximumProbability: Double
    let threshold: Double
    let place: String?

    var movedLater: Bool { newRingDate > previousRingDate }

    var minutesMoved: Int {
        Int((abs(newRingDate.timeIntervalSince(previousRingDate)) / 60).rounded())
    }
}

enum EveningPreviewPlanner {
    static let changeIdentifier = "commute-rain-change"

    /// The sample the "preview notification" button sends, so the person can
    /// see the shape of the thing before the first real evening. Uses the
    /// prefix so a re-plan sweeps it up if it has not fired yet.
    static let sampleIdentifier = "\(identifierPrefix)-sample"
    static let sampleDelay: TimeInterval = 3
    /// A week of previews at most, one per selected weekday. The notification
    /// alarms on iOS 17–25 share the 64-request budget with these — see
    /// `LocalNotificationScheduler.pendingNotificationLimit`.
    static let horizonDays = 7
    static let identifierPrefix = "commute-rain-preview"

    /// - Parameter previewTime: only its hour and minute are read; the preview
    ///   fires at that time on the calendar day before each alarm.
    static func plan(
        summary: ScheduledAlarmSummary,
        selectedWeekdays: Set<Int>,
        previewTime: Date,
        checkedAt: Date,
        now: Date,
        canRefreshInBackground: Bool,
        calendar: Calendar = .current
    ) -> [EveningPreview] {
        let weekdays = selectedWeekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : selectedWeekdays
        let time = calendar.dateComponents([.hour, .minute], from: summary.normalAlarmDate)
        let preview = calendar.dateComponents([.hour, .minute], from: previewTime)
        let todayStart = calendar.startOfDay(for: now)
        var previews: [EveningPreview] = []

        for dayOffset in 0...horizonDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: todayStart),
                  let alarm = calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: day),
                  alarm > now,
                  weekdays.contains(calendar.component(.weekday, from: alarm)),
                  let eve = calendar.date(byAdding: .day, value: -1, to: alarm),
                  let fireDate = calendar.date(bySettingHour: preview.hour ?? 21, minute: preview.minute ?? 0, second: 0, of: eve),
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
                    maximumProbability: summary.maximumPrecipitationProbability,
                    threshold: summary.rainProbabilityThreshold,
                    place: summary.wettestSegmentName,
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

    /// A rainy-morning sample built from the settings alone, for the button.
    /// It says "rain" because that is the variant worth seeing — the dry one is
    /// a shorter sentence with the same shape. `checkedAt` is now, and the
    /// background-refresh sentence follows the phone's real state, so the
    /// sample is also the first time that sentence can be seen.
    static func sample(
        settings: CommuteAlarmSettings,
        now: Date,
        canRefreshInBackground: Bool,
        calendar: Calendar = .current
    ) -> EveningPreview {
        let summary = AlarmTimeCalculator.nextAlarmDateForWeatherCheck(
            alarmTime: settings.alarmTime,
            leadTimeMinutes: settings.rainLeadTimeMinutes,
            shouldApplyLeadTime: true,
            rainProbabilityThreshold: settings.rainProbabilityThreshold,
            maximumPrecipitationProbability: 0.8,
            selectedWeekdays: settings.selectedWeekdays,
            now: now,
            calendar: calendar
        )
        return EveningPreview(
            identifier: sampleIdentifier,
            fireDate: now.addingTimeInterval(sampleDelay),
            kind: .decision(
                rain: true,
                normalAlarmDate: summary.normalAlarmDate,
                scheduledAlarmDate: summary.scheduledAlarmDate,
                leadTimeMinutes: summary.leadTimeMinutes,
                maximumProbability: 0.8,
                threshold: settings.rainProbabilityThreshold,
                place: String(localized: "segment_home_area"),
                checkedAt: now
            ),
            canRefreshInBackground: canRefreshInBackground
        )
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
        case let .decision(rain, normalAlarmDate, scheduledAlarmDate, leadTimeMinutes, maximumProbability, threshold, place, checkedAt):
            let where_ = place ?? String(localized: "evening_preview_route")
            let decision = rain
                ? String.localizedStringWithFormat(
                    String(localized: "evening_preview_rain"),
                    where_,
                    percent(maximumProbability),
                    percent(threshold),
                    time(normalAlarmDate),
                    time(scheduledAlarmDate),
                    leadTimeMinutes,
                    checked(checkedAt)
                )
                : String.localizedStringWithFormat(
                    String(localized: "evening_preview_clear"),
                    where_,
                    percent(maximumProbability),
                    percent(threshold),
                    time(normalAlarmDate),
                    checked(checkedAt)
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

    /// 24-hour, zero-padded, no day-period word: "07:30", not "清晨7:30". The
    /// user's call — the period word is noise once the hour is unambiguous.
    static var changeTitle: String {
        String(localized: "alarm_change_title")
    }

    static func changeBody(for change: AlarmDecisionChange) -> String {
        let where_ = change.place ?? String(localized: "evening_preview_route")
        return String.localizedStringWithFormat(
            String(localized: change.movedLater ? "alarm_change_later" : "alarm_change_earlier"),
            where_,
            percent(change.maximumProbability),
            percent(change.threshold),
            time(change.newRingDate),
            change.minutesMoved
        )
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func percent(_ probability: Double) -> Int {
        Int((probability * 100).rounded())
    }

    /// Weekday and time, no year: the check is always within the week, and
    /// "2026年9月7日 晚上7:58" in a two-line banner spent most of it on the year.
    private static func checked(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
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
    /// Delivers one preview a few seconds from now, leaving the planned ones
    /// alone. The "preview notification" button.
    func showSample(_ preview: EveningPreview) async
    /// Tells the person, without a sound, that a ring the preview announced has
    /// moved. Sent by unattended runs only.
    func notifyDecisionChange(_ change: AlarmDecisionChange) async
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

    func showSample(_ preview: EveningPreview) async {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = EveningPreviewText.title
        content.body = EveningPreviewText.body(for: preview)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, preview.fireDate.timeIntervalSinceNow),
            repeats: false
        )
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: preview.identifier, content: content, trigger: trigger)
        )
    }

    func notifyDecisionChange(_ change: AlarmDecisionChange) async {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = EveningPreviewText.changeTitle
        content.body = EveningPreviewText.changeBody(for: change)
        // No sound: this arrives in the small hours before an alarm, and a
        // sound would defeat the extra sleep it is announcing.
        content.sound = nil
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: EveningPreviewPlanner.changeIdentifier, content: content, trigger: nil)
        )
    }

    private static func removePending(center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(EveningPreviewPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
