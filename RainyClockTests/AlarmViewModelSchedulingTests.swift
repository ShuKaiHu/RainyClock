import XCTest
@testable import RainyClock

/// Covers explicit scheduling and the foreground UI's automatic scheduling flow.
@MainActor
final class AlarmViewModelSchedulingTests: XCTestCase {
    private var storage: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AlarmViewModelSchedulingTests-\(UUID().uuidString)"
        storage = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel(spy: SchedulerSpy) -> AlarmViewModel {
        let viewModel = AlarmViewModel(
            routeWeatherService: MockRouteWeatherService(),
            notificationScheduler: spy,
            settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80)
        )
        viewModel.settings.homeAddress = "Home Street 1"
        viewModel.settings.workAddress = "Work Street 2"
        return viewModel
    }

    private func makeAutomaticViewModel(spy: SchedulerSpy, confirmed: Bool = true) -> AlarmViewModel {
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(),
            routePreviewService: AutomaticRoutePreview(), notificationScheduler: spy,
            previewScheduler: AutomaticPreviewScheduler(), settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80))
        if confirmed {
            model.setAddressFromSuggestion("Home Street 1", location: AutomaticRoutePreview.home, field: .home)
            model.setAddressFromSuggestion("Work Street 2", location: AutomaticRoutePreview.work, field: .work)
        } else {
            model.settings.homeAddress = "Home Street 1"
            model.settings.workAddress = "Work Street 2"
        }
        return model
    }

    func testConfirmedRouteOnlyCreatesInitialAlarmAfterForegroundActivation() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy)
        model.settings.snoozeDurationMinutes = 9
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.authorizationCalls, 0)

        model.activateAutomaticScheduling()
        model.activateAutomaticScheduling()
        try await waitUntil("initial automatic alarm") { model.hasScheduledAlarm && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertEqual(spy.scheduleCalls.first?.snoozeMinutes, 9)
        XCTAssertNil(model.scheduleErrorMessage)
    }

    func testWetWeeklyAlarmUsesEarlySoundAndDryAlarmUsesNormalSound() async throws {
        for rainy in [true, false] {
            let spy = SchedulerSpy()
            let model = makeViewModel(spy: spy)
            model.settings.homeAddress = rainy ? "Rain Street" : "Clear Street"
            model.settings.alarmTime = Date().addingTimeInterval(3 * 3_600)
            model.settings.alarmSound = .softPiano
            model.settings.earlyAlarmSound = .digitalBeep
            await model.evaluateRouteAndScheduleAlarm()
            let call = try XCTUnwrap(spy.scheduleCalls.first)
            XCTAssertEqual(call.sound, rainy ? .digitalBeep : .softPiano)
            XCTAssertEqual(call.soundFileNameOverride, rainy ? "DigitalBeep.wav" : "SoftPiano.wav")
            XCTAssertEqual(call.date < call.normalAlarmDate, rainy)
        }
    }

    func testZeroLeadTimeRemainsInvalidAndDoesNotRegisterEitherSound() async {
        let spy = SchedulerSpy()
        let model = makeViewModel(spy: spy)
        model.settings.homeAddress = "Rain Street"
        model.settings.rainLeadTimeMinutes = 0
        model.settings.alarmSound = .softPiano
        model.settings.earlyAlarmSound = .digitalBeep
        XCTAssertFalse(model.canSchedule)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(spy.scheduleCalls.isEmpty)
        XCTAssertFalse(model.hasScheduledAlarm)
    }

    func testDraftAndUnconfirmedPreviewNeverAutomaticallyArm() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy, confirmed: false)
        model.activateAutomaticScheduling()
        model.settings.rainLeadTimeMinutes = 20
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.authorizationCalls, 0)

        await model.previewRoute()
        model.confirmSuggestedAddress(.home)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.authorizationCalls, 0)
        XCTAssertTrue(model.requiresSuggestedAddressConfirmation)

        model.confirmSuggestedAddress(.work)
        try await waitUntil("both addresses confirmed") { model.hasScheduledAlarm && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.count, 1)
    }

    func testAddressEditRemovesOldAlarmThenConfirmationAutomaticallyRearms() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy)
        model.activateAutomaticScheduling()
        try await waitUntil("initial alarm") { model.hasScheduledAlarm && !model.isScheduling }

        model.settings.homeAddress = "A new draft"
        try await waitUntil("old route removed") { !model.hasScheduledAlarm }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertEqual(spy.cancelCount, 1)

        await model.previewRoute()
        model.confirmSuggestedAddress(.home)
        try await waitUntil("replacement route armed") { spy.scheduleCalls.count == 2 && !model.isScheduling }
        XCTAssertEqual(model.settings.homeAddress, "A new draft")
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertFalse(model.isScheduleStale)
    }

    func testFailedAutomaticRegistrationDoesNotLoopAndARelevantEditRetries() async throws {
        let spy = SchedulerSpy()
        spy.scheduleFailure = TestError.registrationRejected
        let model = makeAutomaticViewModel(spy: spy)
        model.activateAutomaticScheduling()
        try await waitUntil("automatic registration failure") { model.scheduleErrorMessage != nil && !model.isScheduling }
        XCTAssertFalse(model.hasScheduledAlarm)
        model.activateAutomaticScheduling()
        model.settings.timeFormat = .twentyFourHour
        await model.previewRoute()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(spy.authorizationCalls, 1)

        spy.scheduleFailure = nil
        model.settings.rainLeadTimeMinutes += 5
        try await waitUntil("edited settings retried") { model.hasScheduledAlarm && !model.isScheduling }
        XCTAssertEqual(spy.authorizationCalls, 2)
        XCTAssertNil(model.scheduleErrorMessage)
    }

    func testClearingEveryWeekdayTurnsOffAndSelectingADayRearms() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy)
        model.activateAutomaticScheduling()
        try await waitUntil("initial alarm") { model.hasScheduledAlarm && !model.isScheduling }
        let originalWeekdays = model.settings.selectedWeekdays
        model.settings.selectedWeekdays = []
        try await waitUntil("all days disabled") { !model.hasScheduledAlarm }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        model.settings.selectedWeekdays = originalWeekdays
        try await waitUntil("weekday reenabled") { spy.scheduleCalls.count == 2 && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.last?.weekdays, originalWeekdays)
    }

    func testPermissionFailureIsExposedAndManualRetryClearsIt() async throws {
        let spy = SchedulerSpy()
        spy.isAuthorized = false
        let model = makeAutomaticViewModel(spy: spy)
        model.activateAutomaticScheduling()
        try await waitUntil("permission failure") { model.scheduleErrorMessage != nil && !model.isScheduling }
        XCTAssertFalse(model.hasScheduledAlarm)
        spy.isAuthorized = true
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertNil(model.scheduleErrorMessage)
    }

    func testParameterChangeAutoRefreshesTheScheduledAlarm() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertTrue(viewModel.hasScheduledAlarm)

        viewModel.settings.snoozeDurationMinutes = 9

        try await waitUntil("auto refresh re-registered the alarm") {
            // The spy records the request before its async method returns.
            // Wait for the view model to publish the completed registration.
            spy.scheduleCalls.count == 2 && !viewModel.isScheduling
        }
        XCTAssertEqual(spy.scheduleCalls.last?.snoozeMinutes, 9)
        XCTAssertFalse(viewModel.isScheduleStale)
        XCTAssertEqual(spy.cancelCount, 0)
    }

    func testTimeFormatImmediatelyUpdatesWeatherStatusWithoutChangingAlarm() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)
        await viewModel.evaluateRouteAndScheduleAlarm()
        let snapshot = try XCTUnwrap(viewModel.routeWeatherSnapshot)
        let twelveHourStatus = viewModel.statusMessage
        let originalSummary = viewModel.scheduledAlarmSummary
        XCTAssertTrue(twelveHourStatus.contains(ClockTimeFormat.twelveHour.dateTime(snapshot.forecastAt)))

        viewModel.settings.timeFormat = .twentyFourHour
        XCTAssertNotEqual(viewModel.statusMessage, twelveHourStatus)
        XCTAssertTrue(viewModel.statusMessage.contains(ClockTimeFormat.twentyFourHour.dateTime(snapshot.forecastAt)))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertEqual(viewModel.scheduledAlarmSummary, originalSummary)
        XCTAssertFalse(viewModel.isScheduleStale)
    }

    func testAddressChangeRemovesTheAlarmInsteadOfRefreshing() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(viewModel.hasScheduledAlarm)

        viewModel.settings.homeAddress = "Somewhere Completely Different 3"

        try await waitUntil("alarm removed after the address change") {
            spy.cancelCount >= 1 && !viewModel.hasScheduledAlarm
        }

        // No sneaky auto-reschedule afterwards: the button is the only way back.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertFalse(viewModel.isScheduleStale)
    }

    func testRevertingAChangeBeforeTheDebounceFiresDoesNothing() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(spy.scheduleCalls.count, 1)

        let original = viewModel.settings.rainLeadTimeMinutes
        viewModel.settings.rainLeadTimeMinutes = original + 5
        viewModel.settings.rainLeadTimeMinutes = original

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertFalse(viewModel.isScheduleStale)
    }

    func testParameterChangesDoNothingWhileNoAlarmIsScheduled() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        viewModel.settings.snoozeDurationMinutes = 3
        viewModel.settings.rainLeadTimeMinutes = 45

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(spy.scheduleCalls.isEmpty)
        XCTAssertEqual(spy.cancelCount, 0)
    }

    /// A registration that throws must leave nothing behind that says an alarm is set.
    /// The summary is persisted while the failure message is not, so publishing it
    /// before registration succeeded made the next launch show a green "alarm
    /// scheduled" state for an alarm the system had never accepted.
    func testFailedRegistrationLeavesNoScheduledAlarmEvenAfterRelaunch() async throws {
        let spy = SchedulerSpy()
        spy.scheduleFailure = TestError.registrationRejected
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()

        XCTAssertFalse(viewModel.hasScheduledAlarm)
        XCTAssertNil(viewModel.scheduledAlarmSummary)

        let relaunched = AlarmViewModel(
            routeWeatherService: MockRouteWeatherService(),
            notificationScheduler: spy,
            settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80)
        )
        XCTAssertFalse(relaunched.hasScheduledAlarm)
    }

    /// The registered alarm repeats weekly with whatever the rain check said when it
    /// ran, so opening the app has to re-decide it once the answer is old enough.
    func testOpeningTheAppRedecidesAnArmedAlarmOnlyOnceItsRainCheckHasAgedOut() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(spy.scheduleCalls.count, 1)

        // Fresh decision: opening the app must not refetch or re-register anything.
        await viewModel.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertEqual(spy.scheduleCalls.count, 1)

        // Age the stored decision past its lifetime, the way an overnight gap would.
        storage.set(Date().addingTimeInterval(-5 * 60 * 60), forKey: "lastWeatherEvaluationAt")
        let relaunched = AlarmViewModel(
            routeWeatherService: MockRouteWeatherService(),
            notificationScheduler: spy,
            settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80)
        )
        XCTAssertTrue(relaunched.hasScheduledAlarm)

        await relaunched.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertEqual(spy.scheduleCalls.count, 2)
    }

    /// The refresh runs unprompted, so a failure must not replace the status line of an
    /// alarm that is still correctly armed from the previous run.
    func testAStaleRefreshThatFailsKeepsTheAlarmAndItsStatusMessage() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)

        await viewModel.evaluateRouteAndScheduleAlarm()
        let armedStatus = viewModel.statusMessage

        storage.set(Date().addingTimeInterval(-5 * 60 * 60), forKey: "lastWeatherEvaluationAt")
        let relaunched = AlarmViewModel(
            routeWeatherService: MockRouteWeatherService(),
            notificationScheduler: spy,
            settingsStorage: storage,
            autoRefreshDebounce: .milliseconds(80)
        )
        let restoredStatus = relaunched.statusMessage
        spy.scheduleFailure = TestError.registrationRejected

        await relaunched.refreshScheduledAlarmIfWeatherIsStale()

        XCTAssertTrue(relaunched.hasScheduledAlarm)
        XCTAssertEqual(relaunched.statusMessage, restoredStatus)
        XCTAssertFalse(armedStatus.isEmpty)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting until \(what)", file: file, line: line)
    }
}

private enum TestError: Error {
    case registrationRejected
}

private final class SchedulerSpy: NotificationScheduling, @unchecked Sendable {
    struct ScheduleCall {
        var date: Date
        var normalAlarmDate: Date
        var weekdays: Set<Int>
        var sound: CommuteAlarmSettings.AlarmSound
        var soundFileNameOverride: String?
        var snoozeMinutes: Int?
    }

    private let lock = NSLock()
    private var storedScheduleCalls: [ScheduleCall] = []
    private var storedCancelCount = 0
    private var storedScheduleFailure: Error?
    private var storedAuthorizationCalls = 0
    private var storedIsAuthorized = true

    var authorizationCalls: Int { lock.withLock { storedAuthorizationCalls } }
    var isAuthorized: Bool {
        get { lock.withLock { storedIsAuthorized } }
        set { lock.withLock { storedIsAuthorized = newValue } }
    }

    /// Set to make the next registration throw, standing in for AlarmKit or
    /// `UNUserNotificationCenter` refusing the alarm.
    var scheduleFailure: Error? {
        get { lock.withLock { storedScheduleFailure } }
        set { lock.withLock { storedScheduleFailure = newValue } }
    }

    var scheduleCalls: [ScheduleCall] {
        lock.withLock { storedScheduleCalls }
    }

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    func requestAuthorization() async throws -> Bool {
        lock.withLock {
            storedAuthorizationCalls += 1
            return storedIsAuthorized
        }
    }

    func scheduleAlarm(
        at date: Date,
        normalAlarmDate: Date,
        weekdays: Set<Int>,
        sound: CommuteAlarmSettings.AlarmSound,
        soundFileNameOverride: String?,
        snoozeMinutes: Int?,
        title: String,
        body: String
    ) async throws {
        if let failure = scheduleFailure {
            throw failure
        }

        lock.withLock {
            storedScheduleCalls.append(
                ScheduleCall(
                    date: date,
                    normalAlarmDate: normalAlarmDate,
                    weekdays: weekdays,
                    sound: sound,
                    soundFileNameOverride: soundFileNameOverride,
                    snoozeMinutes: snoozeMinutes
                )
            )
        }
    }

    func cancelScheduledAlarms() async {
        lock.withLock {
            storedCancelCount += 1
        }
    }
}

@MainActor
private struct AutomaticRoutePreview: RoutePreviewService {
    static let home = ResolvedMapLocation(latitude: 25.03, longitude: 121.56,
        displayAddress: "Home Street 1", resolution: .exact)
    static let work = ResolvedMapLocation(latitude: 25.05, longitude: 121.52,
        displayAddress: "Work Street 2", resolution: .exact)

    func previewRoute(from homeAddress: String, homeLocation: ResolvedMapLocation?,
        to workAddress: String, workLocation: ResolvedMapLocation?,
        mode: CommuteAlarmSettings.CommuteMode) async throws -> RoutePreview {
        var home = homeLocation ?? Self.home
        var work = workLocation ?? Self.work
        home.displayAddress = homeAddress
        work.displayAddress = workAddress
        return RoutePreview(homeCoordinate: home.coordinate, workCoordinate: work.coordinate,
            homeLocation: home, workLocation: work, route: nil)
    }
}

private struct AutomaticPreviewScheduler: EveningPreviewScheduling {
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}
