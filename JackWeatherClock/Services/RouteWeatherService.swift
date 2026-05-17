import Foundation

protocol RouteWeatherService: Sendable {
    func fetchRouteWeather(
        from homeAddress: String,
        to workAddress: String,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> RouteWeatherSnapshot
}

struct MockRouteWeatherService: RouteWeatherService {
    func fetchRouteWeather(
        from homeAddress: String,
        to workAddress: String,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> RouteWeatherSnapshot {
        try await Task.sleep(for: .milliseconds(350))

        let rainyInput = "\(homeAddress) \(workAddress)".localizedCaseInsensitiveContains("rain")
            || homeAddress.contains("雨")
            || workAddress.contains("雨")

        let routeName = String.localizedStringWithFormat(String(localized: "segment_route_format"), mode.displayName)
        let segments = rainyInput
            ? [
                RouteWeatherSegment(name: String(localized: "segment_home_area"), condition: .cloudy, precipitationProbability: 0.25),
                RouteWeatherSegment(name: routeName, condition: .rain, precipitationProbability: 0.72),
                RouteWeatherSegment(name: String(localized: "segment_office_area"), condition: .cloudy, precipitationProbability: 0.35)
            ]
            : [
                RouteWeatherSegment(name: String(localized: "segment_home_area"), condition: .clear, precipitationProbability: 0.08),
                RouteWeatherSegment(name: routeName, condition: .cloudy, precipitationProbability: 0.18),
                RouteWeatherSegment(name: String(localized: "segment_office_area"), condition: .clear, precipitationProbability: 0.05)
            ]

        return RouteWeatherSnapshot(checkedAt: Date(), segments: segments)
    }
}
