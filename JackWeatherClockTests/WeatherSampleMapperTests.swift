import XCTest
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
}
