import Foundation

@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var settings: CommuteAlarmSettings {
        didSet {
            saveSettings()
        }
    }
    @Published private(set) var routeWeatherSnapshot: RouteWeatherSnapshot?
    @Published private(set) var routePreview: RoutePreview?
    @Published private(set) var scheduledAlarmSummary: ScheduledAlarmSummary?
    @Published private(set) var statusMessage = String(localized: "status_enter_settings")
    @Published private(set) var routePreviewStatusMessage = String(localized: "route_preview_empty")
    @Published private(set) var routeWeatherStatusMessage = String(localized: "route_weather_empty")
    @Published private(set) var isScheduling = false
    @Published private(set) var isPreviewingRoute = false
    @Published private(set) var isRefreshingRouteWeather = false

    private let routeWeatherService: RouteWeatherService
    private let routePreviewService: RoutePreviewService
    private let notificationScheduler: NotificationScheduling
    private let settingsStorage: UserDefaults
    private static let settingsStorageKey = "commuteAlarmSettings"

    init(
        routeWeatherService: RouteWeatherService = MockRouteWeatherService(),
        routePreviewService: RoutePreviewService = MapKitRoutePreviewService(),
        notificationScheduler: NotificationScheduling = LocalNotificationScheduler(),
        settingsStorage: UserDefaults = .standard
    ) {
        self.settings = Self.loadSettings(from: settingsStorage) ?? CommuteAlarmSettings()
        self.routeWeatherService = routeWeatherService
        self.routePreviewService = routePreviewService
        self.notificationScheduler = notificationScheduler
        self.settingsStorage = settingsStorage
    }

    var canSchedule: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.selectedWeekdays.isEmpty
            && settings.rainLeadTimeMinutes > 0
    }

    var canPreviewRoute: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func previewRoute() async {
        guard canPreviewRoute else {
            clearRoutePreview(message: String(localized: "route_preview_required"))
            return
        }

        isPreviewingRoute = true
        routePreviewStatusMessage = String(localized: "previewing_route")
        defer { isPreviewingRoute = false }

        do {
            let preview = try await routePreviewService.previewRoute(
                from: settings.homeAddress,
                to: settings.workAddress,
                mode: settings.commuteMode
            )
            routePreview = preview
            routePreviewStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_preview_ready"),
                preview.routeName,
                preview.expectedTravelTimeMinutes,
                preview.distanceKilometers
            )
        } catch {
            routePreview = nil
            routePreviewStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_preview_failed"),
                error.localizedDescription
            )
        }
    }

    func clearRoutePreview(message: String = String(localized: "route_preview_empty")) {
        routePreview = nil
        routePreviewStatusMessage = message
    }

    func refreshRouteWeather() async {
        guard canPreviewRoute else {
            clearRouteWeather(message: String(localized: "route_weather_empty"))
            return
        }

        isRefreshingRouteWeather = true
        routeWeatherStatusMessage = String(localized: "route_weather_refreshing")
        defer { isRefreshingRouteWeather = false }

        do {
            let snapshot = try await routeWeatherService.fetchRouteWeather(
                from: settings.homeAddress,
                to: settings.workAddress,
                mode: settings.commuteMode,
                around: settings.alarmTime
            )
            routeWeatherSnapshot = snapshot
            routeWeatherStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_weather_updated"),
                snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
            )
        } catch {
            routeWeatherSnapshot = nil
            routeWeatherStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_weather_failed"),
                error.localizedDescription
            )
        }
    }

    func clearRouteWeather(message: String = String(localized: "route_weather_empty")) {
        routeWeatherSnapshot = nil
        routeWeatherStatusMessage = message
    }

    func evaluateRouteAndScheduleAlarm() async {
        guard canSchedule else {
            statusMessage = String(localized: "status_required")
            return
        }

        isScheduling = true
        defer { isScheduling = false }

        do {
            let authorized = try await notificationScheduler.requestAuthorization()
            guard authorized else {
                statusMessage = String(localized: "status_permission_denied")
                return
            }

            let snapshot = try await routeWeatherService.fetchRouteWeather(
                from: settings.homeAddress,
                to: settings.workAddress,
                mode: settings.commuteMode,
                around: settings.alarmTime
            )
            routeWeatherSnapshot = snapshot

            let exceedsThreshold = snapshot.exceedsRainThreshold(settings.rainProbabilityThreshold)
            let summary = AlarmTimeCalculator.nextAlarmDate(
                alarmTime: settings.alarmTime,
                leadTimeMinutes: settings.rainLeadTimeMinutes,
                shouldApplyLeadTime: exceedsThreshold,
                rainProbabilityThreshold: settings.rainProbabilityThreshold,
                maximumPrecipitationProbability: snapshot.maximumPrecipitationProbability,
                selectedWeekdays: settings.selectedWeekdays
            )
            scheduledAlarmSummary = summary

            let body = exceedsThreshold
                ? String(localized: "notification_body_adjusted")
                : String(localized: "notification_body_normal")

            try await notificationScheduler.scheduleAlarm(
                at: summary.scheduledAlarmDate,
                weekdays: settings.selectedWeekdays,
                sound: settings.alarmSound,
                title: String(localized: "notification_title"),
                body: body
            )

            let checkedAt = snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
            let statusKey = exceedsThreshold ? "status_adjusted_checked" : "status_normal_checked"
            statusMessage = String.localizedStringWithFormat(String(localized: String.LocalizationValue(statusKey)), checkedAt)
        } catch {
            statusMessage = String.localizedStringWithFormat(String(localized: "status_schedule_failed"), error.localizedDescription)
        }
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        settingsStorage.set(data, forKey: Self.settingsStorageKey)
    }

    private static func loadSettings(from storage: UserDefaults) -> CommuteAlarmSettings? {
        guard let data = storage.data(forKey: settingsStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(CommuteAlarmSettings.self, from: data)
    }
}
