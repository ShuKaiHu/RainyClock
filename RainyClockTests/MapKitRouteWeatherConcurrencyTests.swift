import CoreLocation
import XCTest
@testable import RainyClock

@MainActor
final class MapKitRouteWeatherConcurrencyTests: XCTestCase {
    private let home = ResolvedMapLocation(latitude: 25, longitude: 121, displayAddress: "Home", resolution: .exact)
    private let work = ResolvedMapLocation(latitude: 25, longitude: 121.4, displayAddress: "Work", resolution: .exact)
    private let forecastDate = Date(timeIntervalSince1970: 1_789_520_400)

    func testEndpointsStartBeforeDirectionsAndAllSamplesOverlapInRouteOrder() async throws {
        let geometry = GatedWeatherGeometry(points: [home.coordinate, work.coordinate])
        let weather = GatedRouteWeatherSampler()
        let service = MapKitRouteWeatherService(weatherSamplingService: weather, routeGeometryProvider: geometry)
        let pending = Task { try await fetch(service) }

        let endpointsStarted = await waitUntil {
            let samples = await weather.startedIDs()
            let directionsStarted = await geometry.hasStarted()
            return samples == [0, 40] && directionsStarted
        }
        XCTAssertTrue(endpointsStarted, "Home and Work weather must start while Directions is still gated")
        await geometry.release()
        let allStarted = await waitUntil { await weather.startedIDs() == [0, 10, 20, 30, 40] }
        XCTAssertTrue(allStarted, "Every interior query must start without waiting for another weather sample")
        let peak = await weather.maximumConcurrentSamples()
        XCTAssertEqual(peak, 5, "Two endpoints plus the existing maximum of three interior samples")

        // Finish in the opposite order to prove the snapshot does not adopt
        // completion order or lose the rainiest interior point.
        for id in [40, 30, 20, 10, 0] { await weather.release(id: id) }
        let snapshot = try await pending.value
        XCTAssertEqual(snapshot.forecastAt, forecastDate)
        XCTAssertEqual(snapshot.segments.map(\.precipitationProbability), [0.1, 0.2, 0.9, 0.4, 0.5])
        XCTAssertEqual(snapshot.segments.map(\.name), [
            String(localized: "segment_home_area"),
            MapKitRouteWeatherService.interiorSegmentName(index: 0, total: 3),
            MapKitRouteWeatherService.interiorSegmentName(index: 1, total: 3),
            MapKitRouteWeatherService.interiorSegmentName(index: 2, total: 3),
            String(localized: "segment_office_area")
        ])
        XCTAssertEqual(snapshot.maximumPrecipitationProbability, 0.9)
        XCTAssertTrue(snapshot.exceedsRainThreshold(0.8))
    }

    func testInteriorWeatherFailureCannotBecomeAnEndpointOnlySuccess() async throws {
        let geometry = GatedWeatherGeometry(points: [home.coordinate, work.coordinate])
        await geometry.release()
        let weather = GatedRouteWeatherSampler()
        for id in [0, 10, 30, 40] { await weather.release(id: id) }
        await weather.release(id: 20, failure: true)
        let service = MapKitRouteWeatherService(weatherSamplingService: weather, routeGeometryProvider: geometry)
        do {
            _ = try await fetch(service)
            XCTFail("A missing interior forecast must throw instead of implying a dry route")
        } catch {
            XCTAssertEqual(error as? WeatherConcurrencyTestError, .forecastUnavailable)
        }
    }

    func testEndpointOnlyModeStillStartsBothWeatherRequestsTogether() async throws {
        let geometry = GatedWeatherGeometry(points: [home.coordinate, work.coordinate])
        let weather = GatedRouteWeatherSampler()
        let service = MapKitRouteWeatherService(weatherSamplingService: weather, routeGeometryProvider: geometry)
        let pending = Task { try await fetch(service, mode: .publicTransit) }
        let bothStarted = await waitUntil { await weather.startedIDs() == [0, 40] }
        XCTAssertTrue(bothStarted)
        let geometryStarted = await geometry.hasStarted()
        XCTAssertFalse(geometryStarted, "MapKit does not provide transit route geometry")
        await weather.release(id: 40)
        await weather.release(id: 0)
        let snapshot = try await pending.value
        XCTAssertEqual(snapshot.segments.map(\.precipitationProbability), [0.1, 0.5])
    }

    func testCancellationStopsStructuredWeatherChildren() async throws {
        let geometry = GatedWeatherGeometry(points: [home.coordinate, work.coordinate])
        await geometry.release()
        let weather = CancellationRouteWeatherSampler()
        let service = MapKitRouteWeatherService(weatherSamplingService: weather, routeGeometryProvider: geometry)
        let pending = Task { try await fetch(service) }
        let allStarted = await waitUntil { await weather.startedCount() == 5 }
        XCTAssertTrue(allStarted)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("A cancelled fetch cannot publish a weather snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelled = await weather.cancelledCount()
        XCTAssertEqual(cancelled, 5)
    }

    func testWorkFailureCancelsStalledHomeAndDirections() async {
        await assertFailureDoesNotWaitForOtherRequests(geometry: SleepingWeatherGeometry(), failingID: 40)
    }

    func testInteriorFailureCancelsStalledEndpoints() async {
        let geometry = GatedWeatherGeometry(points: [home.coordinate, work.coordinate])
        await geometry.release()
        await assertFailureDoesNotWaitForOtherRequests(geometry: geometry, failingID: 20)
    }

    private func assertFailureDoesNotWaitForOtherRequests(geometry: any RouteWeatherGeometryProviding,
                                                        failingID: Int) async {
        let service = MapKitRouteWeatherService(weatherSamplingService: EarlyFailureWeatherSampler(failingID: failingID),
                                               routeGeometryProvider: geometry)
        let finished = WeatherFetchFinished()
        let pending = Task {
            do {
                _ = try await fetch(service)
                await finished.mark()
                return Optional<any Error>.none
            } catch {
                await finished.mark()
                return Optional<any Error>.some(error)
            }
        }
        let failedPromptly = await waitUntil { await finished.value() }
        if !failedPromptly { pending.cancel() }
        let error = await pending.value
        XCTAssertTrue(failedPromptly, "A known forecast error must cancel sibling requests without waiting for their successful result")
        XCTAssertEqual(error as? WeatherConcurrencyTestError, .forecastUnavailable)
    }

    private func fetch(_ service: MapKitRouteWeatherService,
                       mode: CommuteAlarmSettings.CommuteMode = .car) async throws -> RouteWeatherSnapshot {
        try await service.fetchRouteWeather(from: "Home", homeLocation: home,
            to: "Work", workLocation: work, mode: mode, around: forecastDate)
    }

    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

private enum WeatherConcurrencyTestError: Error { case forecastUnavailable }

private actor GatedWeatherGeometry: RouteWeatherGeometryProviding {
    private let points: [CLLocationCoordinate2D]
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<[CLLocationCoordinate2D], Never>?

    init(points: [CLLocationCoordinate2D]) { self.points = points }

    func coordinates(from home: ResolvedMapLocation, to work: ResolvedMapLocation,
                     mode: CommuteAlarmSettings.CommuteMode) async throws -> [CLLocationCoordinate2D] {
        started = true
        if released { return points }
        return await withCheckedContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }
    func release() {
        released = true
        continuation?.resume(returning: points)
        continuation = nil
    }
}

private actor GatedRouteWeatherSampler: WeatherSamplingService {
    private var started = Set<Int>()
    private var active = 0
    private var maximumActive = 0
    private var results: [Int: Result<WeatherSample, WeatherConcurrencyTestError>] = [:]
    private var continuations: [Int: CheckedContinuation<WeatherSample, any Error>] = [:]

    func sampleWeather(at coordinate: CLLocationCoordinate2D, around date: Date) async throws -> WeatherSample {
        let id = Int(((coordinate.longitude - 121) * 100).rounded())
        started.insert(id)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if let result = results[id] { return try result.get() }
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }

    func startedIDs() -> Set<Int> { started }
    func maximumConcurrentSamples() -> Int { maximumActive }
    func release(id: Int, failure: Bool = false) {
        let probabilities = [0: 0.1, 10: 0.2, 20: 0.9, 30: 0.4, 40: 0.5]
        let probability = probabilities[id]!
        let result: Result<WeatherSample, WeatherConcurrencyTestError> = failure
            ? .failure(.forecastUnavailable)
            : .success(.init(condition: probability >= 0.5 ? .rain : .clear, precipitationProbability: probability))
        results[id] = result
        if let continuation = continuations.removeValue(forKey: id) {
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}

private actor CancellationRouteWeatherSampler: WeatherSamplingService {
    private var started = 0
    private var cancelled = 0
    func sampleWeather(at coordinate: CLLocationCoordinate2D, around date: Date) async throws -> WeatherSample {
        started += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return .init(condition: .clear, precipitationProbability: 0)
        } catch {
            if error is CancellationError { cancelled += 1 }
            throw error
        }
    }
    func startedCount() -> Int { started }
    func cancelledCount() -> Int { cancelled }
}

private struct SleepingWeatherGeometry: RouteWeatherGeometryProviding {
    func coordinates(from home: ResolvedMapLocation, to work: ResolvedMapLocation,
                     mode: CommuteAlarmSettings.CommuteMode) async throws -> [CLLocationCoordinate2D] {
        try await Task.sleep(for: .seconds(30))
        return [home.coordinate, work.coordinate]
    }
}

private struct EarlyFailureWeatherSampler: WeatherSamplingService {
    let failingID: Int
    func sampleWeather(at coordinate: CLLocationCoordinate2D, around date: Date) async throws -> WeatherSample {
        let id = Int(((coordinate.longitude - 121) * 100).rounded())
        if id == failingID { throw WeatherConcurrencyTestError.forecastUnavailable }
        try await Task.sleep(for: .seconds(30))
        return .init(condition: .clear, precipitationProbability: 0)
    }
}

private actor WeatherFetchFinished {
    private var finished = false
    func mark() { finished = true }
    func value() -> Bool { finished }
}
