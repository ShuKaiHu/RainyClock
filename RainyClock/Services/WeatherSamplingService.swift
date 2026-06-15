import CoreLocation
import Foundation
import WeatherKit

protocol WeatherSamplingService: Sendable {
    func sampleWeather(
        at coordinate: CLLocationCoordinate2D,
        around date: Date
    ) async throws -> WeatherSample
}

struct WeatherSample: Equatable, Sendable {
    var condition: RouteWeatherSegment.Condition
    var precipitationProbability: Double
}

struct MockWeatherSamplingService: WeatherSamplingService {
    private let defaultSample: WeatherSample

    init(defaultSample: WeatherSample = WeatherSample(condition: .clear, precipitationProbability: 0)) {
        self.defaultSample = defaultSample
    }

    func sampleWeather(
        at coordinate: CLLocationCoordinate2D,
        around date: Date
    ) async throws -> WeatherSample {
        defaultSample
    }
}

enum WeatherSampleMapper {
    static func condition(for precipitationProbability: Double) -> RouteWeatherSegment.Condition {
        switch precipitationProbability {
        case 0.5...:
            .rain
        case 0.2..<0.5:
            .cloudy
        default:
            .clear
        }
    }

    static func condition(
        for weatherCondition: WeatherCondition,
        precipitationProbability: Double
    ) -> RouteWeatherSegment.Condition {
        switch weatherCondition {
        case .blizzard,
             .drizzle,
             .flurries,
             .freezingDrizzle,
             .freezingRain,
             .hail,
             .heavyRain,
             .heavySnow,
             .isolatedThunderstorms,
             .rain,
             .scatteredThunderstorms,
             .sleet,
             .snow,
             .strongStorms,
             .sunFlurries,
             .sunShowers,
             .thunderstorms,
             .tropicalStorm,
             .wintryMix:
            .rain
        case .cloudy,
             .foggy,
             .haze,
             .mostlyCloudy,
             .partlyCloudy,
             .smoky:
            .cloudy
        default:
            condition(for: precipitationProbability)
        }
    }
}
