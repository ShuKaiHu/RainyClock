import CoreLocation
import Foundation
import MapKit

actor MapKitRouteWeatherService: RouteWeatherService {
    private let geocoder: CLGeocoder

    init(geocoder: CLGeocoder = CLGeocoder()) {
        self.geocoder = geocoder
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
        let segments = makeSegments(for: route, mode: mode)

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

    private func makeSegments(for route: MKRoute, mode: CommuteAlarmSettings.CommuteMode) -> [RouteWeatherSegment] {
        let routeName = route.name.isEmpty
            ? String.localizedStringWithFormat(String(localized: "segment_route_format"), mode.displayName)
            : route.name
        let routeCondition = condition(for: route.expectedTravelTime)

        return [
            RouteWeatherSegment(name: String(localized: "segment_home_area"), condition: .cloudy, precipitationProbability: 0),
            RouteWeatherSegment(name: routeName, condition: routeCondition, precipitationProbability: 0),
            RouteWeatherSegment(name: String(localized: "segment_office_area"), condition: .cloudy, precipitationProbability: 0)
        ]
    }

    private func condition(for expectedTravelTime: TimeInterval) -> RouteWeatherSegment.Condition {
        expectedTravelTime > 45 * 60 ? .cloudy : .clear
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
