import CoreLocation
import Foundation
import MapKit

/// The weather pipeline samples this geometry with the same bounded distance
/// rules in production and tests. It never requests extra points for speed.
protocol RouteWeatherGeometryProviding: Sendable {
    func coordinates(from home: ResolvedMapLocation, to work: ResolvedMapLocation,
                     mode: CommuteAlarmSettings.CommuteMode) async throws -> [CLLocationCoordinate2D]
}

actor MapKitRouteWeatherService: RouteWeatherService {
    private let mapItemResolver: MapItemResolver
    private let weatherSamplingService: any WeatherSamplingService
    private let routeGeometryProvider: any RouteWeatherGeometryProviding

    init(
        weatherSamplingService: any WeatherSamplingService = WeatherKitSamplingService(),
        routeGeometryProvider: any RouteWeatherGeometryProviding = MapKitWeatherRouteGeometryProvider()
    ) {
        self.mapItemResolver = MapItemResolver()
        self.weatherSamplingService = weatherSamplingService
        self.routeGeometryProvider = routeGeometryProvider
    }

    func fetchRouteWeather(
        from homeAddress: String,
        homeLocation selectedHomeLocation: ResolvedMapLocation? = nil,
        to workAddress: String,
        workLocation selectedWorkLocation: ResolvedMapLocation? = nil,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> RouteWeatherSnapshot {
        try Task.checkCancellation()
        let homeLocation: ResolvedMapLocation
        if let selectedHomeLocation {
            homeLocation = selectedHomeLocation
        } else {
            homeLocation = try await mapItemResolver.resolve(homeAddress)
        }

        let workLocation: ResolvedMapLocation
        if let selectedWorkLocation {
            workLocation = selectedWorkLocation
        } else {
            workLocation = try await mapItemResolver.resolve(workAddress)
        }
        let segments = try await makeSegments(
            homeLocation: homeLocation,
            workLocation: workLocation,
            mode: mode,
            around: commuteTime
        )

        try Task.checkCancellation()
        return RouteWeatherSnapshot(checkedAt: Date(), forecastAt: commuteTime, segments: segments)
    }

    private func makeSegments(
        homeLocation: ResolvedMapLocation,
        workLocation: ResolvedMapLocation,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> [RouteWeatherSegment] {
        // Endpoints already have coordinates; their WeatherKit requests need not
        // wait for Directions. Structured children belong only to this caller,
        // so cancelling one fetch does not cancel another caller's work.
        return try await withThrowingTaskGroup(of: (Int, [RouteWeatherSegment]).self) { group in
            group.addTask {
                let segment = try await self.sampleSegment(name: String(localized: "segment_home_area"),
                                                          coordinate: homeLocation.coordinate, around: commuteTime)
                return (0, [segment])
            }
            group.addTask {
                let segment = try await self.sampleSegment(name: String(localized: "segment_office_area"),
                                                          coordinate: workLocation.coordinate, around: commuteTime)
                return (2, [segment])
            }
            group.addTask {
                let segments = try await self.interiorSegments(home: homeLocation, work: workLocation,
                                                              mode: mode, around: commuteTime)
                return (1, segments)
            }
            var ordered = [[RouteWeatherSegment]](repeating: [], count: 3)
            // Consume whichever request finishes first, including errors. A Work
            // failure must not wait behind a stalled Home or Directions request.
            for try await (index, segments) in group { ordered[index] = segments }
            return ordered.flatMap { $0 }
        }
    }

    private func sampleSegment(name: String, coordinate: CLLocationCoordinate2D,
                               around date: Date) async throws -> RouteWeatherSegment {
        try Task.checkCancellation()
        let sample = try await weatherSamplingService.sampleWeather(at: coordinate, around: date)
        try Task.checkCancellation()
        return RouteWeatherSegment(name: name, condition: sample.condition,
                                   precipitationProbability: sample.precipitationProbability)
    }

    private func interiorSegments(home: ResolvedMapLocation, work: ResolvedMapLocation,
                                  mode: CommuteAlarmSettings.CommuteMode,
                                  around date: Date) async throws -> [RouteWeatherSegment] {
        try Task.checkCancellation()
        guard mode != .publicTransit else { return [] }
        let geometry = try await routeGeometryProvider.coordinates(from: home, to: work, mode: mode)
        try Task.checkCancellation()
        // The existing sampler chooses at most three points. With the two
        // endpoint tasks, this bounds each fetch to five weather requests.
        let coordinates = RoutePolylineSampler.interiorSamplePoints(along: geometry)
        let sampler = weatherSamplingService
        return try await withThrowingTaskGroup(of: (Int, RouteWeatherSegment).self) { group in
            for (index, coordinate) in coordinates.enumerated() {
                let name = Self.interiorSegmentName(index: index, total: coordinates.count)
                group.addTask {
                    try Task.checkCancellation()
                    let sample = try await sampler.sampleWeather(at: coordinate, around: date)
                    try Task.checkCancellation()
                    return (index, RouteWeatherSegment(name: name, condition: sample.condition,
                                                       precipitationProbability: sample.precipitationProbability))
                }
            }
            var ordered = [RouteWeatherSegment?](repeating: nil, count: coordinates.count)
            for try await (index, segment) in group { ordered[index] = segment }
            // Every submitted sample must succeed; a failed forecast propagates
            // instead of silently shrinking the route or becoming clear weather.
            return ordered.map { $0! }
        }
    }

    /// Names a sample by where it sits along the route — "路程 ¼", "Halfway" —
    /// rather than by an index the reader has to decode. The sampler spaces its
    /// points evenly, so sample `index` of `total` sits at `(index + 1) /
    /// (total + 1)` of the way; `RoutePolylineSamplerTests` pins that agreement
    /// so a changed fraction list cannot quietly make these labels lie.
    static func interiorSegmentName(index: Int, total: Int) -> String {
        let denominator = total + 1
        let divisor = greatestCommonDivisor(index + 1, denominator)

        switch ((index + 1) / divisor, denominator / divisor) {
        case (1, 4):
            return String(localized: "segment_route_quarter")
        case (1, 2):
            return String(localized: "segment_route_half")
        case (3, 4):
            return String(localized: "segment_route_three_quarter")
        case let (numerator, denominator):
            return String.localizedStringWithFormat(
                String(localized: "segment_route_fraction_format"),
                numerator,
                denominator
            )
        }
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        b == 0 ? max(a, 1) : greatestCommonDivisor(b, a % b)
    }
}

/// Geometry remains best effort as before: a Directions failure uses the two
/// endpoints, but cancellation is never converted into a successful snapshot.
actor MapKitWeatherRouteGeometryProvider: RouteWeatherGeometryProviding {
    private var activeDirections: [UUID: MKDirections] = [:]

    func coordinates(from home: ResolvedMapLocation, to work: ResolvedMapLocation,
                     mode: CommuteAlarmSettings.CommuteMode) async throws -> [CLLocationCoordinate2D] {
        try Task.checkCancellation()
        let request = MKDirections.Request()
        request.source = home.mapItem
        request.destination = work.mapItem
        request.transportType = mode == .walking ? .walking : .automobile
        let directions = MKDirections(request: request)
        let id = UUID()
        activeDirections[id] = directions
        defer { activeDirections.removeValue(forKey: id) }
        do {
            let response = try await withTaskCancellationHandler {
                try await directions.calculate()
            } onCancel: {
                Task { await self.cancelDirections(id) }
            }
            try Task.checkCancellation()
            return response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime })?.polyline.coordinateArray ?? []
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    private func cancelDirections(_ id: UUID) { activeDirections[id]?.cancel() }
}

/// Picks interior weather-sample points along a route polyline. Distance-based
/// because weather-model cells are a few km wide — on a short commute the
/// endpoints already cover the route:
///   < 4 km  → no interior samples
///   4–20 km → the midpoint
///   ≥ 20 km → quarter, mid, and three-quarter points
///
/// Replaces the earlier `RoutePolylineSampler` deleted in the 1.6.5 cleanup,
/// which trapped on `Int(Double.nan)` when asked for a single sample; the
/// degenerate cases (empty, single-point, zero-length routes) are unit-tested
/// this time. Matches the Android `RouteSampler` exactly.
enum RoutePolylineSampler {
    static func interiorSamplePoints(along coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else {
            return []
        }

        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(coordinates.count)
        for index in 1..<coordinates.count {
            cumulative.append(cumulative[index - 1] + distance(coordinates[index - 1], coordinates[index]))
        }

        guard let total = cumulative.last, total > 0 else {
            return []
        }

        return interiorSampleFractions(forRouteLength: total).map { fraction in
            point(atDistance: total * fraction, along: coordinates, cumulative: cumulative)
        }
    }

    /// Where along a route of this length the interior samples sit.
    ///
    /// The even spacing is not only cosmetic: `interiorSegmentName` labels each
    /// card from its position, deriving it as `(index + 1) / (count + 1)`.
    /// Changing these fractions to anything unevenly spaced makes those labels
    /// wrong — `RoutePolylineSamplerTests` fails if that happens.
    static func interiorSampleFractions(forRouteLength length: CLLocationDistance) -> [Double] {
        switch length {
        case ..<4_000:
            []
        case ..<20_000:
            [0.5]
        default:
            [0.25, 0.5, 0.75]
        }
    }

    private static func point(
        atDistance target: CLLocationDistance,
        along coordinates: [CLLocationCoordinate2D],
        cumulative: [CLLocationDistance]
    ) -> CLLocationCoordinate2D {
        for index in 1..<coordinates.count where cumulative[index] >= target {
            let segmentLength = cumulative[index] - cumulative[index - 1]
            guard segmentLength > 0 else {
                return coordinates[index]
            }
            let t = (target - cumulative[index - 1]) / segmentLength
            let start = coordinates[index - 1]
            let end = coordinates[index]
            return CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * t,
                longitude: start.longitude + (end.longitude - start.longitude) * t
            )
        }
        return coordinates[coordinates.count - 1]
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
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
