import CoreLocation
import Foundation
import MapKit

@MainActor
protocol RoutePreviewService {
    func previewRoute(
        from homeAddress: String,
        to workAddress: String,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> RoutePreview
}

struct RoutePreview {
    var homeCoordinate: CLLocationCoordinate2D
    var workCoordinate: CLLocationCoordinate2D
    var route: MKRoute

    var routeName: String {
        route.name.isEmpty ? String(localized: "route_preview_selected_route") : route.name
    }

    var expectedTravelTimeMinutes: Int {
        max(1, Int((route.expectedTravelTime / 60).rounded()))
    }

    var distanceKilometers: Double {
        route.distance / 1_000
    }
}

@MainActor
final class MapKitRoutePreviewService: RoutePreviewService {
    private let geocoder: CLGeocoder

    init(geocoder: CLGeocoder = CLGeocoder()) {
        self.geocoder = geocoder
    }

    func previewRoute(
        from homeAddress: String,
        to workAddress: String,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> RoutePreview {
        let homePlacemark = try await geocode(homeAddress)
        let workPlacemark = try await geocode(workAddress)
        let route = try await route(from: homePlacemark, to: workPlacemark, mode: mode)

        guard let homeCoordinate = homePlacemark.location?.coordinate,
              let workCoordinate = workPlacemark.location?.coordinate else {
            throw MapKitRouteWeatherServiceError.routeNotFound
        }

        return RoutePreview(
            homeCoordinate: homeCoordinate,
            workCoordinate: workCoordinate,
            route: route
        )
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
        request.transportType = mode.routePreviewTransportType
        request.highwayPreference = mode == .scooter ? .avoid : .any

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw MapKitRouteWeatherServiceError.routeNotFound
        }

        return route
    }
}

private extension CommuteAlarmSettings.CommuteMode {
    var routePreviewTransportType: MKDirectionsTransportType {
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
