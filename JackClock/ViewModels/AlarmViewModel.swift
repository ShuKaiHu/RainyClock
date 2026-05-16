import Foundation

@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var settings = CommuteAlarmSettings()
    @Published private(set) var routeWeatherSnapshot: RouteWeatherSnapshot?
    @Published private(set) var scheduledAlarmSummary: ScheduledAlarmSummary?
    @Published private(set) var statusMessage = "Enter your commute and alarm settings."
    @Published private(set) var isScheduling = false

    private let routeWeatherService: RouteWeatherService
    private let notificationScheduler: NotificationScheduling

    init(
        routeWeatherService: RouteWeatherService = MockRouteWeatherService(),
        notificationScheduler: NotificationScheduling = LocalNotificationScheduler()
    ) {
        self.routeWeatherService = routeWeatherService
        self.notificationScheduler = notificationScheduler
    }

    var canSchedule: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settings.rainLeadTimeMinutes > 0
    }

    func evaluateRouteAndScheduleAlarm() async {
        guard canSchedule else {
            statusMessage = "Home, work, and lead time are required."
            return
        }

        isScheduling = true
        defer { isScheduling = false }

        do {
            let authorized = try await notificationScheduler.requestAuthorization()
            guard authorized else {
                statusMessage = "Notification permission was not granted."
                return
            }

            let snapshot = try await routeWeatherService.fetchRouteWeather(
                from: settings.homeAddress,
                to: settings.workAddress,
                around: settings.alarmTime
            )
            routeWeatherSnapshot = snapshot

            let summary = AlarmTimeCalculator.nextAlarmDate(
                alarmTime: settings.alarmTime,
                leadTimeMinutes: settings.rainLeadTimeMinutes,
                shouldApplyLeadTime: snapshot.hasRain
            )
            scheduledAlarmSummary = summary

            let body = snapshot.hasRain
                ? "Rain is expected on your route, so the alarm was moved earlier."
                : "No rain detected on your route, so the normal alarm time was used."

            try await notificationScheduler.scheduleAlarm(
                at: summary.scheduledAlarmDate,
                title: "Jack Clock",
                body: body
            )

            statusMessage = snapshot.hasRain ? "Rain detected. Alarm adjusted." : "No rain detected. Alarm scheduled."
        } catch {
            statusMessage = "Could not schedule alarm: \(error.localizedDescription)"
        }
    }
}
