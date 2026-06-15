import CoreLocation
import Foundation
import WeatherKit

struct WeatherKitSamplingService: WeatherSamplingService {
    private let service: WeatherService

    init(service: WeatherService = .shared) {
        self.service = service
    }

    func sampleWeather(
        at coordinate: CLLocationCoordinate2D,
        around date: Date
    ) async throws -> WeatherSample {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let weather = try await service.weather(for: location)
        let hourWeather = nearestHour(in: weather.hourlyForecast, to: date)
        let precipitationProbability = hourWeather?.precipitationChance ?? 0
        let condition = WeatherSampleMapper.condition(
            for: hourWeather?.condition ?? weather.currentWeather.condition,
            precipitationProbability: precipitationProbability
        )

        return WeatherSample(
            condition: condition,
            precipitationProbability: precipitationProbability
        )
    }

    private func nearestHour(in forecast: Forecast<HourWeather>, to date: Date) -> HourWeather? {
        forecast.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
    }
}
