import Foundation

@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var settings: CommuteAlarmSettings {
        didSet {
            saveSettings()
        }
    }
    @Published private(set) var routeWeatherSnapshot: RouteWeatherSnapshot?
    @Published private(set) var scheduledAlarmSummary: ScheduledAlarmSummary?
    @Published private(set) var statusMessage = String(localized: "status_enter_settings")
    @Published private(set) var isScheduling = false

    private let routeWeatherService: RouteWeatherService
    private let notificationScheduler: NotificationScheduling
    private let settingsStorage: UserDefaults
    private static let settingsStorageKey = "commuteAlarmSettings"

    init(
        routeWeatherService: RouteWeatherService = MockRouteWeatherService(),
        notificationScheduler: NotificationScheduling = LocalNotificationScheduler(),
        settingsStorage: UserDefaults = .standard
    ) {
        self.settings = Self.loadSettings(from: settingsStorage) ?? CommuteAlarmSettings()
        self.routeWeatherService = routeWeatherService
        self.notificationScheduler = notificationScheduler
        self.settingsStorage = settingsStorage
    }

    var canSchedule: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settings.rainLeadTimeMinutes > 0
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
                maximumPrecipitationProbability: snapshot.maximumPrecipitationProbability
            )
            scheduledAlarmSummary = summary

            let body = exceedsThreshold
                ? String(localized: "notification_body_adjusted")
                : String(localized: "notification_body_normal")

            try await notificationScheduler.scheduleAlarm(
                at: summary.scheduledAlarmDate,
                title: String(localized: "notification_title"),
                body: body
            )

            statusMessage = exceedsThreshold ? String(localized: "status_adjusted") : String(localized: "status_normal")
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
