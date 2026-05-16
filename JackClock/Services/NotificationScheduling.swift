import Foundation
import UserNotifications

protocol NotificationScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func scheduleAlarm(at date: Date, title: String, body: String) async throws
}

struct LocalNotificationScheduler: NotificationScheduling {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func scheduleAlarm(at date: Date, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "commute-rain-alarm", content: content, trigger: trigger)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.identifier])
        try await UNUserNotificationCenter.current().add(request)
    }
}
