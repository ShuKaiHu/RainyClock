import CoreLocation
import Foundation
import MapKit

@MainActor
protocol RoutePreviewService {
    func previewRoute(
        from homeAddress: String,
        homeLocation selectedHomeLocation: ResolvedMapLocation?,
        to workAddress: String,
        workLocation selectedWorkLocation: ResolvedMapLocation?,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> RoutePreview
}

struct RoutePreview {
    var homeCoordinate: CLLocationCoordinate2D
    var workCoordinate: CLLocationCoordinate2D
    var homeLocation: ResolvedMapLocation
    var workLocation: ResolvedMapLocation
    var route: MKRoute?
    var estimatedTravelTime: TimeInterval?
    var estimatedDistance: CLLocationDistance?

    var routeName: String {
        if let route {
            return route.name.isEmpty ? String(localized: "route_preview_selected_route") : route.name
        }

        if estimatedTravelTime != nil {
            return String(localized: "route_preview_transit_route")
        }

        return String(localized: "route_preview_locations_only")
    }

    var expectedTravelTimeMinutes: Int? {
        guard let travelTime = route?.expectedTravelTime ?? estimatedTravelTime else {
            return nil
        }

        return max(1, Int((travelTime / 60).rounded()))
    }

    var distanceKilometers: Double? {
        guard let distance = route?.distance ?? estimatedDistance else {
            return nil
        }

        return distance / 1_000
    }
}

@MainActor
final class MapKitRoutePreviewService: RoutePreviewService {
    private let mapItemResolver: MapItemResolver

    init() {
        self.mapItemResolver = MapItemResolver()
    }

    func previewRoute(
        from homeAddress: String,
        homeLocation selectedHomeLocation: ResolvedMapLocation? = nil,
        to workAddress: String,
        workLocation selectedWorkLocation: ResolvedMapLocation? = nil,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> RoutePreview {
        var homeLocation: ResolvedMapLocation
        if let selectedHomeLocation {
            homeLocation = selectedHomeLocation
        } else {
            homeLocation = try await mapItemResolver.resolve(homeAddress)
        }

        var workLocation: ResolvedMapLocation
        if let selectedWorkLocation {
            workLocation = selectedWorkLocation
        } else {
            workLocation = try await mapItemResolver.resolve(workAddress)
        }
        homeLocation = await MapItemResolver.includingDistrict(homeLocation)
        workLocation = await MapItemResolver.includingDistrict(workLocation)
        // MKDirections.calculate() does not support the transit transport type;
        // only calculateETA() does, so transit previews use the ETA estimate.
        if mode == .publicTransit {
            let eta = try? await transitETA(from: homeLocation.mapItem, to: workLocation.mapItem)
            return RoutePreview(
                homeCoordinate: homeLocation.coordinate,
                workCoordinate: workLocation.coordinate,
                homeLocation: homeLocation,
                workLocation: workLocation,
                route: nil,
                estimatedTravelTime: eta?.expectedTravelTime,
                estimatedDistance: eta?.distance
            )
        }

        let route = try? await route(from: homeLocation.mapItem, to: workLocation.mapItem, mode: mode)

        return RoutePreview(
            homeCoordinate: homeLocation.coordinate,
            workCoordinate: workLocation.coordinate,
            homeLocation: homeLocation,
            workLocation: workLocation,
            route: route
        )
    }

    private func transitETA(
        from homeItem: MKMapItem,
        to workItem: MKMapItem
    ) async throws -> MKDirections.ETAResponse {
        let request = MKDirections.Request()
        request.source = homeItem
        request.destination = workItem
        request.transportType = .transit

        return try await MKDirections(request: request).calculateETA()
    }

    private func route(
        from homeItem: MKMapItem,
        to workItem: MKMapItem,
        mode: CommuteAlarmSettings.CommuteMode
    ) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = homeItem
        request.destination = workItem
        request.transportType = mode.routePreviewTransportType
        request.highwayPreference = mode == .scooter ? .avoid : .any

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
                throw MapKitRouteWeatherServiceError.routeNotFound
            }

            return route
        } catch let error as MapKitRouteWeatherServiceError {
            throw error
        } catch {
            throw MapKitRouteWeatherServiceError.routeNotFound
        }
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
