import CoreLocation
import Foundation
import MapKit

actor MapKitRouteWeatherService: RouteWeatherService {
    private let geocoder: CLGeocoder
    private let weatherSamplingService: any WeatherSamplingService
    private let maximumSampleCount: Int

    init(
        geocoder: CLGeocoder = CLGeocoder(),
        weatherSamplingService: any WeatherSamplingService = MockWeatherSamplingService(),
        maximumSampleCount: Int = 5
    ) {
        self.geocoder = geocoder
        self.weatherSamplingService = weatherSamplingService
        self.maximumSampleCount = maximumSampleCount
    }

    func fetchRouteWeather(
        from homeAddress: String,
        to workAddress: String,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> RouteWeatherSnapshot {
        let homePlacemark = try await geocode(homeAddress)
        let workPlacemark = try await geocode(workAddress)
        let route = try await route(from: homePlacemark, to: workPlacemark, mode: mode)
        let segments = try await makeSegments(for: route, mode: mode, around: commuteTime)

        return RouteWeatherSnapshot(checkedAt: Date(), segments: segments)
    }

    private func geocode(_ address: String) async throws -> CLPlacemark {
        let placemarks = try await geocoder.geocodeAddressString(address)
        guard let placemark = placemarks.first, placemark.location != nil else {
            throw MapKitRouteWeatherServiceError.addressNotFound(address)
        }

        return placemark
    }

    private func route(
        from homePlacemark: CLPlacemark,
        to workPlacemark: CLPlacemark,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(placemark: homePlacemark))
        request.destination = MKMapItem(placemark: MKPlacemark(placemark: workPlacemark))
        request.transportType = mode.mapKitTransportType

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw MapKitRouteWeatherServiceError.routeNotFound
        }

        return route
    }

    private func makeSegments(
        for route: MKRoute,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> [RouteWeatherSegment] {
        let routeName = route.name.isEmpty
            ? String.localizedStringWithFormat(String(localized: "segment_route_format"), mode.displayName)
            : route.name
        let coordinates = RoutePolylineSampler.sampleCoordinates(from: route.polyline, maximumCount: maximumSampleCount)

        guard !coordinates.isEmpty else {
            return [RouteWeatherSegment(name: routeName, condition: .clear, precipitationProbability: 0)]
        }

        var segments: [RouteWeatherSegment] = []
        segments.reserveCapacity(coordinates.count)

        for (index, coordinate) in coordinates.enumerated() {
            let sample = try await weatherSamplingService.sampleWeather(at: coordinate, around: commuteTime)
            let segmentName = String.localizedStringWithFormat(
                String(localized: "segment_route_sample_format"),
                routeName,
                index + 1
            )
            segments.append(RouteWeatherSegment(
                name: segmentName,
                condition: sample.condition,
                precipitationProbability: sample.precipitationProbability
            ))
        }

        return segments
    }
}

enum MapKitRouteWeatherServiceError: LocalizedError, Equatable {
    case addressNotFound(String)
    case routeNotFound

    var errorDescription: String? {
        switch self {
        case .addressNotFound(let address):
            String.localizedStringWithFormat(String(localized: "error_address_not_found"), address)
        case .routeNotFound:
            String(localized: "error_route_not_found")
        }
    }
}

private extension CommuteAlarmSettings.CommuteMode {
    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .car, .scooter:
            .automobile
        case .walking:
            .walking
        case .publicTransit:
            .transit
        }
    }
}
