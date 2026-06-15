import SwiftUI
import UserNotifications

@main
struct RainyClockApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: AlarmViewModel(routeWeatherService: AppEnvironment.routeWeatherService),
                showsWeatherAttribution: AppEnvironment.usesWeatherKit
            )
        }
    }
}
