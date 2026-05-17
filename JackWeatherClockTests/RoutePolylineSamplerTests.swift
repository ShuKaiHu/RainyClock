import CoreLocation
import MapKit
import XCTest
@testable import JackWeatherClock

final class RoutePolylineSamplerTests: XCTestCase {
    func testSampleCoordinatesReturnsAllCoordinatesWhenUnderLimit() {
        let coordinates = makeCoordinates(count: 3)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)

        let samples = RoutePolylineSampler.sampleCoordinates(from: polyline, maximumCount: 5)

        XCTAssertEqual(samples.map(roundedLatitude), [0, 1, 2])
    }

    func testSampleCoordinatesEvenlySpreadsAcrossRoute() {
        let coordinates = makeCoordinates(count: 9)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)

        let samples = RoutePolylineSampler.sampleCoordinates(from: polyline, maximumCount: 5)

        XCTAssertEqual(samples.map(roundedLatitude), [0, 2, 4, 6, 8])
    }

    func testSampleCoordinatesReturnsEmptyWhenMaximumIsZero() {
        let coordinates = makeCoordinates(count: 3)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)

        let samples = RoutePolylineSampler.sampleCoordinates(from: polyline, maximumCount: 0)

        XCTAssertTrue(samples.isEmpty)
    }

    private func makeCoordinates(count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { index in
            CLLocationCoordinate2D(latitude: CLLocationDegrees(index), longitude: CLLocationDegrees(index * 2))
        }
    }

    private func roundedLatitude(_ coordinate: CLLocationCoordinate2D) -> Int {
        Int(coordinate.latitude.rounded())
    }
}
