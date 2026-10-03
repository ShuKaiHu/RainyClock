import XCTest
@testable import RainyClock

/// When a background run re-decides an alarm the evening preview already
/// announced, the person is told — silently — that it moved. These pin when
/// that notice is sent and when it is not.
@MainActor
final class AlarmDecisionChangeTests: XCTestCase {
    private var storage: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AlarmDecisionChangeTests-\(UUID().uuidString)"
        storage = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        storage.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeViewModel(weather: SteerableWeather, previews: PreviewSpy) -> AlarmViewModel {
        let viewModel = AlarmViewModel(
            routeWeatherService: weather,
            notificationScheduler: AcceptingScheduler(),
            previewScheduler: previews,
            canRefreshInBackground: { true },
            settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80)
        )
        viewModel.settings.homeAddress = "Home Street 1"
        viewModel.settings.workAddress = "Work Street 2"
        // Three hours out, so the run never lands inside the check-point-to-ring
        // window that an unattended run is meant to leave alone.
        viewModel.settings.alarmTime = Date().addingTimeInterval(3 * 60 * 60)
        viewModel.settings.rainLeadTimeMinutes = 30
        return viewModel
    }

    func testAnUnattendedRunThatMovesTheRingLaterSendsAChangeNotice() async {
        let weather = SteerableWeather(rainy: true)
        let previews = PreviewSpy()
        let viewModel = makeViewModel(weather: weather, previews: previews)

        await viewModel.evaluateRouteAndScheduleAlarm()
        let armed = try! XCTUnwrap(viewModel.scheduledAlarmSummary)
        XCTAssertTrue(armed.exceedsRainThreshold)
        XCTAssertTrue(previews.changes.isEmpty, "the foreground run shows its result on screen instead")

        weather.rainy = false
        let rescheduled = await viewModel.refreshScheduledAlarmUnattended()

        XCTAssertTrue(rescheduled)
        XCTAssertEqual(previews.changes.count, 1)
        let change = previews.changes[0]
        XCTAssertEqual(change.previousRingDate, armed.scheduledAlarmDate)
        XCTAssertEqual(change.newRingDate, armed.normalAlarmDate)
        XCTAssertGreaterThan(change.newRingDate, change.previousRingDate)
        XCTAssertLessThan(change.maximumProbability, change.threshold)
    }

    func testAnUnattendedRunThatMovesTheRingEarlierSendsAChangeNotice() async {
        let weather = SteerableWeather(rainy: false)
        let previews = PreviewSpy()
        let viewModel = makeViewModel(weather: weather, previews: previews)

        await viewModel.evaluateRouteAndScheduleAlarm()
        let armed = try! XCTUnwrap(viewModel.scheduledAlarmSummary)

        weather.rainy = true
        await viewModel.refreshScheduledAlarmUnattended()

        XCTAssertEqual(previews.changes.count, 1)
        XCTAssertLessThan(previews.changes[0].newRingDate, armed.scheduledAlarmDate)
        XCTAssertGreaterThanOrEqual(previews.changes[0].maximumProbability, previews.changes[0].threshold)
    }

    func testAnUnattendedRunWithTheSameDecisionStaysQuiet() async {
        let weather = SteerableWeather(rainy: true)
        let previews = PreviewSpy()
        let viewModel = makeViewModel(weather: weather, previews: previews)

        await viewModel.evaluateRouteAndScheduleAlarm()
        await viewModel.refreshScheduledAlarmUnattended()

        XCTAssertTrue(previews.changes.isEmpty)
    }

    func testAForegroundRunThatMovesTheRingStaysQuiet() async {
        let weather = SteerableWeather(rainy: true)
        let previews = PreviewSpy()
        let viewModel = makeViewModel(weather: weather, previews: previews)

        await viewModel.evaluateRouteAndScheduleAlarm()
        weather.rainy = false
        await viewModel.evaluateRouteAndScheduleAlarm()

        XCTAssertTrue(previews.changes.isEmpty, "the person is looking at the status line")
    }

    func testEveryRegistrationReplacesThePreviews() async {
        let weather = SteerableWeather(rainy: true)
        let previews = PreviewSpy()
        let viewModel = makeViewModel(weather: weather, previews: previews)

        await viewModel.evaluateRouteAndScheduleAlarm()
        await viewModel.refreshScheduledAlarmUnattended()

        XCTAssertEqual(previews.replacements.count, 2)
    }
}

private final class SteerableWeather: RouteWeatherService, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRainy: Bool

    init(rainy: Bool) {
        storedRainy = rainy
    }

    var rainy: Bool {
        get { lock.withLock { storedRainy } }
        set { lock.withLock { storedRainy = newValue } }
    }

    func fetchRouteWeather(
        from homeAddress: String,
        homeLocation selectedHomeLocation: ResolvedMapLocation?,
        to workAddress: String,
        workLocation selectedWorkLocation: ResolvedMapLocation?,
        mode: CommuteAlarmSettings.CommuteMode,
        around commuteTime: Date
    ) async throws -> RouteWeatherSnapshot {
        let probability = rainy ? 0.8 : 0.1
        return RouteWeatherSnapshot(
            checkedAt: Date(),
            forecastAt: commuteTime,
            segments: [
                RouteWeatherSegment(name: "住家", condition: .cloudy, precipitationProbability: 0.2),
                RouteWeatherSegment(name: "公司", condition: rainy ? .rain : .clear, precipitationProbability: probability)
            ]
        )
    }
}

private struct AcceptingScheduler: NotificationScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func scheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        soundFileNameOverride: String?,
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws {}
    func cancelScheduledAlarms() async {}
}

private final class PreviewSpy: EveningPreviewScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReplacements: [[EveningPreview]] = []
    private var storedChanges: [AlarmDecisionChange] = []

    var replacements: [[EveningPreview]] { lock.withLock { storedReplacements } }
    var changes: [AlarmDecisionChange] { lock.withLock { storedChanges } }

    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async {
        lock.withLock { storedReplacements.append(previews) }
    }
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {
        lock.withLock { storedChanges.append(change) }
    }
}
