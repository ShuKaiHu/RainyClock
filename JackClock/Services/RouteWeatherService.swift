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

        let segments = rainyInput
            ? [
                RouteWeatherSegment(name: "Home area", condition: .cloudy, precipitationProbability: 0.25),
                RouteWeatherSegment(name: "Driving route", condition: .rain, precipitationProbability: 0.72),
                RouteWeatherSegment(name: "Office area", condition: .cloudy, precipitationProbability: 0.35)
            ]
            : [
                RouteWeatherSegment(name: "Home area", condition: .clear, precipitationProbability: 0.08),
                RouteWeatherSegment(name: "Driving route", condition: .cloudy, precipitationProbability: 0.18),
                RouteWeatherSegment(name: "Office area", condition: .clear, precipitationProbability: 0.05)
            ]

        return RouteWeatherSnapshot(checkedAt: Date(), segments: segments)
    }
}
