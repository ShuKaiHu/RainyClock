import Foundation
import UserNotifications

protocol NotificationScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func scheduleAlarm(
        at date: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        title: String,
        body: String
    ) async throws
}

struct LocalNotificationScheduler: NotificationScheduling {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func scheduleAlarm(
        at date: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        title: String,
        body: String
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound(for: sound)

        let identifiers = ["commute-rain-alarm"] + alarmIdentifiers(for: CommuteAlarmSettings.allWeekdays)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)

        let selectedWeekdays = weekdays.isEmpty ? CommuteAlarmSettings.allWeekdays : weekdays
        let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: date)

        for weekday in selectedWeekdays.sorted() {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = timeComponents.hour
            components.minute = timeComponents.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: alarmIdentifier(for: weekday),
                content: content,
                trigger: trigger
            )
            try await UNUserNotificationCenter.current().add(request)
        }
    }

    private func notificationSound(for sound: CommuteAlarmSettings.AlarmSound) -> UNNotificationSound {
        switch sound {
        case .rainyClock, .morningBell, .softPiano:
            UNNotificationSound(named: UNNotificationSoundName(sound.fileName))
        case .systemDefault:
            .default
        }
    }

    private func alarmIdentifiers(for weekdays: Set<Int>) -> [String] {
        weekdays.map(alarmIdentifier(for:))
    }

    private func alarmIdentifier(for weekday: Int) -> String {
        "commute-rain-alarm-\(weekday)"
    }
}

final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static let shared = NotificationPresentationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
