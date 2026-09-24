import SwiftUI
import UserNotifications

@main
struct RainyClockApp: App {
    @UIApplicationDelegateAdaptor(DisasterPushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-weather-scene-preview") { return }
        #endif
        #if DEBUG
        if TomorrowWidgetDemo.isActive { return }
        if AppEnvironment.supportsTemporaryClosures && ProcessInfo.processInfo.arguments.contains("-disaster-map-preview") { return }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationPresentationDelegate.shared
        LocalNotificationScheduler.registerNotificationCategories()
        // Has to happen before launch finishes, or the system refuses the handlers.
        BackgroundWeatherRefresh.registerHandlers()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-weather-scene-preview") {
                CommuteWeatherPreviewHost()
            } else { standardContent }
            #else
            standardContent
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-weather-scene-preview") { return }
            #endif
            handleScenePhase(newPhase)
        }
    }

    @ViewBuilder private var standardContent: some View {
        #if DEBUG
        if TomorrowWidgetDemo.isActive {
            TomorrowWidgetDemoHost()
        } else if AppEnvironment.supportsTemporaryClosures && ProcessInfo.processInfo.arguments.contains("-disaster-map-preview") {
            DisasterMapPreviewHost()
        } else { mainContent }
        #else
        mainContent
        #endif
    }

    private func handleScenePhase(_ newPhase: ScenePhase) {
        #if DEBUG
        if TomorrowWidgetDemo.isActive { return }
        if AppEnvironment.supportsTemporaryClosures && ProcessInfo.processInfo.arguments.contains("-disaster-map-preview") { return }
        #endif
        // The widget's snapshot must be current when the app leaves the screen:
        // the debounce would not fire once suspended.
        if newPhase == .background {
            TomorrowWidgetPublisher.shared.publish()
        }
        guard newPhase == .active else {
            return
        }

        // A widget showing "open the app to refresh" must update even when no
        // model property changes on return from suspension — and even when the
        // snapshot itself is unchanged (a time zone or clock change undone), so
        // reload regardless; a foreground app's reloads are not budgeted.
        TomorrowWidgetPublisher.shared.publish(forceReload: true)

        // Runs on every system, not just pre-26: an install that upgraded to
        // iOS 26 before rescheduling still carries notification alarms, and
        // skipping this would strand any that are sitting on a fallback
        // trigger. Once AlarmKit takes over there is no stored plan left and
        // this is a no-op.
        Task {
            await LocalNotificationScheduler().rearmAlarmsIfNeeded()
        }
    }

    private var mainContent: some View {
        ContentView(viewModel: CommuteAlarmRefresher.currentModel(), showsWeatherAttribution: AppEnvironment.showsWeatherAttribution)
    }
}

#if DEBUG
/// Isolated visual QA: does not register notifications, load ads, or write the
/// user's real settings. Synthetic announcements stay inside the map screen.
private struct DisasterMapPreviewHost: View {
    @StateObject private var model = AlarmViewModel(settingsStorage: UserDefaults(suiteName: "DisasterMapVisualPreview")!)
    private var county: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-disaster-map-county"), index + 1 < args.count,
              DisasterRegion.counties.contains(args[index + 1]) else { return nil }
        return args[index + 1]
    }
    var body: some View {
        NavigationStack {
            DisasterMapView(viewModel: model, isDemo: true, initialCounty: county)
        }.preferredColorScheme(.dark)
    }
}
#endif
