import BackgroundTasks
import Foundation
import OSLog

/// Re-decides the armed alarm's rain adjustment while the app is closed.
///
/// Both scheduling paths register a *weekly repeating* alarm at whatever time the
/// rain check produced when it last ran, so without this the decision made on the
/// day the user pressed Schedule would keep applying every week. The product
/// contract is the opposite: on each selected weekday the forecast for *that*
/// morning decides whether the alarm moves earlier.
///
/// iOS never promises to run background work at a chosen minute, so this uses both
/// budgets available to an app with no server:
///
/// - a **refresh** task asked for shortly before the lead-time point, which the
///   system grants around the times the user habitually opens the app, and
/// - a **processing** task asked for the evening before, the window iOS is most
///   generous with because the phone is usually idle and charging overnight.
///
/// Whichever runs first brings the alarm current; opening the app is the third
/// path (`AlarmViewModel.refreshScheduledAlarmIfWeatherIsStale()`). A morning
/// where none of them ran still rings — on the previous decision, which is the
/// same behaviour as before this existed, never a missed alarm.
enum BackgroundWeatherRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
    static let refreshTaskIdentifier = "com.shukaihu.RainyClock.weatherRefresh"
    static let processingTaskIdentifier = "com.shukaihu.RainyClock.alarmMaintenance"
    /// A third window, opened shortly before the evening preview fires, so the
    /// text it carries can be re-decided on a forecast from that evening rather
    /// than from whenever the app was last opened.
    static let previewRefreshTaskIdentifier = "com.shukaihu.RainyClock.previewRefresh"
    static let previewRefreshLeadTime: TimeInterval = 30 * 60

    /// How far ahead of the lead-time point to start asking for the refresh task.
    /// The system treats `earliestBeginDate` as "not before", never "at", so this is
    /// the start of a window, not an appointment.
    static let refreshLeadTime: TimeInterval = 45 * 60
    /// How far ahead to ask for the overnight processing task — far enough back to
    /// land in the night before a morning alarm.
    private static let processingLeadTime: TimeInterval = 9 * 60 * 60

    private static let logger = Logger(subsystem: "com.shukaihu.RainyClock", category: "BackgroundRefresh")

    /// Registers both handlers. Must run before the app finishes launching, so it is
    /// called from `RainyClockApp.init()`.
    static func registerHandlers() {
        // Registration throws in test hosts and previews, where the identifiers are
        // not in the host's Info.plist. Nothing to do there.
        guard !AppEnvironment.isRunningTests else {
            return
        }

        for identifier in [refreshTaskIdentifier, processingTaskIdentifier, previewRefreshTaskIdentifier] {
            // `using: .main` pins the launch handler to the main queue; the box is
            // what carries the non-Sendable `BGTask` from there to the main actor.
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: .main
            ) { task in
                let delivered = DeliveredTask(task: task)
                Task { @MainActor in
                    handle(task: delivered.task)
                }
            }
            if !registered {
                logger.error("Could not register background task \(identifier, privacy: .public)")
            }
        }
    }

    /// Asks the system for both windows around `weatherRefreshDate` — the moment the
    /// next selected weekday's forecast should decide that morning's alarm.
    ///
    /// Safe to call repeatedly: submitting an identifier that is already pending
    /// replaces it, so re-arming after every successful scheduling keeps the request
    /// pointed at the next occurrence rather than a date that has passed.
    static func scheduleNextRun(before weatherRefreshDate: Date, now: Date = Date()) {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        submit(
            BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier),
            beginningAt: weatherRefreshDate.addingTimeInterval(-refreshLeadTime),
            now: now
        )

        let processing = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        // The point is to have an answer before the alarm, not to be cheap about it:
        // requiring external power would skip every user who does not charge nightly.
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        submit(
            processing,
            beginningAt: weatherRefreshDate.addingTimeInterval(-processingLeadTime),
            now: now
        )
    }

    /// Asks for a refresh window opening `previewRefreshLeadTime` before the first
    /// evening preview. Nothing to preview, or a window that has already opened
    /// (this run *is* that refresh), drops the request instead of resubmitting it
    /// for a moment that has passed — which would run again at once, re-plan,
    /// resubmit, and spin until the preview time went by.
    static func schedulePreviewRefresh(before fireDate: Date?, now: Date = Date()) {
        guard !AppEnvironment.isRunningTests else {
            return
        }

        guard let fireDate, fireDate.addingTimeInterval(-previewRefreshLeadTime) > now else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: previewRefreshTaskIdentifier)
            return
        }

        submit(
            BGAppRefreshTaskRequest(identifier: previewRefreshTaskIdentifier),
            beginningAt: fireDate.addingTimeInterval(-previewRefreshLeadTime),
            now: now
        )
    }

    static func cancelScheduledRuns() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: previewRefreshTaskIdentifier)
    }

    private static func submit(_ request: BGTaskRequest, beginningAt date: Date, now: Date) {
        // A window that already opened is submitted as "as soon as possible" rather
        // than dropped: a phone that was off all night should still catch up.
        request.earliestBeginDate = max(date, now.addingTimeInterval(60))

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskSchedulerErrorCodeUnavailable is normal — Background App Refresh
            // switched off, or a simulator. The in-app refresh still covers those.
            logger.notice("Background task \(request.identifier, privacy: .public) not submitted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `BGTask` is not `Sendable`, but the system hands each one to exactly one launch
    /// handler — on the queue registered above — and never touches it concurrently.
    /// This carries it to the main actor, where all of this app's scheduling lives.
    private struct DeliveredTask: @unchecked Sendable {
        let task: BGTask
    }

    @MainActor
    private static func handle(task: BGTask) {
        let work = Task { @MainActor in
            await CommuteAlarmRefresher.refreshArmedAlarm()
        }

        // The system reclaims the task if it runs long; cancelling here stops the
        // weather fetch instead of letting it be killed mid-registration.
        task.expirationHandler = {
            work.cancel()
        }

        Task { @MainActor in
            let outcome = await work.value
            // Re-arm before reporting completion, or the chain stops after one run.
            if let nextRefreshDate = outcome.nextWeatherRefreshDate {
                scheduleNextRun(before: nextRefreshDate)
            }
            logger.info("Background refresh finished, rescheduled: \(outcome.didReschedule, privacy: .public)")
            task.setTaskCompleted(success: outcome.didReschedule)
        }
    }
}

/// Runs the same evaluate-and-register flow the UI runs, with no UI attached.
///
/// Deliberately built on `AlarmViewModel` rather than a parallel implementation:
/// the rain decision, the fingerprint bookkeeping and the persisted state have to
/// stay identical whether they were produced in the foreground or at 5 a.m.
@MainActor
enum CommuteAlarmRefresher {
    struct Outcome {
        var didReschedule: Bool
        var nextWeatherRefreshDate: Date?
    }

    static func refreshArmedAlarm() async -> Outcome {
        let viewModel = AlarmViewModel(
            routeWeatherService: AppEnvironment.routeWeatherService,
            notificationScheduler: SystemAlarmScheduler()
        )

        guard viewModel.hasScheduledAlarm else {
            // Nothing armed: stop the chain instead of waking up forever.
            return Outcome(didReschedule: false, nextWeatherRefreshDate: nil)
        }

        let didReschedule = await viewModel.refreshScheduledAlarmUnattended()
        return Outcome(
            didReschedule: didReschedule,
            nextWeatherRefreshDate: viewModel.scheduledAlarmSummary?.weatherRefreshDate
        )
    }
}
