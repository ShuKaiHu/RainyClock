import Foundation
import UIKit

enum CommuteAddressField: Hashable {
    case home
    case work
}

struct SuggestedAddressMatch: Equatable {
    var originalInput: String
    var suggestedAddress: String
    var isConfirmed: Bool
}

@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var settings: CommuteAlarmSettings {
        didSet {
            if oldValue.homeAddress != settings.homeAddress {
                invalidAddressFields.remove(.home)
                clearSuggestedAddressIfInputChanged(.home, input: settings.homeAddress)
                if suggestionSelectedInputs[.home] != settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines) {
                    settings.homeResolvedLocation = nil
                }
            }
            if oldValue.workAddress != settings.workAddress {
                invalidAddressFields.remove(.work)
                clearSuggestedAddressIfInputChanged(.work, input: settings.workAddress)
                if suggestionSelectedInputs[.work] != settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines) {
                    settings.workResolvedLocation = nil
                }
            }
            saveSettings()
            updateScheduleStaleness()
            reconcileScheduledAlarmWithSettings()
            if oldValue.isEveningPreviewEnabled != settings.isEveningPreviewEnabled
                || oldValue.eveningPreviewTime != settings.eveningPreviewTime {
                Task {
                    await replanEveningPreviews(requestingAuthorization: settings.isEveningPreviewEnabled)
                }
            }
        }
    }
    @Published private(set) var routeWeatherSnapshot: RouteWeatherSnapshot?
    @Published private(set) var routePreview: RoutePreview?
    @Published private(set) var scheduledAlarmSummary: ScheduledAlarmSummary? {
        didSet {
            saveScheduledAlarmSummary()
        }
    }
    @Published private(set) var statusMessage = String(localized: "status_enter_settings")
    @Published private(set) var routePreviewStatusMessage = String(localized: "route_preview_empty")
    @Published private(set) var routeWeatherStatusMessage = String(localized: "route_weather_empty")
    @Published private(set) var isScheduling = false
    @Published private(set) var isPreviewingRoute = false
    @Published private(set) var isRefreshingRouteWeather = false
    @Published private(set) var invalidAddressFields: Set<CommuteAddressField> = []
    @Published private(set) var suggestedAddressMatches: [CommuteAddressField: SuggestedAddressMatch] = [:]
    /// True when schedule-relevant settings changed after the last successful
    /// scheduling, so the registered alarm no longer matches the visible settings.
    @Published private(set) var isScheduleStale = false
    /// True on iOS 26 when the alarm still runs on the pre-26 notification path,
    /// which cannot pierce silent mode. Rescheduling once hands it to AlarmKit.
    @Published private(set) var requiresAlarmKitReschedule = false

    private let routeWeatherService: RouteWeatherService
    private let routePreviewService: RoutePreviewService
    private let notificationScheduler: NotificationScheduling
    private let previewScheduler: EveningPreviewScheduling
    /// Whether a background refresh can run on this phone right now. Injected
    /// so tests can plan both kinds of preview without touching UIKit state.
    private let canRefreshInBackground: @MainActor () -> Bool
    private let settingsStorage: UserDefaults
    private var suggestionSelectedInputs: [CommuteAddressField: String] = [:]
    private var previewGeneration = 0
    private var weatherGeneration = 0
    private var scheduledFingerprint: AlarmScheduleFingerprint? {
        didSet {
            saveScheduledFingerprint()
        }
    }
    /// When the rain decision behind the armed alarm was last computed. The alarm
    /// itself repeats weekly, so this is what says whether that decision still
    /// describes the weather — see `refreshScheduledAlarmIfWeatherIsStale()`.
    private var lastWeatherEvaluationAt: Date? {
        didSet {
            if let lastWeatherEvaluationAt {
                settingsStorage.set(lastWeatherEvaluationAt, forKey: Self.lastEvaluationStorageKey)
            } else {
                settingsStorage.removeObject(forKey: Self.lastEvaluationStorageKey)
            }
        }
    }
    private var autoRefreshTask: Task<Void, Never>?
    /// True while a run nobody asked for is in flight — a background task, or a launch
    /// that found the rain decision stale. Such a run must not repaint the status line
    /// or flag addresses the user typed correctly.
    private var isRunningUnattended = false
    private let autoRefreshDebounce: Duration
    private static let addressValidationTimeout: Duration = .seconds(4)
    private static let settingsStorageKey = "commuteAlarmSettings"
    private static let scheduledSummaryStorageKey = "scheduledAlarmSummaryDisplay"
    private static let scheduledFingerprintStorageKey = "scheduledAlarmFingerprint"
    private static let lastEvaluationStorageKey = "lastWeatherEvaluationAt"
    /// How stale the rain decision may get before opening the app re-runs it. Short
    /// enough that an evening or overnight launch re-decides tomorrow's alarm, long
    /// enough that flicking between apps does not refetch the forecast every time.
    private static let weatherDecisionLifetime: TimeInterval = 4 * 60 * 60

    init(
        routeWeatherService: RouteWeatherService = MockRouteWeatherService(),
        routePreviewService: RoutePreviewService = MapKitRoutePreviewService(),
        notificationScheduler: NotificationScheduling = SystemAlarmScheduler(),
        previewScheduler: EveningPreviewScheduling = UserNotificationEveningPreviewScheduler(),
        canRefreshInBackground: @escaping @MainActor () -> Bool = AlarmViewModel.systemCanRefreshInBackground,
        settingsStorage: UserDefaults = .standard,
        autoRefreshDebounce: Duration = .seconds(1.5)
    ) {
        self.autoRefreshDebounce = autoRefreshDebounce
        self.settings = Self.loadSettings(from: settingsStorage) ?? CommuteAlarmSettings()
        self.routeWeatherService = routeWeatherService
        self.routePreviewService = routePreviewService
        self.notificationScheduler = notificationScheduler
        self.previewScheduler = previewScheduler
        self.canRefreshInBackground = canRefreshInBackground
        self.settingsStorage = settingsStorage

        // Restore state that survives relaunches, so a scheduled alarm and confirmed
        // addresses do not look reset every time the app reopens.
        if let confirmedHome = settings.confirmedHomeAddressInput {
            suggestionSelectedInputs[.home] = confirmedHome
        }
        if let confirmedWork = settings.confirmedWorkAddressInput {
            suggestionSelectedInputs[.work] = confirmedWork
        }
        if let storedSummary = Self.loadScheduledAlarmSummary(from: settingsStorage) {
            scheduledAlarmSummary = storedSummary.rollingForward(selectedWeekdays: settings.selectedWeekdays)
            statusMessage = String(localized: "status_alarm_scheduled")
        }
        scheduledFingerprint = Self.loadScheduledFingerprint(from: settingsStorage)
        lastWeatherEvaluationAt = settingsStorage.object(forKey: Self.lastEvaluationStorageKey) as? Date
        updateScheduleStaleness()
        updateAlarmKitRescheduleNotice()
    }

    /// Re-decides the armed alarm against current weather when the stored decision has
    /// aged out. This is the "user opened the app" path; `BackgroundWeatherRefresh` is
    /// the one that covers the mornings they do not.
    func refreshScheduledAlarmIfWeatherIsStale() async {
        // A settings edit already queued its own re-registration; let that one win.
        guard autoRefreshTask == nil, !isRefreshingRouteWeather else {
            return
        }

        if let lastWeatherEvaluationAt,
           Date().timeIntervalSince(lastWeatherEvaluationAt) < Self.weatherDecisionLifetime {
            return
        }

        _ = await refreshScheduledAlarmUnattended()
    }

    /// Re-decides the armed alarm without touching anything the user is looking at.
    ///
    /// Both scheduling paths register a *weekly repeating* alarm at whatever time the
    /// rain check produced when it ran, so an alarm armed on a rainy Monday would keep
    /// ringing early every week and one armed on a dry day would never move. Bringing
    /// that decision up to date on each selected weekday is the whole product, and it
    /// has to happen without a person present — from a background task, or from a
    /// launch that the user did not make for this purpose.
    ///
    /// Silent by construction: failures leave the previously registered alarm armed
    /// and unchanged, and an unprompted run must not repaint the status line or mark
    /// correctly typed addresses as invalid on the way past.
    ///
    /// - Returns: whether the alarm was actually re-registered.
    @discardableResult
    func refreshScheduledAlarmUnattended() async -> Bool {
        guard hasScheduledAlarm, canSchedule, !isScheduling else {
            return false
        }

        let evaluationsBefore = lastWeatherEvaluationAt
        isRunningUnattended = true
        defer { isRunningUnattended = false }

        await evaluateRouteAndScheduleAlarm()
        return lastWeatherEvaluationAt != evaluationsBefore
    }

    /// An install that upgraded to iOS 26 keeps ringing through the old notification
    /// alarms until the user reschedules once — correct (no gap), but it silently
    /// misses the whole point of this release, so say so.
    func updateAlarmKitRescheduleNotice() {
        guard #available(iOS 26.0, *) else {
            requiresAlarmKitReschedule = false
            return
        }

        let needsReschedule = LocalNotificationScheduler.hasScheduledAlarmPlan
            && AlarmKitScheduler.scheduledAlarmIdentifiers().isEmpty
        if needsReschedule != requiresAlarmKitReschedule {
            requiresAlarmKitReschedule = needsReschedule
        }
    }

    private func updateScheduleStaleness() {
        guard scheduledAlarmSummary != nil, let scheduledFingerprint else {
            isScheduleStale = false
            return
        }

        let isStale = settings.scheduleFingerprint() != scheduledFingerprint
        if isStale != isScheduleStale {
            isScheduleStale = isStale
        }
    }

    var hasScheduledAlarm: Bool {
        scheduledAlarmSummary != nil
    }

    /// Keeps the registered alarm in lockstep with the visible settings. Parameter
    /// changes (weekdays, time, lead time, threshold, sound, snooze) re-schedule
    /// automatically after a short debounce; address changes instead drop the alarm
    /// entirely, because an alarm for a route the user has not confirmed yet should
    /// never ring — they re-arm it with the schedule button.
    private func reconcileScheduledAlarmWithSettings() {
        guard scheduledAlarmSummary != nil, let scheduledFingerprint else {
            return
        }

        let current = settings.scheduleFingerprint()
        guard current != scheduledFingerprint else {
            // Settings changed and changed back before the debounce fired.
            autoRefreshTask?.cancel()
            return
        }

        if current.homeAddress != scheduledFingerprint.homeAddress
            || current.workAddress != scheduledFingerprint.workAddress {
            autoRefreshTask?.cancel()
            Task {
                await removeScheduledAlarm()
            }
        } else {
            scheduleAutoRefresh()
        }
    }

    /// Debounced so slider drags coalesce into one weather fetch + re-registration.
    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        let debounce = autoRefreshDebounce
        autoRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else {
                return
            }

            guard !self.isScheduling else {
                // A manual run is in flight; re-debounce and reconcile after it.
                self.scheduleAutoRefresh()
                return
            }
            guard self.canSchedule else {
                return
            }

            // Detach before running: evaluate cancels `autoRefreshTask` on entry
            // (to absorb queued debounces), and cancelling this task mid-flight
            // would abort its own weather fetch with a CancellationError.
            self.autoRefreshTask = nil
            await self.evaluateRouteAndScheduleAlarm()
        }
    }

    private func removeScheduledAlarm() async {
        autoRefreshTask?.cancel()
        await notificationScheduler.cancelScheduledAlarms()
        await previewScheduler.cancelPreviews()
        scheduledAlarmSummary = nil
        scheduledFingerprint = nil
        isScheduleStale = false
        statusMessage = String(localized: "status_alarm_removed_address_changed")
        updateAlarmKitRescheduleNotice()
    }

    var canSchedule: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.selectedWeekdays.isEmpty
            && settings.rainLeadTimeMinutes > 0
            && !hasUnconfirmedSuggestedAddresses
    }

    var canPreviewRoute: Bool {
        !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var requiresSuggestedAddressConfirmation: Bool {
        hasUnconfirmedSuggestedAddresses
    }

    func previewRoute() async {
        guard canPreviewRoute else {
            clearRoutePreview(message: String(localized: "route_preview_required"))
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        isPreviewingRoute = true
        routePreviewStatusMessage = String(localized: "previewing_route")
        defer {
            if generation == previewGeneration {
                isPreviewingRoute = false
            }
        }

        do {
            let preview = try await routePreviewService.previewRoute(
                from: settings.homeAddress,
                homeLocation: settings.homeResolvedLocation,
                to: settings.workAddress,
                workLocation: settings.workResolvedLocation,
                mode: settings.commuteMode
            )
            // A newer preview request (or a clear) supersedes this in-flight result.
            guard generation == previewGeneration else {
                return
            }
            routePreview = preview
            invalidAddressFields.removeAll()
            updateSuggestedAddressMatches(homeLocation: preview.homeLocation, workLocation: preview.workLocation)
            if let expectedTravelTimeMinutes = preview.expectedTravelTimeMinutes,
               let distanceKilometers = preview.distanceKilometers {
                routePreviewStatusMessage = String.localizedStringWithFormat(
                    String(localized: "route_preview_ready"),
                    preview.routeName,
                    expectedTravelTimeMinutes,
                    distanceKilometers
                )
            } else {
                routePreviewStatusMessage = String(localized: "route_preview_locations_only_message")
            }
        } catch {
            guard generation == previewGeneration else {
                return
            }
            routePreview = nil
            updateAddressValidation(for: error)
            routePreviewStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_preview_failed"),
                error.localizedDescription
            )
        }
    }

    func clearRoutePreview(message: String = String(localized: "route_preview_empty")) {
        previewGeneration += 1
        isPreviewingRoute = false
        routePreview = nil
        routePreviewStatusMessage = message
    }

    func confirmSuggestedAddress(_ field: CommuteAddressField) {
        guard let match = suggestedAddressMatches[field] else {
            return
        }

        let actualAddress = match.suggestedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actualAddress.isEmpty else {
            return
        }

        setSuggestionSelectedInput(actualAddress, for: field)
        switch field {
        case .home:
            settings.homeAddress = actualAddress
            settings.homeResolvedLocation = nil
        case .work:
            settings.workAddress = actualAddress
            settings.workResolvedLocation = nil
        }
        suggestedAddressMatches.removeValue(forKey: field)
        invalidAddressFields.remove(field)
    }

    func clearAddressState(_ field: CommuteAddressField) {
        invalidAddressFields.remove(field)
        suggestedAddressMatches.removeValue(forKey: field)
        setSuggestionSelectedInput(nil, for: field)
        switch field {
        case .home:
            settings.homeResolvedLocation = nil
        case .work:
            settings.workResolvedLocation = nil
        }
    }

    func setAddressFromSuggestion(_ address: String, location: ResolvedMapLocation?, field: CommuteAddressField) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        setSuggestionSelectedInput(trimmedAddress, for: field)

        switch field {
        case .home:
            settings.homeAddress = address
            settings.homeResolvedLocation = location
        case .work:
            settings.workAddress = address
            settings.workResolvedLocation = location
        }
    }

    func refreshRouteWeather() async {
        guard canPreviewRoute else {
            clearRouteWeather(message: String(localized: "route_weather_empty"))
            return
        }

        weatherGeneration += 1
        let generation = weatherGeneration
        isRefreshingRouteWeather = true
        routeWeatherStatusMessage = String(localized: "route_weather_refreshing")
        defer {
            if generation == weatherGeneration {
                isRefreshingRouteWeather = false
            }
        }

        do {
            let now = Date()
            let snapshot = try await routeWeatherService.fetchRouteWeather(
                from: settings.homeAddress,
                homeLocation: settings.homeResolvedLocation,
                to: settings.workAddress,
                workLocation: settings.workResolvedLocation,
                mode: settings.commuteMode,
                around: nextWeatherCheckDate(for: settings, now: now)
            )
            // A newer refresh (or a clear) supersedes this in-flight result.
            guard generation == weatherGeneration else {
                return
            }
            routeWeatherSnapshot = snapshot
            invalidAddressFields.removeAll()
            let forecastAt = snapshot.forecastAt.formatted(date: .abbreviated, time: .shortened)
            routeWeatherStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_weather_updated"),
                forecastAt,
                snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
            )
        } catch {
            guard generation == weatherGeneration else {
                return
            }
            routeWeatherSnapshot = nil
            updateAddressValidation(for: error)
            routeWeatherStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_weather_failed"),
                Self.userFacingMessage(for: error)
            )
        }
    }

    func clearRouteWeather(message: String = String(localized: "route_weather_empty")) {
        weatherGeneration += 1
        isRefreshingRouteWeather = false
        routeWeatherSnapshot = nil
        routeWeatherStatusMessage = message
    }

    /// Invalidates an in-flight preview request so its late result cannot land while a
    /// replacement request is still in its debounce delay.
    func supersedeRoutePreview() {
        previewGeneration += 1
    }

    /// Invalidates an in-flight weather refresh so its late result cannot land while a
    /// replacement request is still in its debounce delay.
    func supersedeRouteWeather() {
        weatherGeneration += 1
    }

    func evaluateRouteAndScheduleAlarm() async {
        guard canSchedule else {
            statusMessage = hasUnconfirmedSuggestedAddresses
                ? String(localized: "status_confirm_suggested_address")
                : String(localized: "status_required")
            return
        }

        isScheduling = true
        // This run IS the refresh; a queued debounce would only duplicate it.
        autoRefreshTask?.cancel()
        defer { isScheduling = false }

        // Freeze the settings for the whole flow: the user can keep moving sliders
        // while the weather fetch is in flight, and the registered alarm must match
        // ONE consistent set of values — the fingerprint saved below. Drift that
        // happens mid-flight is caught by reconcile at the end.
        let settingsSnapshot = settings

        do {
            let authorized = try await notificationScheduler.requestAuthorization()
            guard authorized else {
                // Same reasoning as the catch below: an unattended run says nothing.
                guard !isRunningUnattended else {
                    return
                }

                // iOS 26 asks for alarm permission, not notification permission, and
                // the system only prompts once — point at Settings either way.
                statusMessage = if #available(iOS 26.0, *) {
                    String(localized: "status_alarm_permission_denied")
                } else {
                    String(localized: "status_permission_denied")
                }
                return
            }

            // Scheduling supersedes any in-flight background weather refresh, and must
            // also clear the refresh spinner that refresh will no longer reset.
            weatherGeneration += 1
            let weatherFetchGeneration = weatherGeneration
            isRefreshingRouteWeather = false
            let now = Date()
            let weatherCheckDate = nextWeatherCheckDate(for: settingsSnapshot, now: now)
            let snapshot = try await routeWeatherService.fetchRouteWeather(
                from: settingsSnapshot.homeAddress,
                homeLocation: settingsSnapshot.homeResolvedLocation,
                to: settingsSnapshot.workAddress,
                workLocation: settingsSnapshot.workResolvedLocation,
                mode: settingsSnapshot.commuteMode,
                around: weatherCheckDate
            )
            if weatherFetchGeneration == weatherGeneration {
                routeWeatherSnapshot = snapshot
                invalidAddressFields.removeAll()
                routeWeatherStatusMessage = String.localizedStringWithFormat(
                    String(localized: "route_weather_updated"),
                    snapshot.forecastAt.formatted(date: .abbreviated, time: .shortened),
                    snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
                )
            }

            let exceedsThreshold = snapshot.exceedsRainThreshold(settingsSnapshot.rainProbabilityThreshold)
            let summary = AlarmTimeCalculator.nextAlarmDateForWeatherCheck(
                alarmTime: settingsSnapshot.alarmTime,
                leadTimeMinutes: settingsSnapshot.rainLeadTimeMinutes,
                shouldApplyLeadTime: exceedsThreshold,
                rainProbabilityThreshold: settingsSnapshot.rainProbabilityThreshold,
                maximumPrecipitationProbability: snapshot.maximumPrecipitationProbability,
                selectedWeekdays: settingsSnapshot.selectedWeekdays,
                now: now
            )

            let body = exceedsThreshold
                ? String(localized: "notification_body_adjusted")
                : String(localized: "notification_body_normal")

            try await notificationScheduler.scheduleAlarm(
                at: summary.scheduledAlarmDate,
                normalAlarmDate: summary.normalAlarmDate,
                weekdays: settingsSnapshot.selectedWeekdays,
                sound: settingsSnapshot.alarmSound,
                soundFileNameOverride: settingsSnapshot.soundFileNameOverride,
                snoozeMinutes: settingsSnapshot.effectiveSnoozeMinutes,
                title: String(localized: "notification_title"),
                body: body
            )
            // Everything below runs only once registration actually succeeded. The
            // summary is persisted and is what `hasScheduledAlarm` — the green "alarm
            // is set" state — reads, so publishing it before this point left a failed
            // run claiming an alarm that does not exist, and the failure message that
            // contradicted it did not survive a relaunch.
            scheduledAlarmSummary = summary
            lastWeatherEvaluationAt = now
            // The fingerprint describes what was actually registered — the frozen
            // snapshot — never the live settings, which may have moved on.
            scheduledFingerprint = settingsSnapshot.scheduleFingerprint()
            updateScheduleStaleness()
            updateAlarmKitRescheduleNotice()
            // Point the background budget at the next selected weekday's lead-time
            // point, so that morning's forecast — not this one — decides that alarm.
            // When this run *is* the one for the imminent occurrence, aim past it at
            // the following weekday instead, or the request would keep resubmitting
            // itself for a check point that has already been answered.
            let horizon = now.addingTimeInterval(BackgroundWeatherRefresh.refreshLeadTime)
            let nextCheckDate = summary.weatherRefreshDate > horizon
                ? summary.weatherRefreshDate
                : nextWeatherCheckDate(for: settingsSnapshot, now: summary.weatherRefreshDate.addingTimeInterval(60))
            BackgroundWeatherRefresh.scheduleNextRun(before: nextCheckDate, now: now)
            // The evening-before previews describe this registration, so they
            // are replaced here and nowhere else — a background refresh that
            // changes the decision changes tonight's notification with it.
            await replanEveningPreviews(requestingAuthorization: !isRunningUnattended, summary: summary, settings: settingsSnapshot, now: now)

            let checkedAt = snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
            let forecastAt = snapshot.forecastAt.formatted(date: .abbreviated, time: .shortened)
            let statusKey = exceedsThreshold ? "status_adjusted_checked" : "status_normal_checked"
            statusMessage = String.localizedStringWithFormat(String(localized: String.LocalizationValue(statusKey)), forecastAt, checkedAt)
        } catch {
            // An unattended run reports to nobody: the alarm registered by the last
            // successful run is still armed, so repainting the status line or marking
            // the addresses invalid would only be noise the user cannot act on.
            guard !isRunningUnattended else {
                updateScheduleStaleness()
                return
            }

            updateAddressValidation(for: error)
            statusMessage = String.localizedStringWithFormat(
                String(localized: "status_schedule_failed"),
                Self.userFacingMessage(for: error)
            )
            // Deliberately no reconcile pass on this path. The fingerprint still
            // describes the last alarm that registered, so drifted settings would
            // look like drift forever: reconcile schedules an auto-refresh, that run
            // fails the same way, and the two spin against each other every 1.5
            // seconds for as long as the failure lasts. The amber stale notice above
            // says the same thing and waits for the user.
            return
        }

        // Settings that drifted while this run was in flight get their own pass —
        // auto-refresh for parameter drift, removal for address drift.
        reconcileScheduledAlarmWithSettings()
    }

    private static func userFacingMessage(for error: Error) -> String {
        let description = error.localizedDescription
        let lowercasedDescription = description.lowercased()
        if lowercasedDescription.contains("weatherdaemon")
            || lowercasedDescription.contains("jwtauthenticator") {
            return String(localized: "error_weather_unavailable")
        }

        return description
    }

    private var hasUnconfirmedSuggestedAddresses: Bool {
        suggestedAddressMatches.values.contains { !$0.isConfirmed }
    }

    private func updateSuggestedAddressMatches(
        homeLocation: ResolvedMapLocation,
        workLocation: ResolvedMapLocation
    ) {
        updateSuggestedAddressMatch(.home, input: settings.homeAddress, location: homeLocation)
        updateSuggestedAddressMatch(.work, input: settings.workAddress, location: workLocation)
    }

    private func updateSuggestedAddressMatch(
        _ field: CommuteAddressField,
        input: String,
        location: ResolvedMapLocation
    ) {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // An input the user already picked from suggestions or explicitly confirmed
        // (persisted across relaunches) needs no re-confirmation banner.
        let wasSelectedFromSuggestions = suggestionSelectedInputs[field] == trimmedInput
        guard !wasSelectedFromSuggestions else {
            suggestedAddressMatches.removeValue(forKey: field)
            return
        }

        let suggestedAddress = location.displayAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestedAddressMatches[field] = SuggestedAddressMatch(
            originalInput: trimmedInput,
            suggestedAddress: suggestedAddress?.isEmpty == false ? suggestedAddress! : trimmedInput,
            isConfirmed: suggestedAddressMatches[field]?.originalInput == trimmedInput
                ? suggestedAddressMatches[field]?.isConfirmed ?? false
                : false
        )
    }

    private func clearSuggestedAddressIfInputChanged(_ field: CommuteAddressField, input: String) {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestedAddressMatches[field]?.originalInput != trimmedInput else {
            return
        }

        suggestedAddressMatches.removeValue(forKey: field)
        if suggestionSelectedInputs[field] != trimmedInput {
            setSuggestionSelectedInput(nil, for: field)
        }
    }

    private func setSuggestionSelectedInput(_ value: String?, for field: CommuteAddressField) {
        if let value {
            suggestionSelectedInputs[field] = value
        } else {
            suggestionSelectedInputs.removeValue(forKey: field)
        }

        switch field {
        case .home:
            settings.confirmedHomeAddressInput = value
        case .work:
            settings.confirmedWorkAddressInput = value
        }
    }

    private func updateAddressValidation(for error: Error) {
        guard let routeError = error as? MapKitRouteWeatherServiceError else {
            let description = error.localizedDescription.lowercased()
            if description.contains("route")
                || description.contains("directions")
                || description.contains("路線")
                || description.contains("路徑") {
                validateAddressesIndividuallyInBackground()
            }
            return
        }

        switch routeError {
        case .addressNotFound(let address):
            markAddressNotFound(address)
        case .routeNotFound:
            validateAddressesIndividuallyInBackground()
        }
    }

    private func validateAddressesIndividuallyInBackground() {
        Task { @MainActor in
            await validateAddressesIndividually()
        }
    }

    private func markAddressNotFound(_ address: String) {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedAddress == settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines) {
            invalidAddressFields.insert(.home)
        }
        if normalizedAddress == settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines) {
            invalidAddressFields.insert(.work)
        }
    }

    private func validateAddressesIndividually() async {
        async let homeResolved = canResolveAddress(settings.homeAddress)
        async let workResolved = canResolveAddress(settings.workAddress)

        var fields: Set<CommuteAddressField> = []
        if !(await homeResolved) {
            fields.insert(.home)
        }
        if !(await workResolved) {
            fields.insert(.work)
        }

        invalidAddressFields = fields
    }

    private func canResolveAddress(_ address: String) async -> Bool {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await MapItemResolver().canResolvePrecisely(trimmedAddress)
            }

            group.addTask {
                try? await Task.sleep(for: Self.addressValidationTimeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Background App Refresh switched off (Settings › General) or Low Power Mode:
    /// either one means `BackgroundWeatherRefresh` will not run, and the alarm keeps
    /// whatever decision the last foreground run made. The preview is where the
    /// person is told.
    static func systemCanRefreshInBackground() -> Bool {
        UIApplication.shared.backgroundRefreshStatus == .available
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Asks for notification permission on behalf of the previews when nothing
    /// else has — an install that upgraded with an alarm already armed never taps
    /// Schedule again, and on iOS 26 the alarm's own permission is AlarmKit's, not
    /// this one. Runs from the foreground only; the prompt needs a screen.
    func requestEveningPreviewAuthorizationIfNeeded() async {
        guard settings.isEveningPreviewEnabled, hasScheduledAlarm,
              await previewScheduler.authorizationStatus() == .notDetermined else {
            return
        }

        await replanEveningPreviews(requestingAuthorization: true)
    }

    /// Sends a sample preview a few seconds from now so the person can see what
    /// one looks like. Asks for permission first if nothing has; returns false
    /// when it is denied, so the button can say where to turn it on.
    func sendSampleEveningPreview() async -> Bool {
        var status = await previewScheduler.authorizationStatus()
        if status == .notDetermined {
            status = await previewScheduler.requestAuthorization() ? .authorized : .denied
        }
        guard status == .authorized else {
            return false
        }

        await previewScheduler.showSample(EveningPreviewPlanner.sample(
            settings: settings,
            now: Date(),
            canRefreshInBackground: canRefreshInBackground()
        ))
        return true
    }

    /// Re-plans the previews from the stored summary — the toggle flipping, or
    /// permission arriving after the alarm was registered.
    private func replanEveningPreviews(requestingAuthorization: Bool) async {
        guard let summary = scheduledAlarmSummary else {
            await previewScheduler.cancelPreviews()
            return
        }

        let now = Date()
        await replanEveningPreviews(
            requestingAuthorization: requestingAuthorization,
            summary: summary.rollingForward(selectedWeekdays: settings.selectedWeekdays, now: now),
            settings: settings,
            now: now
        )
    }

    private func replanEveningPreviews(
        requestingAuthorization: Bool,
        summary: ScheduledAlarmSummary,
        settings: CommuteAlarmSettings,
        now: Date
    ) async {
        guard settings.isEveningPreviewEnabled else {
            await previewScheduler.cancelPreviews()
            return
        }

        var status = await previewScheduler.authorizationStatus()
        if status == .notDetermined, requestingAuthorization {
            status = await previewScheduler.requestAuthorization() ? .authorized : .denied
        }
        guard status == .authorized else {
            return
        }

        let previews = EveningPreviewPlanner.plan(
            summary: summary,
            selectedWeekdays: settings.selectedWeekdays,
            previewTime: settings.eveningPreviewTime,
            checkedAt: lastWeatherEvaluationAt ?? now,
            now: now,
            canRefreshInBackground: canRefreshInBackground()
        )
        await previewScheduler.replacePreviews(previews)
    }

    private func nextWeatherCheckDate(for settings: CommuteAlarmSettings, now: Date = Date()) -> Date {
        AlarmTimeCalculator.nextAlarmDateForWeatherCheck(
            alarmTime: settings.alarmTime,
            leadTimeMinutes: settings.rainLeadTimeMinutes,
            shouldApplyLeadTime: false,
            rainProbabilityThreshold: settings.rainProbabilityThreshold,
            maximumPrecipitationProbability: 0,
            selectedWeekdays: settings.selectedWeekdays,
            now: now
        ).weatherRefreshDate
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        settingsStorage.set(data, forKey: Self.settingsStorageKey)
    }

    private func saveScheduledAlarmSummary() {
        guard let summary = scheduledAlarmSummary else {
            settingsStorage.removeObject(forKey: Self.scheduledSummaryStorageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(summary) else {
            return
        }

        settingsStorage.set(data, forKey: Self.scheduledSummaryStorageKey)
    }

    private static func loadScheduledAlarmSummary(from storage: UserDefaults) -> ScheduledAlarmSummary? {
        guard let data = storage.data(forKey: scheduledSummaryStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(ScheduledAlarmSummary.self, from: data)
    }

    private func saveScheduledFingerprint() {
        guard let fingerprint = scheduledFingerprint else {
            settingsStorage.removeObject(forKey: Self.scheduledFingerprintStorageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(fingerprint) else {
            return
        }

        settingsStorage.set(data, forKey: Self.scheduledFingerprintStorageKey)
    }

    private static func loadScheduledFingerprint(from storage: UserDefaults) -> AlarmScheduleFingerprint? {
        guard let data = storage.data(forKey: scheduledFingerprintStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(AlarmScheduleFingerprint.self, from: data)
    }

    private static func loadSettings(from storage: UserDefaults) -> CommuteAlarmSettings? {
        guard let data = storage.data(forKey: settingsStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(CommuteAlarmSettings.self, from: data)
    }
}
