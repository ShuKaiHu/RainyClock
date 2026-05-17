import SwiftUI
import UserNotifications

@main
struct JackWeatherClockApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: AlarmViewModel())
        }
    }
}
