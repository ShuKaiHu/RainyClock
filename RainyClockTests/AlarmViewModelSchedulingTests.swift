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

    private func makeAutomaticViewModel(spy: SchedulerSpy, confirmed: Bool = true,
                                        preview: AutomaticRoutePreview = AutomaticRoutePreview()) -> AlarmViewModel {
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(),
            routePreviewService: preview, notificationScheduler: spy,
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
        let model = makeAutomaticViewModel(spy: spy, confirmed: false, preview: AutomaticRoutePreview(resolvedNames: [
            "Home Street 1": "Home Street 1, Test District", "Work Street 2": "Work Street 2, Test District"]))
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
        let model = makeAutomaticViewModel(spy: spy, preview: AutomaticRoutePreview(resolvedNames: [
            "A new draft": "A New Draft Road, Test District"]))
        model.activateAutomaticScheduling()
        try await waitUntil("initial alarm") { model.hasScheduledAlarm && !model.isScheduling }

        model.settings.homeAddress = "A new draft"
        try await waitUntil("old route removed") { !model.hasScheduledAlarm }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        // The alarm is still on: a ringing or snoozing one is left to finish (adversarial
        // review, 2026-10-01). Only turning the alarm off cancels everything.
        XCTAssertEqual(spy.retireCount, 1)
        XCTAssertEqual(spy.cancelCount, 0)

        await model.previewRoute()
        model.confirmSuggestedAddress(.home)
        try await waitUntil("replacement route armed") { spy.scheduleCalls.count == 2 && !model.isScheduling }
        XCTAssertEqual(model.settings.homeAddress, "A New Draft Road, Test District")
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertFalse(model.isScheduleStale)
    }

    /// 1.7.0 hid this banner inside the address sheet while it blocked scheduling, so
    /// "Taipei main station" typed by hand left the home screen at "No alarm set".
    func testTypedAddressDifferingOnlyInCaseIsConfirmedWithoutBanner() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy, confirmed: false, preview: AutomaticRoutePreview(resolvedNames: [
            "taipei main station": "Taipei Main Station", "ＴＡＩＰＥＩ　１０１": "Taipei 101"]))
        model.settings.homeAddress = "taipei main station"
        model.settings.workAddress = "ＴＡＩＰＥＩ　１０１"
        await model.previewRoute()
        XCTAssertTrue(model.suggestedAddressMatches.isEmpty)
        XCTAssertFalse(model.requiresSuggestedAddressConfirmation)
        XCTAssertEqual(model.settings.homeAddress, "taipei main station")
        XCTAssertEqual(model.settings.confirmedHomeAddressInput, "taipei main station")
        XCTAssertNotNil(model.settings.homeResolvedLocation)
        XCTAssertNotNil(model.settings.workResolvedLocation)
        XCTAssertTrue(model.canSchedule)

        model.activateAutomaticScheduling()
        try await waitUntil("typed route armed") { model.hasScheduledAlarm && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.count, 1)
    }

    func testTypedAddressResolvingToDifferentPlaceStillNeedsConfirmation() async throws {
        let spy = SchedulerSpy()
        let model = makeAutomaticViewModel(spy: spy, confirmed: false, preview: AutomaticRoutePreview(resolvedNames: [
            "Home Street 1": "Taipei Zoo"]))
        model.activateAutomaticScheduling()
        await model.previewRoute()
        XCTAssertEqual(model.suggestedAddressMatches[.home]?.suggestedAddress, "Taipei Zoo")
        XCTAssertFalse(model.canSchedule)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(spy.scheduleCalls.isEmpty)
    }

    func testSameNameStillNeedsConfirmationWhenOnlySuggestedOrNumbered() async {
        let suggested = makeAutomaticViewModel(spy: SchedulerSpy(), confirmed: false,
            preview: AutomaticRoutePreview(resolution: .suggested))
        await suggested.previewRoute()
        XCTAssertNotNil(suggested.suggestedAddressMatches[.home])

        // The same street and number exist in many towns.
        let numbered = makeAutomaticViewModel(spy: SchedulerSpy(), confirmed: false)
        numbered.settings.homeAddress = "中正路100號"
        await numbered.previewRoute()
        XCTAssertEqual(numbered.suggestedAddressMatches[.home]?.suggestedAddress, "中正路100號")
        XCTAssertTrue(numbered.requiresSuggestedAddressConfirmation)
    }

    func testAutoConfirmedAddressSurvivesRelaunchAndEditingDropsIt() async throws {
        let model = makeAutomaticViewModel(spy: SchedulerSpy(), confirmed: false, preview: AutomaticRoutePreview(resolvedNames: [
            "taipei main station": "Taipei Main Station"]))
        model.settings.homeAddress = "taipei main station"
        await model.previewRoute()
        XCTAssertNil(model.suggestedAddressMatches[.home])

        // The restored confirmation must still arm the alarm, and a new preview that
        // names another place must not bring the banner back.
        let relaunchSpy = SchedulerSpy()
        let relaunched = AlarmViewModel(routeWeatherService: MockRouteWeatherService(),
            routePreviewService: AutomaticRoutePreview(resolvedNames: ["taipei main station": "Taipei Zoo"]),
            notificationScheduler: relaunchSpy, previewScheduler: AutomaticPreviewScheduler(),
            settingsStorage: storage, autoRefreshDebounce: .milliseconds(80))
        XCTAssertEqual(relaunched.settings.homeAddress, "taipei main station")
        XCTAssertEqual(relaunched.settings.confirmedHomeAddressInput, "taipei main station")
        XCTAssertNotNil(relaunched.settings.homeResolvedLocation)
        await relaunched.previewRoute()
        XCTAssertNil(relaunched.suggestedAddressMatches[.home])
        relaunched.activateAutomaticScheduling()
        try await waitUntil("restored route armed") { relaunched.hasScheduledAlarm && !relaunched.isScheduling }
        XCTAssertEqual(relaunchSpy.scheduleCalls.count, 1)

        relaunched.settings.homeAddress = "taipei main statio"
        XCTAssertNil(relaunched.settings.confirmedHomeAddressInput)
        XCTAssertNil(relaunched.settings.homeResolvedLocation)
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
            spy.retireCount >= 1 && !viewModel.hasScheduledAlarm
        }
        XCTAssertEqual(spy.cancelCount, 0, "A snooze in progress is not ended by an address change")

        // No sneaky auto-reschedule afterwards: the button is the only way back.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        XCTAssertFalse(viewModel.isScheduleStale)
    }

    /// Clearing the last repeat day removes the registration the same way: the alarm is still
    /// on, so a snooze in progress finishes. Turning it off then ends everything.
    func testClearingTheLastRepeatDayLeavesAnAlarmInProgressToFinish() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)
        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(viewModel.hasScheduledAlarm)

        viewModel.settings.selectedWeekdays = []
        try await waitUntil("the registration is removed") { !viewModel.hasScheduledAlarm && spy.retireCount == 1 }
        XCTAssertEqual(spy.cancelCount, 0)
        XCTAssertEqual(viewModel.statusMessage, String(localized: "calendar_off_no_weekdays"))

        await viewModel.turnAlarmOff()
        XCTAssertGreaterThan(spy.cancelCount, 0, "Turning the alarm off ends a snooze")
    }

    /// Adversarial review, 2026-10-01: an unattended run (a launch that found the decision stale,
    /// a background task, a push) re-registering the weekly alarm while it rang or snoozed left
    /// the replaced repeating alarm to finish — and, once stopped with no activation after,
    /// to ring again at its old time next weekday beside its replacement. It waits instead.
    func testAnUnattendedRunLeavesARingingOrSnoozingAlarmAlone() async throws {
        final class InProgress { var value = false }
        let inProgress = InProgress()
        let spy = SchedulerSpy()
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: spy,
                                   settingsStorage: storage, autoRefreshDebounce: .milliseconds(80),
                                   alarmInProgress: { inProgress.value })
        model.settings.homeAddress = "Clear Street"
        model.settings.workAddress = "Work Street 2"
        model.settings.alarmTime = Date().addingTimeInterval(3 * 3_600)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(spy.scheduleCalls.count, 1)

        inProgress.value = true
        let rescheduled = await model.refreshScheduledAlarmUnattended()
        XCTAssertFalse(rescheduled)
        XCTAssertEqual(spy.scheduleCalls.count, 1, "Nothing re-registered while an alarm rings or snoozes")

        inProgress.value = false
        _ = await model.refreshScheduledAlarmUnattended()
        XCTAssertEqual(spy.scheduleCalls.count, 2, "The next run re-decides")
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

    /// A registered forecast decision is recorded for the morning it decided (2026-10-09). Opening
    /// the app inside that morning's re-check window keeps a young decision made in it, but
    /// re-decides when none is on record there, however young `lastWeatherEvaluationAt` is: else
    /// an evening open would leave the morning reading "not re-checked" though the app ran.
    func testARegisteredDecisionIsLoggedAndAnOpenInsideTheWindowReDecidesWithoutOne() async throws {
        let spy = SchedulerSpy()
        let viewModel = makeViewModel(spy: spy)
        viewModel.settings.rainLeadTimeMinutes = 30
        // The check point two hours ahead: now is inside its nine-hour window.
        viewModel.settings.alarmTime = Date().addingTimeInterval(2.5 * 3_600)
        await viewModel.evaluateRouteAndScheduleAlarm()
        XCTAssertEqual(spy.scheduleCalls.count, 1)
        let morning = try XCTUnwrap(viewModel.scheduledAlarmSummary?.normalAlarmDate)
        let logged = WeatherDecisionLog.load(from: storage)
        XCTAssertEqual(logged.decisions.map(\.morning), [morning])
        XCTAssertLessThan(abs(try XCTUnwrap(logged.decisions.first?.checkedAt).timeIntervalSinceNow), 60)

        await viewModel.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertEqual(spy.scheduleCalls.count, 1, "A decision inside the window is the re-check")

        // Only an evening decision before the window is on record; the last evaluation is young.
        var evening = WeatherDecisionLog()
        evening.record(morning: morning, checkedAt: morning.addingTimeInterval(-11 * 3_600))
        evening.save(to: storage)
        let relaunched = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: spy,
                                        settingsStorage: storage, autoRefreshDebounce: .milliseconds(80))
        // Moments on the morning's own calendar day (the morning can fall just after midnight).
        let calendar = AlarmCalendarSettings.calendar
        let dayStart = calendar.startOfDay(for: morning)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let afterCheckPoint = max(morning.addingTimeInterval(-10 * 60), dayStart)
        let afterRing = min(morning.addingTimeInterval(5 * 60), dayEnd.addingTimeInterval(-1))
        let expected = UnrecheckedMorning(morning: morning, forecastCheckedAt: morning.addingTimeInterval(-11 * 3_600))
        XCTAssertEqual(relaunched.unrecheckedMorning(now: afterCheckPoint), expected,
                       "As things stand, the morning would ring on the evening forecast")
        XCTAssertEqual(relaunched.unrecheckedMorning(now: afterRing), expected, "And says so after the ring")
        if morning.addingTimeInterval(WeatherDecisionLog.retrospective) < dayEnd {
            XCTAssertNil(relaunched.unrecheckedMorning(now: morning.addingTimeInterval(WeatherDecisionLog.retrospective)))
        }
        // The widget's adapter samples the same rule at its entries' moments.
        let snapshot = TomorrowWidgetSnapshotBuilder.snapshot(for: relaunched)
        func shown(at moment: Date) -> TomorrowWidgetSnapshot.Entry? {
            let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: moment, currentTimeZoneID: calendar.timeZone.identifier)
            if case .status(let entry) = plan.items[0].state { return entry }
            return nil
        }
        XCTAssertEqual(shown(at: afterCheckPoint)?.notRecheckedMorning, morning)
        XCTAssertNil(shown(at: Date())?.notRecheckedMorning, "Not before the check point")
        await relaunched.refreshScheduledAlarmIfWeatherIsStale()
        XCTAssertEqual(spy.scheduleCalls.count, 2, "Inside the window with no decision there: this open re-decides")
        XCTAssertTrue(WeatherDecisionLog.load(from: storage).wasRechecked(
            morning: morning, checkPoint: morning.addingTimeInterval(-30 * 60)))
        XCTAssertNil(relaunched.unrecheckedMorning(now: afterCheckPoint))
        XCTAssertNil(relaunched.unrecheckedMorning(now: afterRing))
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

    // MARK: - Master switch (1.8.0)

    private func makeSwitchViewModel(spy: SchedulerSpy, weather: RouteWeatherService = MockRouteWeatherService(),
                                     holdsAlarms: @escaping @MainActor () -> Bool = { false }) -> AlarmViewModel {
        let model = AlarmViewModel(routeWeatherService: weather, notificationScheduler: spy, settingsStorage: storage,
                                   autoRefreshDebounce: .milliseconds(80), systemHoldsAlarms: holdsAlarms)
        model.settings.homeAddress = "Clear Street"
        model.settings.workAddress = "Work Street 2"
        model.settings.alarmTime = Date().addingTimeInterval(3 * 3_600)
        return model
    }

    func testTurningOffRemovesAndNothingReArms() async throws {
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy)
        await model.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(model.hasScheduledAlarm)
        let registered = spy.scheduleCalls.count
        let cancelled = spy.cancelCount

        await model.turnAlarmOff()
        XCTAssertFalse(model.hasScheduledAlarm)
        XCTAssertGreaterThan(spy.cancelCount, cancelled, "Cancelled at once, then swept again")
        XCTAssertFalse(model.canSchedule)
        XCTAssertFalse(model.isAlarmSwitchOn())
        XCTAssertEqual(model.statusMessage, String(localized: "status_alarm_turned_off"))

        model.settings.alarmTime = model.settings.alarmTime.addingTimeInterval(600)
        model.settings.selectedWeekdays = [2, 3]
        model.settings.alarmSound = .softPiano
        await model.evaluateRouteAndScheduleAlarm()
        await model.applyCalendarSettings()
        _ = await model.refreshScheduledAlarmUnattended()
        await model.refreshScheduledAlarmIfWeatherIsStale()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.scheduleCalls.count, registered, "Nothing may re-arm an alarm the user turned off")

        let relaunched = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: spy,
                                        settingsStorage: storage, autoRefreshDebounce: .milliseconds(80))
        XCTAssertFalse(relaunched.settings.isAlarmEnabled)
        relaunched.activateAutomaticScheduling()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.scheduleCalls.count, registered)
        XCTAssertFalse(relaunched.hasScheduledAlarm)
    }

    func testTurningBackOnArmsImmediately() async throws {
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy)
        await model.evaluateRouteAndScheduleAlarm()
        await model.turnAlarmOff()
        let before = spy.scheduleCalls.count
        await model.turnAlarmOn()
        XCTAssertTrue(model.settings.isAlarmEnabled)
        XCTAssertTrue(model.hasScheduledAlarm)
        XCTAssertEqual(spy.scheduleCalls.count, before + 1)
        XCTAssertTrue(model.isAlarmSwitchOn())
    }

    func testTurningOnOfflineStillArmsAtTheUsualTime() async throws {
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy, weather: OfflineSwitchWeather())
        await model.turnAlarmOff()
        await model.turnAlarmOn()
        XCTAssertTrue(model.hasScheduledAlarm, "On means armed, like the Clock app")
        let call = try XCTUnwrap(spy.scheduleCalls.last)
        XCTAssertEqual(call.date, call.normalAlarmDate, "No rain decision was possible, so the usual time")
        XCTAssertEqual(model.scheduleErrorMessage, String(localized: "alarm_on_without_forecast"))
    }

    func testTurningOnInsideThisMorningsCheckWindowKeepsThisMorningsRing() async throws {
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy)
        model.settings.homeAddress = "Rain Street"
        model.settings.alarmTime = Date().addingTimeInterval(10 * 60)
        await model.turnAlarmOff()
        await model.turnAlarmOn()
        let call = try XCTUnwrap(spy.scheduleCalls.last)
        let untilRing = call.normalAlarmDate.timeIntervalSinceNow
        XCTAssertTrue(untilRing > 0 && untilRing <= 11 * 60,
                      "A rainy tomorrow must not replace the ring due in 10 minutes (got \(untilRing) s)")
        XCTAssertEqual(call.date, call.normalAlarmDate)
    }

    func testOffOnOffEndsOff() async throws {
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy)
        await model.evaluateRouteAndScheduleAlarm()
        await model.turnAlarmOff()
        await model.turnAlarmOn()
        await model.turnAlarmOff()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.settings.isAlarmEnabled)
        XCTAssertFalse(model.hasScheduledAlarm)
    }

    /// Turned off while a registration's forecast was still loading: that run must not
    /// arm anything when it finishes (adversarial review).
    func testARegistrationStillLoadingWhenTurnedOffArmsNothing() async throws {
        let spy = SchedulerSpy()
        let weather = GatedSwitchWeather()
        let model = makeSwitchViewModel(spy: spy, weather: weather)
        let evaluating = Task { await model.evaluateRouteAndScheduleAlarm() }
        await weather.waitUntilStarted()
        let turningOff = Task { await model.turnAlarmOff() }
        try await Task.sleep(for: .milliseconds(100))
        await weather.release()
        await evaluating.value
        await turningOff.value
        XCTAssertTrue(spy.scheduleCalls.isEmpty, "Nothing may be armed after the switch went off")
        XCTAssertFalse(model.hasScheduledAlarm)
    }

    /// The app was suspended before a turn-off finished: the stored registration survived.
    /// A background run must finish removing it instead of leaving the alarm armed.
    func testABackgroundRunFinishesAnInterruptedTurnOff() async throws {
        let spy = SchedulerSpy()
        let first = makeSwitchViewModel(spy: spy)
        await first.evaluateRouteAndScheduleAlarm()
        XCTAssertTrue(first.hasScheduledAlarm)
        // Simulate the interruption: "off" persisted, the removal never ran.
        var stored = try JSONDecoder().decode(CommuteAlarmSettings.self,
                                              from: XCTUnwrap(storage.data(forKey: "commuteAlarmSettings")))
        stored.isAlarmEnabled = false
        storage.set(try JSONEncoder().encode(stored), forKey: "commuteAlarmSettings")
        let relaunched = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: spy,
                                        settingsStorage: storage, autoRefreshDebounce: .milliseconds(80))
        XCTAssertTrue(relaunched.hasScheduledAlarm)
        let cancelled = spy.cancelCount
        let rescheduled = await relaunched.refreshScheduledAlarmUnattended()
        XCTAssertFalse(rescheduled)
        XCTAssertFalse(relaunched.hasScheduledAlarm)
        XCTAssertGreaterThan(spy.cancelCount, cancelled)
    }

    func testAlarmsLeftBehindAfterTurningOffAreReportedAndRetried() async throws {
        final class Holds { var value = true }
        let holds = Holds()
        let spy = SchedulerSpy()
        let model = makeSwitchViewModel(spy: spy, holdsAlarms: { holds.value })
        await model.evaluateRouteAndScheduleAlarm()
        await model.turnAlarmOff()
        XCTAssertEqual(model.scheduleErrorMessage, String(localized: "alarm_off_failed"))
        holds.value = false
        await model.turnAlarmOff()
        XCTAssertNil(model.scheduleErrorMessage)
    }

    // MARK: - Inside this morning's check window (adversarial review, 2026-09-29)

    /// Relaunches onto a weekly registration for a morning ~10 minutes away whose rain check
    /// point (30 minutes before it) has passed — the user opened the app inside the window.
    /// `rangEarly`: that morning was rainy and its early ring already went off.
    private func relaunchInsideThisMorningsWindow(spy: SchedulerSpy, home: String, rangEarly: Bool,
                                                   previews: EveningPreviewScheduling = UserNotificationEveningPreviewScheduler(),
                                                   previewTime: Date? = nil) throws -> (model: AlarmViewModel, normal: Date) {
        let now = Date()
        var settings = CommuteAlarmSettings()
        settings.homeAddress = home
        settings.workAddress = "Work Street 2"
        settings.alarmTime = now.addingTimeInterval(10 * 60)
        settings.rainLeadTimeMinutes = 30
        if let previewTime { settings.eveningPreviewTime = previewTime }
        let normal = TomorrowWeatherRequest(settings: settings, now: now).normalAlarmDate
        let early = normal.addingTimeInterval(-30 * 60)
        try XCTSkipUnless(Calendar.current.isDate(early, inSameDayAs: normal) && Calendar.current.isDate(now, inSameDayAs: normal),
                          "The window must sit inside one calendar day")
        let summary = ScheduledAlarmSummary(normalAlarmDate: normal, scheduledAlarmDate: rangEarly ? early : normal,
            weatherRefreshDate: early, exceedsRainThreshold: rangEarly, leadTimeMinutes: rangEarly ? 30 : 0,
            rainProbabilityThreshold: 0.5, maximumPrecipitationProbability: rangEarly ? 0.72 : 0.08)
        storage.set(try JSONEncoder().encode(settings), forKey: "commuteAlarmSettings")
        storage.set(try JSONEncoder().encode(summary), forKey: "scheduledAlarmSummaryDisplay")
        storage.set(try JSONEncoder().encode(settings.scheduleFingerprint()), forKey: "scheduledAlarmFingerprint")
        let model = AlarmViewModel(routeWeatherService: MockRouteWeatherService(), notificationScheduler: spy,
                                   previewScheduler: previews, settingsStorage: storage, autoRefreshDebounce: .milliseconds(80))
        return (model, normal)
    }

    /// A foreground run inside the window (an edit, Retry, the debounced refresh) decided
    /// *tomorrow*, whose check point is the next one ahead, and moved the single weekly
    /// repeating alarm to tomorrow's time. A rainy tomorrow took this morning's ring with it.
    func testAnEditInsideThisMorningsWindowKeepsThisMorningsRing() async throws {
        let spy = SchedulerSpy()
        let (model, normal) = try relaunchInsideThisMorningsWindow(spy: spy, home: "Rain Street", rangEarly: false)
        model.settings.alarmSound = .softPiano
        try await waitUntil("the edit re-registered") { spy.scheduleCalls.count == 1 && !model.isScheduling }
        var call = try XCTUnwrap(spy.scheduleCalls.last)
        XCTAssertEqual(call.date, normal, "A rainy tomorrow must not take this morning's ring")
        XCTAssertEqual(call.normalAlarmDate, normal)
        XCTAssertEqual(call.sound, .softPiano, "The edit itself still applies")
        XCTAssertFalse(model.isScheduleStale)

        await model.evaluateRouteAndScheduleAlarm()
        call = try XCTUnwrap(spy.scheduleCalls.last)
        XCTAssertEqual(spy.scheduleCalls.count, 2)
        XCTAssertEqual(call.date, normal, "Retry keeps it too")
    }

    /// The same window after this morning already rang early: a dry tomorrow puts the
    /// weekly alarm back at the normal time, which rang this morning a second time.
    func testARunAfterThisMorningsEarlyRingDoesNotRingItAgain() async throws {
        let spy = SchedulerSpy()
        let (model, normal) = try relaunchInsideThisMorningsWindow(spy: spy, home: "Clear Street", rangEarly: true)
        await model.evaluateRouteAndScheduleAlarm()
        let call = try XCTUnwrap(spy.scheduleCalls.last)
        let early = normal.addingTimeInterval(-30 * 60)
        XCTAssertEqual(call.date, early, "The weekly clock stays on the ring that already went off")
        XCTAssertEqual(call.normalAlarmDate, normal)
        XCTAssertEqual(model.scheduledAlarmSummary?.normalAlarmDate, normal)
        let status = model.tomorrowStatus()
        XCTAssertTrue(status.hasRung)
        XCTAssertEqual(status.registeredRingDate, early)

        // A shorter lead puts this morning's check point back ahead; it still rang already.
        model.settings.rainLeadTimeMinutes = 5
        try await waitUntil("the edit re-registered") { spy.scheduleCalls.count == 2 && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.last?.date, early, "A morning that rang early never rings again")
    }

    /// The same edit, read back (adversarial review, 2026-10-01): woken at 07:00 for a 07:30
    /// alarm, the user shortens the lead. The weekly alarm stays on 07:00 and records it; the
    /// card must say 已響鈴 07:00, and tomorrow — which the weekly repeat rings at 07:00 again —
    /// must show that time waiting for its own forecast (D-D), not 07:30 with a
    /// 鬧鐘設定尚未更新完成 that no retry can clear before this morning's normal time.
    func testChangingTheLeadAfterThisMorningsEarlyRingKeepsWhatAlarmKitRings() async throws {
        let spy = SchedulerSpy()
        let (model, normal) = try relaunchInsideThisMorningsWindow(spy: spy, home: "Clear Street", rangEarly: true)
        let calendar = AlarmCalendarSettings.calendar
        let early = normal.addingTimeInterval(-30 * 60)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: normal))
        let tomorrowEarly = tomorrow.addingTimeInterval(-30 * 60)

        model.settings.rainLeadTimeMinutes = 5
        try await waitUntil("the edit re-registered") { spy.scheduleCalls.count == 1 && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.last?.date, early, "The weekly clock stays on the ring that already went off")
        XCTAssertEqual(model.scheduledAlarmSummary?.firedEarlyRing, .init(normalDate: normal, ringDate: early))
        XCTAssertFalse(model.isScheduleStale)
        XCTAssertNil(model.scheduleErrorMessage)

        // The card: this morning rang at the recorded 07:00, whatever the lead is now.
        let now = Date()
        let card = model.tomorrowStatus(now: now)
        XCTAssertEqual(card.normalAlarmDate, normal)
        XCTAssertTrue(card.hasRung)
        XCTAssertEqual(card.expectedRingDate, early)
        XCTAssertEqual(card.leadTimeMinutes, 30)
        XCTAssertNil(TomorrowWidgetSnapshotBuilder.scheduleIssue(for: card, flags: .init()))

        // The widget: today ended at that ring; tomorrow shows the 07:00 AlarmKit will ring.
        XCTAssertEqual(model.todayStatus(now: now).passedRingDate, early)
        let entry = try XCTUnwrap(TomorrowWidgetSnapshotBuilder.snapshot(for: model, now: now).entries.first)
        XCTAssertFalse(entry.isToday)
        XCTAssertEqual(entry.day, calendar.startOfDay(for: tomorrow))
        XCTAssertEqual(entry.expectedRingDate, tomorrowEarly, "The weekly repeat carries the 07:00 to tomorrow")
        XCTAssertEqual(entry.reasonLine, .awaitingForecast)
        XCTAssertNotEqual(entry.scheduleIssue, .updateNeeded, "Nothing a retry could change before the normal time")

        // Past this morning's normal time the card moves on to tomorrow and says the same.
        let next = model.tomorrowStatus(now: normal.addingTimeInterval(60))
        XCTAssertEqual(next.normalAlarmDate, tomorrow)
        XCTAssertEqual(next.expectedRingDate, tomorrowEarly)
        XCTAssertTrue(next.rainLeadIsCarriedOver)
        XCTAssertNil(TomorrowWidgetSnapshotBuilder.scheduleIssue(for: next, flags: .init()))
    }

    /// Adversarial review, 2026-10-01: the kept ring reads as carried over only until that
    /// morning's own check point under the current lead. Raised from 30 to 60 minutes after the
    /// 07:00 early ring, tomorrow's check point (06:30) comes before the kept 07:00. From then on
    /// nothing re-decides tomorrow, a retry would register 07:30, and 07:00 is a registration the
    /// settings no longer describe: flagged, not "waiting for tomorrow's forecast".
    func testRaisingTheLeadAfterThisMorningsEarlyRingFlagsTheKeptRingOnceItsCheckPointPasses() async throws {
        let spy = SchedulerSpy()
        let (model, normal) = try relaunchInsideThisMorningsWindow(spy: spy, home: "Clear Street", rangEarly: true)
        let calendar = AlarmCalendarSettings.calendar
        let early = normal.addingTimeInterval(-30 * 60)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: normal))
        let tomorrowEarly = tomorrow.addingTimeInterval(-30 * 60)
        let tomorrowCheckPoint = tomorrow.addingTimeInterval(-60 * 60)
        try XCTSkipUnless(calendar.isDate(tomorrowCheckPoint, inSameDayAs: tomorrow),
                          "Tomorrow's window must sit inside one calendar day")

        model.settings.rainLeadTimeMinutes = 60
        try await waitUntil("the edit re-registered") { spy.scheduleCalls.count == 1 && !model.isScheduling }
        XCTAssertEqual(spy.scheduleCalls.last?.date, early, "The weekly clock stays on the ring that already went off")

        // Until tomorrow's check point the kept 07:00 is what AlarmKit rings, awaiting its forecast.
        let evening = model.tomorrowStatus(now: normal.addingTimeInterval(60))
        XCTAssertEqual(evening.normalAlarmDate, tomorrow)
        XCTAssertEqual(evening.expectedRingDate, tomorrowEarly)
        XCTAssertTrue(evening.rainLeadIsCarriedOver)

        // 06:35 tomorrow: its 06:30 check point has passed, the kept 07:00 has not.
        let now = tomorrowCheckPoint.addingTimeInterval(5 * 60)
        let card = model.tomorrowStatus(now: now)
        XCTAssertEqual(card.normalAlarmDate, tomorrow)
        XCTAssertEqual(card.expectedRingDate, tomorrow, "Past its check point the kept lead is not this morning's")
        XCTAssertEqual(card.registeredRingDate, tomorrowEarly)
        XCTAssertFalse(card.rainLeadIsCarriedOver)
        XCTAssertNotEqual(TomorrowWidgetSnapshotBuilder.reasonLine(for: card), .awaitingForecast)
        XCTAssertEqual(TomorrowWidgetSnapshotBuilder.scheduleIssue(for: card, flags: .init()), .updateNeeded)

        // The widget's today entry shows the ring AlarmKit will fire, flagged, as it shows an
        // outdated registration's.
        let entry = try XCTUnwrap(TomorrowWidgetSnapshotBuilder.snapshot(for: model, now: now).entries.first)
        XCTAssertTrue(entry.isToday)
        XCTAssertEqual(entry.expectedRingDate, tomorrowEarly)
        XCTAssertNotEqual(entry.reasonLine, .awaitingForecast)
        XCTAssertEqual(entry.scheduleIssue, .updateNeeded)
    }

    /// Adversarial review, 2026-10-01: the previews that edit re-planned read the summary one
    /// date at a time, so tomorrow was not the armed ring and its preview named 07:30 while the
    /// card, the widget and AlarmKit said 07:00. They read it as the card does now (D-D).
    func testThePreviewPlannedAfterTheEarlyRingNamesTheRingCarriedToTomorrow() async throws {
        let spy = SchedulerSpy()
        let previews = PreviewCapture()
        let now = Date()
        // Tomorrow's preview fires this evening; put it just after this morning's normal time.
        let previewTime = now.addingTimeInterval(20 * 60)
        try XCTSkipUnless(Calendar.current.isDate(previewTime, inSameDayAs: now), "The preview must fire today")
        let (model, normal) = try relaunchInsideThisMorningsWindow(spy: spy, home: "Clear Street", rangEarly: true,
                                                                  previews: previews, previewTime: previewTime)
        let calendar = AlarmCalendarSettings.calendar
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: normal))

        model.settings.rainLeadTimeMinutes = 5
        try await waitUntil("the edit re-registered") { spy.scheduleCalls.count == 1 && !model.isScheduling }
        let identifier = EveningPreviewPlanner.identifier(forAlarmOn: tomorrow, calendar: calendar)
        let preview = try XCTUnwrap(previews.previews.first { $0.identifier == identifier })
        XCTAssertEqual(preview.kind, .upcoming(normalAlarmDate: tomorrow.addingTimeInterval(-30 * 60)),
                       "The preview names the 07:00 the weekly repeat rings, as the card and widget do")
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
    private var storedRetireCount = 0
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

    /// Removals that leave an alarm in progress to finish (the alarm stays on).
    var retireCount: Int {
        lock.withLock { storedRetireCount }
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

    func retireScheduledAlarms() async {
        lock.withLock {
            storedRetireCount += 1
        }
    }
}

@MainActor
private struct AutomaticRoutePreview: RoutePreviewService {
    static let home = ResolvedMapLocation(latitude: 25.03, longitude: 121.56,
        displayAddress: "Home Street 1", resolution: .exact)
    static let work = ResolvedMapLocation(latitude: 25.05, longitude: 121.52,
        displayAddress: "Work Street 2", resolution: .exact)
    /// Typed text → the name Apple reports; unlisted text comes back unchanged.
    var resolvedNames: [String: String] = [:]
    var resolution: AddressResolution = .exact

    func previewRoute(from homeAddress: String, homeLocation: ResolvedMapLocation?,
        to workAddress: String, workLocation: ResolvedMapLocation?,
        mode: CommuteAlarmSettings.CommuteMode) async throws -> RoutePreview {
        var home = homeLocation ?? Self.home
        var work = workLocation ?? Self.work
        home.displayAddress = resolvedNames[homeAddress] ?? homeAddress
        work.displayAddress = resolvedNames[workAddress] ?? workAddress
        if homeLocation == nil { home.resolution = resolution }
        if workLocation == nil { work.resolution = resolution }
        return RoutePreview(homeCoordinate: home.coordinate, workCoordinate: work.coordinate,
            homeLocation: home, workLocation: work, route: nil)
    }
}

/// Authorized, and keeps the previews last planned.
private final class PreviewCapture: EveningPreviewScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [EveningPreview] = []
    var previews: [EveningPreview] { lock.withLock { stored } }
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async { lock.withLock { stored = previews } }
    func cancelPreviews() async { lock.withLock { stored = [] } }
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

private struct AutomaticPreviewScheduler: EveningPreviewScheduling {
    func authorizationStatus() async -> EveningPreviewAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func replacePreviews(_ previews: [EveningPreview]) async {}
    func cancelPreviews() async {}
    func showSample(_ preview: EveningPreview) async {}
    func notifyDecisionChange(_ change: AlarmDecisionChange) async {}
}

private struct OfflineSwitchWeather: RouteWeatherService {
    func fetchRouteWeather(from homeAddress: String, homeLocation: ResolvedMapLocation?, to workAddress: String,
                           workLocation: ResolvedMapLocation?, mode: CommuteAlarmSettings.CommuteMode,
                           around commuteTime: Date) async throws -> RouteWeatherSnapshot {
        throw URLError(.notConnectedToInternet)
    }
}

private actor GatedSwitchWeather: RouteWeatherService {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func fetchRouteWeather(from homeAddress: String, homeLocation: ResolvedMapLocation?, to workAddress: String,
                           workLocation: ResolvedMapLocation?, mode: CommuteAlarmSettings.CommuteMode,
                           around commuteTime: Date) async throws -> RouteWeatherSnapshot {
        started = true
        startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { gate = $0 }
        return .init(checkedAt: Date(), forecastAt: commuteTime,
                     segments: [.init(name: "Home", condition: .clear, precipitationProbability: 0.1)])
    }
}
