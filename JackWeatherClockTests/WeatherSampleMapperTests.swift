import XCTest
import WeatherKit
@testable import JackWeatherClock

final class WeatherSampleMapperTests: XCTestCase {
    func testConditionMappingUsesRainThreshold() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.5), .rain)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.8), .rain)
    }

    func testConditionMappingUsesCloudyBand() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.2), .cloudy)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.49), .cloudy)
    }

    func testConditionMappingUsesClearBand() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.0), .clear)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.19), .clear)
    }

    func testWeatherKitConditionMappingOverridesProbabilityWhenConditionIsWet() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: WeatherCondition.rain, precipitationProbability: 0.1), .rain)
        XCTAssertEqual(WeatherSampleMapper.condition(for: WeatherCondition.thunderstorms, precipitationProbability: 0.1), .rain)
    }

    func testWeatherKitConditionMappingUsesCloudyConditions() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: WeatherCondition.cloudy, precipitationProbability: 0.1), .cloudy)
        XCTAssertEqual(WeatherSampleMapper.condition(for: WeatherCondition.partlyCloudy, precipitationProbability: 0.1), .cloudy)
    }
}
