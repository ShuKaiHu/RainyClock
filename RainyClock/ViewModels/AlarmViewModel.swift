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

/// What "turn off only the next alarm" can offer at a given moment.
enum AlarmSkipAvailability: Equatable {
    /// The morning to skip (`normalDate`) and the ring the system holds for it (`ringDate`).
    case available(CalendarAlarmPlan.Occurrence)
    /// An alarm is ringing or snoozing; stop it first.
    case alarmInProgress
    case unavailable
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
                    settings.homeSuspensionRegion = nil
                }
            }
            if oldValue.workAddress != settings.workAddress {
                invalidAddressFields.remove(.work)
                clearSuggestedAddressIfInputChanged(.work, input: settings.workAddress)
                if suggestionSelectedInputs[.work] != settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines) {
                    settings.workResolvedLocation = nil
                    settings.workSuspensionRegion = nil
                }
            }
            synchronizeAutomaticSuspensionRegions()
            // One instant for both: two Date() calls straddling the morning's switch would
            // look like a settings change.
            let requestNow = Date()
            if TomorrowWeatherRequest(settings: oldValue, now: requestNow) != TomorrowWeatherRequest(settings: settings, now: requestNow) {
                tomorrowWeatherGeneration += 1
                activeTomorrowWeatherRequest = nil
                isRefreshingTomorrowWeather = false
            }
            if oldValue.isDisasterSuspensionEnabled != settings.isDisasterSuspensionEnabled {
                Task { await DisasterPushRegistration.shared.update(enabled: effectiveSchedulingSettings.isDisasterSuspensionEnabled) }
                Task { await refreshDisasterSuspensions(force: true) }
            }
            saveSettings()
            if oldValue.scheduleFingerprint() != effectiveSchedulingSettings.scheduleFingerprint() {
                lastAutomaticInitialAttempt = nil
            }
            updateScheduleStaleness()
            reconcileScheduledAlarmWithSettings()
            if oldValue.isEveningPreviewEnabled != settings.isEveningPreviewEnabled
                || oldValue.eveningPreviewTime != settings.eveningPreviewTime
                || oldValue.timeFormat != settings.timeFormat {
                Task {
                    await replanEveningPreviews(requestingAuthorization: settings.isEveningPreviewEnabled)
                }
            }
        }
    }
    @Published private(set) var disasterFeed: DisasterFeed?
    @Published private(set) var isRefreshingDisasters = false
    @Published private(set) var disasterRefreshFailed = false
    @Published private(set) var disasterScheduleNeedsAttention = false {
        didSet { settingsStorage.set(disasterScheduleNeedsAttention, forKey: "disasterScheduleNeedsAttention") }
    }
    @Published private(set) var disasterLastAttemptAt: Date?
    private let disasterFeedProvider: any DisasterFeedProviding
    private let disasterSyncReporter: any DisasterSyncReporting
    private var pendingDisasterUpdate = false
    private var disasterRefreshTask: Task<Bool, Never>?
    private var pendingForcedDisasterRefresh = false
    private static let disasterFeedStorageKey = "disasterFeed.v1"
    @Published private(set) var holidayCalendar: HolidayCalendar
    @Published private(set) var isRefreshingHolidays = false
    @Published private(set) var holidayRefreshFailed = false
    @Published private(set) var routeWeatherSnapshot: RouteWeatherSnapshot?
    @Published private(set) var isRefreshingTomorrowWeather = false
    @Published private var tomorrowWeatherRecord: TomorrowWeatherRecord?
    @Published private var tomorrowWeatherFailureRequest: TomorrowWeatherRequest?
    private var activeTomorrowWeatherRequest: TomorrowWeatherRequest?
    private var tomorrowWeatherGeneration = 0
    private var lastTomorrowWeatherAttempt: (request: TomorrowWeatherRequest, at: Date)?
    @Published private(set) var routePreview: RoutePreview?
    @Published private(set) var scheduledAlarmSummary: ScheduledAlarmSummary? {
        didSet {
            disasterScheduleNeedsAttention = false
            saveScheduledAlarmSummary()
        }
    }
    private enum AlarmStatus {
        case text(String)
        case weatherDecision(exceedsThreshold: Bool, forecastAt: Date, checkedAt: Date)
    }
    @Published private var alarmStatus = AlarmStatus.text(String(localized: "status_enter_settings"))
    private(set) var statusMessage: String {
        get {
            switch alarmStatus {
            case .text(let message): return message
            case .weatherDecision(let exceedsThreshold, let forecastAt, let checkedAt):
                let key: String.LocalizationValue = exceedsThreshold ? "status_adjusted_checked" : "status_normal_checked"
                return String.localizedStringWithFormat(String(localized: key),
                    settings.timeFormat.dateTime(forecastAt), settings.timeFormat.time(checkedAt))
            }
        }
        set { alarmStatus = .text(newValue) }
    }
    @Published private(set) var routePreviewStatusMessage = String(localized: "route_preview_empty")
    @Published private(set) var routeWeatherStatusMessage = String(localized: "route_weather_empty")
    @Published private(set) var isScheduling = false
    @Published private(set) var scheduleErrorMessage: String?
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
    private let membershipEntitlements: @MainActor () -> MembershipEntitlements?
    private let supportsTemporaryClosures: Bool

    /// Rights constrain a scheduling copy only; saved premium rules remain recoverable.
    var effectiveSchedulingSettings: CommuteAlarmSettings {
        var effective = MembershipSchedulingAccess.effectiveSettings(settings, entitlements: membershipEntitlements())
        if !supportsTemporaryClosures { effective.isDisasterSuspensionEnabled = false }
        return effective
    }
    private var suggestionSelectedInputs: [CommuteAddressField: String] = [:]
    private var previewHomeInput: String?
    private var previewWorkInput: String?
    private var previewGeneration = 0
    private var pendingHolidayUpdate = false
    private var weatherGeneration = 0
    private var scheduledFingerprint: AlarmScheduleFingerprint? {
        didSet {
            saveScheduledFingerprint()
        }
    }
    /// When the rain decision behind the armed alarm was last computed. The alarm
    /// itself repeats weekly, so this is what says whether that decision still
    /// describes the weather — see `refreshScheduledAlarmIfWeatherIsStale()`.
    private(set) var lastWeatherEvaluationAt: Date? {
        didSet {
            if let lastWeatherEvaluationAt {
                settingsStorage.set(lastWeatherEvaluationAt, forKey: Self.lastEvaluationStorageKey)
            } else {
                settingsStorage.removeObject(forKey: Self.lastEvaluationStorageKey)
            }
        }
    }
    private var autoRefreshTask: Task<Void, Never>?
    private var automaticSchedulingActivated = false
    private var lastAutomaticInitialAttempt: AlarmScheduleFingerprint?
    private var settingsRemovalTask: Task<Void, Never>?
    /// True while a run nobody asked for is in flight — a background task, or a launch
    /// that found the rain decision stale. Such a run must not repaint the status line
    /// or flag addresses the user typed correctly.
    private var isRunningUnattended = false
    private let autoRefreshDebounce: Duration
    /// When the notification extension last saw a day-off push (see `DayOffPushMarker`).
    private let dayOffPushReceivedAt: () -> Date?
    /// An alarm is ringing or snoozing (AlarmKit only; false below iOS 26 and in tests).
    private let alarmInProgress: @MainActor () -> Bool
    /// The system still holds alarms of ours, whatever the stored summary says.
    private let systemHoldsAlarms: @MainActor () -> Bool
    /// Alarms are local notifications with self-repeating follow-ups (iOS 17–25).
    private let usesNotificationAlarms: Bool
    private let calendarWeatherTimeout: Duration
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
        holidayCalendar: HolidayCalendar? = nil,
        autoRefreshDebounce: Duration = .seconds(1.5),
        calendarWeatherTimeout: Duration = .seconds(12),
        disasterFeedProvider: (any DisasterFeedProviding)? = nil,
        disasterSyncReporter: (any DisasterSyncReporting)? = nil,
        membershipEntitlements: @escaping @MainActor () -> MembershipEntitlements? = { MembershipManager.shared.schedulingEntitlements },
        supportsTemporaryClosures: Bool = AppEnvironment.supportsTemporaryClosures,
        dayOffPushReceivedAt: @escaping () -> Date? = {
            AppEnvironment.isRunningTests ? nil : DayOffPushMarker.lastReceivedAt()
        },
        alarmInProgress: @escaping @MainActor () -> Bool = {
            AppEnvironment.isRunningTests ? false : SystemAlarmScheduler.hasAlarmInProgress()
        },
        systemHoldsAlarms: @escaping @MainActor () -> Bool = {
            AppEnvironment.isRunningTests ? false : SystemAlarmScheduler.holdsRegisteredAlarms()
        },
        usesNotificationAlarms: Bool? = nil
    ) {
        // Assigning the published summary also clears the success/error state;
        // capture the persisted flag before restoring that summary.
        let restoredDisasterAttention = settingsStorage.bool(forKey: "disasterScheduleNeedsAttention")
        self.disasterFeedProvider = disasterFeedProvider ?? DisasterFeedClient(
            endpoint: AppEnvironment.dayOffServiceURL?.appendingPathComponent("v1/suspensions"))
        self.disasterSyncReporter = disasterSyncReporter ?? DisasterPushRegistration.shared
        if let data = settingsStorage.data(forKey: Self.disasterFeedStorageKey) {
            self.disasterFeed = try? JSONDecoder().decode(DisasterFeed.self, from: data)
        }
        self.holidayCalendar = holidayCalendar ?? HolidayCalendar.load(storage: settingsStorage)
        self.autoRefreshDebounce = autoRefreshDebounce
        self.calendarWeatherTimeout = calendarWeatherTimeout
        self.settings = Self.loadSettings(from: settingsStorage) ?? CommuteAlarmSettings()
        self.routeWeatherService = routeWeatherService
        self.routePreviewService = routePreviewService
        self.notificationScheduler = notificationScheduler
        self.previewScheduler = previewScheduler
        self.canRefreshInBackground = canRefreshInBackground
        self.settingsStorage = settingsStorage
        self.membershipEntitlements = membershipEntitlements
        self.supportsTemporaryClosures = supportsTemporaryClosures
        self.dayOffPushReceivedAt = dayOffPushReceivedAt
        self.alarmInProgress = alarmInProgress
        self.systemHoldsAlarms = systemHoldsAlarms
        if let usesNotificationAlarms {
            self.usesNotificationAlarms = usesNotificationAlarms
        } else if #available(iOS 26.0, *) {
            self.usesNotificationAlarms = false
        } else {
            self.usesNotificationAlarms = true
        }

        // Restore state that survives relaunches, so a scheduled alarm and confirmed
        // addresses do not look reset every time the app reopens.
        if let confirmedHome = settings.confirmedHomeAddressInput {
            suggestionSelectedInputs[.home] = confirmedHome
        }
        if let confirmedWork = settings.confirmedWorkAddressInput {
            suggestionSelectedInputs[.work] = confirmedWork
        }
        // Regions are derived from Route. Migrate old independently selected areas
        // before comparing the registered fingerprint with current settings.
        let restoredSettings = settings
        synchronizeAutomaticSuspensionRegions()
        if settings != restoredSettings { saveSettings() }
        let cacheNow = Date()
        tomorrowWeatherRecord = TomorrowWeatherRecord.load(from: settingsStorage,
            matching: TomorrowWeatherRequest(settings: settings, now: cacheNow), now: cacheNow)
        if var storedSummary = Self.loadScheduledAlarmSummary(from: settingsStorage) {
            // A weekly summary stored before 1.8.0 names no decided morning; the stored date,
            // before the roll below moves it on, is the best record of it. Without this a
            // relaunch after an early ring reads the rolled morning as the decided one, and
            // an offline re-registration would re-apply that lead to it (`hasSameForecast`).
            if storedSummary.calendarPlan == nil, storedSummary.decisionNormalAlarmDate == nil {
                storedSummary.decisionNormalAlarmDate = storedSummary.normalAlarmDate
            }
            scheduledAlarmSummary = storedSummary.rollingForward(selectedWeekdays: settings.selectedWeekdays)
            if let plan = storedSummary.calendarPlan {
                statusMessage = String(localized: plan.occurrences.isEmpty ? "calendar_all_silent" : "calendar_schedule_saved")
            } else { statusMessage = String(localized: "status_alarm_scheduled") }
        }
        scheduledFingerprint = Self.loadScheduledFingerprint(from: settingsStorage)
        disasterScheduleNeedsAttention = restoredDisasterAttention
        lastWeatherEvaluationAt = settingsStorage.object(forKey: Self.lastEvaluationStorageKey) as? Date
        updateScheduleStaleness()
        updateAlarmKitRescheduleNotice()
    }

    /// Re-decides the armed alarm against current weather when the stored decision has
    /// aged out. This is the "user opened the app" path; `BackgroundWeatherRefresh` is
    /// the one that covers the mornings they do not.
    func refreshScheduledAlarmIfWeatherIsStale() async {
        await retireSkipIfSafe()
        let settings = effectiveSchedulingSettings
        await refreshDisasterSuspensions()
        if settings.usesDatedSchedule, let plan = scheduledAlarmSummary?.calendarPlan,
           (plan.coveredUntil.timeIntervalSinceNow < Double(Self.calendarHorizonDays - 2) * 86_400 || plan.timeZoneID != TimeZone.current.identifier) {
            await applyCalendarSettings()
        }
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
        if !settings.isAlarmEnabled {
            await finishTurningOffIfNeeded()
            return false
        }
        // Disaster updates must precede the weather guard below: a 06:55 notice
        // can still cancel a 07:00 alarm even though today's rain check has passed.
        let refreshed = await refreshDisasterSuspensions()
        let disasterChanged = await retireSkipIfSafe() || refreshed
        guard hasScheduledAlarm, canSchedule, !isScheduling else {
            return disasterChanged
        }

        // Between today's check point and today's ring, leave the alarm alone. A
        // run here would decide *tomorrow* (today's check point has passed) and
        // re-register the weekly alarm at tomorrow's time — and if that differs
        // from today's, today's ring is gone. iOS grants refresh windows at its
        // discretion, so this half hour is reachable; the next run is not far.
        // Read the registration as a relaunch would: a weekly summary this process has held
        // since an earlier morning still names that morning, and today's window would be missed.
        let now = Date()
        if let summary = registeredSummary(now: now) {
            let checkPoint = summary.normalAlarmDate.addingTimeInterval(TimeInterval(-settings.rainLeadTimeMinutes * 60))
            if now >= checkPoint, now < summary.normalAlarmDate {
                return disasterChanged
            }
        }

        let evaluationsBefore = lastWeatherEvaluationAt
        let calendarBefore = scheduledAlarmSummary?.calendarPlan
        isRunningUnattended = true
        defer { isRunningUnattended = false }

        await evaluateRouteAndScheduleAlarm()
        return disasterChanged || lastWeatherEvaluationAt != evaluationsBefore || scheduledAlarmSummary?.calendarPlan != calendarBefore
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

        let isStale = effectiveSchedulingSettings.scheduleFingerprint() != scheduledFingerprint
        if isStale != isScheduleStale {
            isScheduleStale = isStale
        }
    }

    var hasScheduledAlarm: Bool {
        scheduledAlarmSummary != nil
    }

    /// Called by the foreground UI, never by construction or a background refresh.
    /// Confirmed routes can then create their first alarm without an Apply button.
    func activateAutomaticScheduling() {
        guard !automaticSchedulingActivated else { return }
        automaticSchedulingActivated = true
        // Off, yet the system still holds alarms (an interrupted or failed cancel, or a
        // summary that did not decode): remove them before anything else runs.
        if !settings.isAlarmEnabled, scheduledAlarmSummary == nil, systemHoldsAlarms() {
            enqueueSettingsRemoval(statusKey: "status_alarm_turned_off")
        }
        reconcileScheduledAlarmWithSettings()
    }

    private var hasEnabledAlarmDay: Bool {
        let settings = effectiveSchedulingSettings
        return !settings.selectedWeekdays.isEmpty
            || (settings.calendarSettings.isActive && settings.calendarSettings.overrides.values.contains(.ring))
    }

    private var hasConfirmedAutomaticRoute: Bool {
        guard invalidAddressFields.isEmpty, !hasUnconfirmedSuggestedAddresses else { return false }
        func confirmed(_ field: CommuteAddressField, input: String, location: ResolvedMapLocation?) -> Bool {
            guard suggestionSelectedInputs[field] == input.trimmingCharacters(in: .whitespacesAndNewlines),
                  let location else { return false }
            return location.latitude.isFinite && location.longitude.isFinite
                && (-90...90).contains(location.latitude) && (-180...180).contains(location.longitude)
        }
        let home = settings.homeResolvedLocation
            ?? (previewHomeInput == settings.homeAddress ? routePreview?.homeLocation : nil)
        let work = settings.workResolvedLocation
            ?? (previewWorkInput == settings.workAddress ? routePreview?.workLocation : nil)
        return confirmed(.home, input: settings.homeAddress, location: home)
            && confirmed(.work, input: settings.workAddress, location: work)
    }

    /// Existing registrations follow edits; a new registration additionally needs
    /// foreground activation and two confirmed locations. Address edits remove the
    /// old registration before the replacement route can be armed.
    private func reconcileScheduledAlarmWithSettings() {
        guard settingsRemovalTask == nil else { return }
        // Off until the user turns it back on: nothing registered, nothing re-armed —
        // before the first-arm, premium-lapse and fingerprint rules below get a say.
        guard settings.isAlarmEnabled else {
            autoRefreshTask?.cancel()
            if scheduledAlarmSummary != nil || scheduledFingerprint != nil {
                enqueueSettingsRemoval(statusKey: "status_alarm_turned_off")
            }
            return
        }
        guard scheduledAlarmSummary != nil, let scheduledFingerprint else {
            if automaticSchedulingActivated, canSchedule, hasConfirmedAutomaticRoute,
               lastAutomaticInitialAttempt != effectiveSchedulingSettings.scheduleFingerprint() {
                scheduleAutoRefresh()
            } else {
                autoRefreshTask?.cancel()
            }
            return
        }

        let current = effectiveSchedulingSettings.scheduleFingerprint()
        if !hasEnabledAlarmDay && (settings.calendarSettings.isActive && settings.calendarSettings.overrides.values.contains(.ring)) {
            autoRefreshTask?.cancel()
            return
        }
        guard current != scheduledFingerprint else {
            // Settings changed and changed back before the debounce fired.
            autoRefreshTask?.cancel()
            return
        }

        if current.homeAddress != scheduledFingerprint.homeAddress
            || current.workAddress != scheduledFingerprint.workAddress {
            enqueueSettingsRemoval()
        } else if !hasEnabledAlarmDay {
            enqueueSettingsRemoval(statusKey: "calendar_off_no_weekdays")
        } else {
            scheduleAutoRefresh()
        }
    }

    private var restrictedRulesTransitionIsSafe: Bool {
        let now = Date()
        guard let summary = registeredSummary(now: now) else { return true }
        let check = summary.normalAlarmDate.addingTimeInterval(Double(-settings.rainLeadTimeMinutes * 60))
        return now < check || now >= summary.normalAlarmDate
    }

    private func enqueueSettingsRemoval(statusKey: String.LocalizationValue = "status_alarm_removed_address_changed") {
        autoRefreshTask?.cancel()
        guard settingsRemovalTask == nil else { return }
        settingsRemovalTask = Task { [weak self] in
            guard let self else { return }
            // Let an in-flight registration finish before cancelling, otherwise its
            // late success could recreate the alarm for the old address.
            while self.isScheduling {
                try? await Task.sleep(for: .milliseconds(25))
            }
            await self.removeScheduledAlarm(statusKey: statusKey)
            self.settingsRemovalTask = nil
            self.reconcileScheduledAlarmWithSettings()
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
            guard self.settingsRemovalTask == nil else { return }

            guard !self.isScheduling else {
                // A manual run is in flight; re-debounce and reconcile after it.
                self.scheduleAutoRefresh()
                return
            }
            // Detach before running: evaluate cancels `autoRefreshTask` on entry
            // (to absorb queued debounces), and cancelling this task mid-flight
            // would abort its own weather fetch with a CancellationError.
            self.autoRefreshTask = nil
            let current = self.effectiveSchedulingSettings.scheduleFingerprint()
            if !self.hasScheduledAlarm {
                guard self.automaticSchedulingActivated, self.canSchedule, self.hasConfirmedAutomaticRoute,
                      self.lastAutomaticInitialAttempt != current else { return }
                self.lastAutomaticInitialAttempt = current
                await self.evaluateRouteAndScheduleAlarm()
            } else if self.scheduledFingerprint?.calendarSettings != current.calendarSettings
                || self.scheduledFingerprint?.disasterSettings != current.disasterSettings
                || self.scheduledFingerprint?.skippedAlarmDay != current.skippedAlarmDay {
                await self.applyCalendarSettings()
            } else {
                guard self.canSchedule else { return }
                await self.evaluateRouteAndScheduleAlarm()
            }
        }
    }

    private func removeScheduledAlarm(statusKey: String.LocalizationValue = "status_alarm_removed_address_changed") async {
        autoRefreshTask?.cancel()
        await notificationScheduler.cancelScheduledAlarms()
        await previewScheduler.cancelPreviews()
        await CalendarCoverageReminder.cancel()
        scheduledAlarmSummary = nil
        scheduledFingerprint = nil
        isScheduleStale = false
        scheduleErrorMessage = nil
        if !settings.isAlarmEnabled, systemHoldsAlarms() {
            scheduleErrorMessage = String(localized: "alarm_off_failed")
        }
        statusMessage = String(localized: statusKey)
        updateAlarmKitRescheduleNotice()
    }

    var canSchedule: Bool {
        settings.isAlarmEnabled
            && !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEnabledAlarmDay
            && settings.rainLeadTimeMinutes > 0
            && !hasUnconfirmedSuggestedAddresses
    }

    /// The Alarm page card: the coming morning, today's alarm until its normal time has
    /// passed, then tomorrow's (see `TomorrowAlarmStatus`).
    func tomorrowStatus(now: Date = Date()) -> TomorrowAlarmStatus {
        alarmStatus(now: now, dayOffset: nil)
    }

    /// Today's alarm, for the widget between local midnight and today's ring (D-C): the same
    /// inputs and rules as the card, resolved for the calendar day that has begun, so it is
    /// what AlarmKit's registration will ring (or the forecast's decision, flagged "update
    /// needed" when the registration differs). From midnight to the normal time this is the
    /// card's morning too; the widget hands over at the ring, the card at the normal time.
    func todayStatus(now: Date = Date()) -> TomorrowAlarmStatus {
        alarmStatus(now: now, dayOffset: 0)
    }

    /// Calendar tomorrow, the widget's other day. Before midnight it is the card's morning
    /// (once today's normal time has passed); after midnight the card describes today.
    func calendarTomorrowStatus(now: Date = Date()) -> TomorrowAlarmStatus {
        alarmStatus(now: now, dayOffset: 1)
    }

    /// One reading for the card and the widget: the weekly summary is rolled forward as a
    /// pair at `now`, so a process that stays alive reads what a relaunch reads, and after
    /// an early ring the next morning shows the ring AlarmKit's repeat will fire.
    private func alarmStatus(now: Date, dayOffset: Int?) -> TomorrowAlarmStatus {
        let settings = effectiveSchedulingSettings
        let request = TomorrowWeatherRequest(settings: settings, now: now, dayOffset: dayOffset)
        let currentRegistration = scheduledAlarmSummary != nil && scheduledFingerprint == effectiveSchedulingSettings.scheduleFingerprint()
        let routeIsReady = invalidAddressFields.isEmpty && !hasUnconfirmedSuggestedAddresses
            && (hasConfirmedAutomaticRoute || currentRegistration)
        // The registration repeats on the weekdays it was made with; they differ from the
        // settings' only while it is outdated (then `outdatedRegistrationRingDate` reads it).
        let registeredWeekdays = scheduledFingerprint?.selectedWeekdays ?? settings.selectedWeekdays
        return TomorrowAlarmStatus.resolve(settings: settings, holidays: holidayCalendar,
            weatherRecord: tomorrowWeatherRecord, weatherRefreshFailed: tomorrowWeatherFailureRequest == request,
            routeIsReady: routeIsReady,
            summary: displaySummary?.rollingForwardAsPair(selectedWeekdays: registeredWeekdays, now: now,
                                                          calendar: AlarmCalendarSettings.calendar),
            registeredFingerprint: scheduledFingerprint,
            disasterFeed: disasterFeed, disasterSourceFailed: disasterRefreshFailed, now: now, dayOffset: dayOffset)
    }

    /// The registered summary as the status reads it. A weekly summary stored before 1.8.0
    /// does not name the morning it was decided for; the unrolled date this model holds is
    /// that morning, unless a relaunch after its ring already rolled it (then the lead reads
    /// as decided, as it did before 1.8.0, until the next registration records the date).
    private var displaySummary: ScheduledAlarmSummary? {
        guard var summary = scheduledAlarmSummary else { return nil }
        if summary.calendarPlan == nil, summary.decisionNormalAlarmDate == nil {
            summary.decisionNormalAlarmDate = summary.normalAlarmDate
        }
        return summary
    }

    /// The registration as the scheduler reads it: what a relaunch reads (`init` rolls the
    /// stored summary forward). A weekly summary this process has held since it registered
    /// still names the morning it was made for, while AlarmKit's weekly repeat has carried
    /// its ring onto every selected morning since. Rolled, its normal date is the coming
    /// morning's, so a carried early ring that already went off there is recognised
    /// (`earlyRingThatWentOff`) and that morning's check window is where the scheduler looks;
    /// unrolled, a re-registration inside the window armed the normal time and the morning
    /// rang twice. The lead and `decisionNormalAlarmDate` survive the roll.
    ///
    /// Dated plans are returned as held: each occurrence already names its morning, and
    /// `datedBasePlan` reads those.
    private func registeredSummary(now: Date) -> ScheduledAlarmSummary? {
        guard let summary = displaySummary else { return nil }
        guard summary.calendarPlan == nil else { return summary }
        return summary.rollingForward(selectedWeekdays: scheduledFingerprint?.selectedWeekdays ?? settings.selectedWeekdays,
                                      now: now, calendar: AlarmCalendarSettings.calendar)
    }

    #if DEBUG
    /// Tests only: a process that registered `summary` on an earlier morning and has stayed
    /// alive since holds it as registered, never rolled (only `init` rolls). A test cannot
    /// wait a day for AlarmKit's weekly repeat to carry the ring on, so it hands one over.
    func holdRegistrationForTesting(_ summary: ScheduledAlarmSummary) {
        scheduledAlarmSummary = summary
    }
    #endif

    /// The coming morning's forecast (today's until its normal time, then tomorrow's) is
    /// fetched even on a skipped day. This path never authorizes,
    /// registers, cancels, or persists a successful alarm schedule.
    func refreshTomorrowWeatherIfNeeded(now: Date = Date(), force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let request = TomorrowWeatherRequest(settings: settings, now: now)
        guard request.hasRoute else { return }
        guard activeTomorrowWeatherRequest != request || !isRefreshingTomorrowWeather else { return }
        if !force {
            if tomorrowWeatherFailureRequest != request,
               let record = tomorrowWeatherRecord, record.request == request, record.isValid(at: now),
               now.timeIntervalSince(record.snapshot.checkedAt) <= TomorrowAlarmStatus.weatherLifetime { return }
            if let attempt = lastTomorrowWeatherAttempt, attempt.request == request,
               now.timeIntervalSince(attempt.at) >= 0, now.timeIntervalSince(attempt.at) < 60 { return }
        }

        tomorrowWeatherGeneration += 1
        let generation = tomorrowWeatherGeneration
        activeTomorrowWeatherRequest = request
        lastTomorrowWeatherAttempt = (request, now)
        isRefreshingTomorrowWeather = true
        let startedAt = Date()
        defer {
            if generation == tomorrowWeatherGeneration {
                activeTomorrowWeatherRequest = nil
                isRefreshingTomorrowWeather = false
            }
        }
        do {
            let service = routeWeatherService
            let timeout = calendarWeatherTimeout
            let snapshot = try await withThrowingTaskGroup(of: RouteWeatherSnapshot.self) { group in
                group.addTask {
                    try await service.fetchRouteWeather(from: request.homeAddress, homeLocation: request.homeLocation,
                        to: request.workAddress, workLocation: request.workLocation, mode: request.mode, around: request.forecastDate)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            let completedAt = now.addingTimeInterval(max(0, Date().timeIntervalSince(startedAt)))
            guard generation == tomorrowWeatherGeneration,
                  TomorrowWeatherRequest(settings: settings, now: completedAt) == request else { return }
            let record = TomorrowWeatherRecord(request: request, snapshot: snapshot)
            guard record.isValid(at: completedAt),
                  completedAt.timeIntervalSince(snapshot.checkedAt) <= TomorrowAlarmStatus.weatherLifetime else {
                throw URLError(.cannotParseResponse)
            }
            try Task.checkCancellation()
            record.save(to: settingsStorage, now: completedAt)
            tomorrowWeatherRecord = record
            tomorrowWeatherFailureRequest = nil
        } catch {
            if Task.isCancelled || error is CancellationError {
                if generation == tomorrowWeatherGeneration { lastTomorrowWeatherAttempt = nil }
                return
            }
            guard generation == tomorrowWeatherGeneration,
                  TomorrowWeatherRequest(settings: settings, now: now.addingTimeInterval(max(0, Date().timeIntervalSince(startedAt)))) == request else { return }
            // Keep a last good matching snapshot, with its original timestamp.
            tomorrowWeatherFailureRequest = request
        }
    }

    var homeAutomaticSuspensionRegion: DisasterRegion? {
        guard !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let location = settings.homeResolvedLocation {
            return DisasterRegionCatalog.matching(location.districtName)
        }
        return DisasterRegionCatalog.matching(homeMapDistrict)
    }

    var workAutomaticSuspensionRegion: DisasterRegion? {
        guard !settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let location = settings.workResolvedLocation {
            return DisasterRegionCatalog.matching(location.districtName)
        }
        return DisasterRegionCatalog.matching(workMapDistrict)
    }

    private func synchronizeAutomaticSuspensionRegions() {
        let home = homeAutomaticSuspensionRegion
        let work = workAutomaticSuspensionRegion
        if settings.homeSuspensionRegion != home { settings.homeSuspensionRegion = home }
        if settings.workSuspensionRegion != work { settings.workSuspensionRegion = work }
    }

    var homeMapDistrict: String? {
        if previewHomeInput == settings.homeAddress, let district = routePreview?.homeLocation.districtName { return district }
        return settings.homeResolvedLocation?.districtName
    }

    var workMapDistrict: String? {
        if previewWorkInput == settings.workAddress, let district = routePreview?.workLocation.districtName { return district }
        return settings.workResolvedLocation?.districtName
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

        let homeInput = settings.homeAddress
        let workInput = settings.workAddress
        let selectedHomeLocation = settings.homeResolvedLocation
        let selectedWorkLocation = settings.workResolvedLocation
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
            guard settings.homeAddress == homeInput, settings.workAddress == workInput,
                  settings.homeResolvedLocation == selectedHomeLocation, settings.workResolvedLocation == selectedWorkLocation else { return }
            previewHomeInput = homeInput
            previewWorkInput = workInput
            routePreview = preview
            if settings.homeResolvedLocation != nil { settings.homeResolvedLocation = preview.homeLocation }
            if settings.workResolvedLocation != nil { settings.workResolvedLocation = preview.workLocation }
            invalidAddressFields.removeAll()
            updateSuggestedAddressMatches(homeLocation: preview.homeLocation, workLocation: preview.workLocation)
            synchronizeAutomaticSuspensionRegions()
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
            reconcileScheduledAlarmWithSettings()
        } catch {
            guard generation == previewGeneration else {
                return
            }
            guard settings.homeAddress == homeInput, settings.workAddress == workInput,
                  settings.homeResolvedLocation == selectedHomeLocation, settings.workResolvedLocation == selectedWorkLocation else { return }
            routePreview = nil
            synchronizeAutomaticSuspensionRegions()
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
        synchronizeAutomaticSuspensionRegions()
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

        let mapLocation = field == .home
            ? (previewHomeInput == settings.homeAddress ? routePreview?.homeLocation : nil)
            : (previewWorkInput == settings.workAddress ? routePreview?.workLocation : nil)
        setSuggestionSelectedInput(actualAddress, for: field)
        switch field {
        case .home:
            settings.homeAddress = actualAddress
            settings.homeResolvedLocation = mapLocation
        case .work:
            settings.workAddress = actualAddress
            settings.workResolvedLocation = mapLocation
        }
        suggestedAddressMatches.removeValue(forKey: field)
        invalidAddressFields.remove(field)
        reconcileScheduledAlarmWithSettings()
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
        // A different map selection can have the same display text. Do not let an
        // old preview supply its district or overwrite this selection later.
        previewGeneration += 1
        isPreviewingRoute = false
        if field == .home { previewHomeInput = nil } else { previewWorkInput = nil }
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
        suggestedAddressMatches.removeValue(forKey: field)
        invalidAddressFields.remove(field)
        reconcileScheduledAlarmWithSettings()
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
            let forecastAt = settings.timeFormat.dateTime(snapshot.forecastAt)
            routeWeatherStatusMessage = String.localizedStringWithFormat(
                String(localized: "route_weather_updated"),
                forecastAt,
                settings.timeFormat.time(snapshot.checkedAt)
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
        if let settingsRemovalTask { await settingsRemovalTask.value }
        guard settings.isAlarmEnabled else {
            statusMessage = String(localized: "status_alarm_turned_off")
            return
        }
        if hasScheduledAlarm,
           settings.scheduleFingerprint() != effectiveSchedulingSettings.scheduleFingerprint(),
           !restrictedRulesTransitionIsSafe {
            // Do not replace an imminent alarm because a feature was deferred or
            // paid rules expired. The next refresh outside this ring window retries.
            return
        }
        guard canSchedule else {
            statusMessage = hasUnconfirmedSuggestedAddresses
                ? String(localized: "status_confirm_suggested_address")
                : String(localized: "status_required")
            return
        }

        isScheduling = true
        scheduleErrorMessage = nil
        // This run IS the refresh; a queued debounce would only duplicate it.
        autoRefreshTask?.cancel()
        defer { finishScheduling() }

        // Freeze the settings for the whole flow: the user can keep moving sliders
        // while the weather fetch is in flight, and the registered alarm must match
        // ONE consistent set of values — the fingerprint saved below. Drift that
        // happens mid-flight is caught by reconcile at the end.
        let settingsSnapshot = effectiveSchedulingSettings
        // What the evening preview announced, if this run turns out to re-decide
        // the same ring.
        let previousSummary = scheduledAlarmSummary

        do {
            let authorized = try await notificationScheduler.requestAuthorization()
            guard authorized else {
                scheduleErrorMessage = if #available(iOS 26.0, *) {
                    String(localized: "status_alarm_permission_denied")
                } else { String(localized: "status_permission_denied") }
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

            if settingsSnapshot.usesDatedSchedule {
                try await registerCalendar(settings: settingsSnapshot, refreshWeather: true)
                reconcileScheduledAlarmWithSettings()
                return
            }
            if weeklyComingMorningIsDecided(settingsSnapshot, now: Date()) {
                // The rain check below would decide the next check point ahead — tomorrow's
                // — and move the one repeating alarm to tomorrow's time: a rainy tomorrow
                // takes this morning's ring with it, a dry one rings a morning that already
                // rang early a second time. Register this morning's own decision instead;
                // the first run after its normal time decides tomorrow.
                try await restoreWeeklySchedule(settings: settingsSnapshot)
                reconcileScheduledAlarmWithSettings()
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
                    settings.timeFormat.dateTime(snapshot.forecastAt),
                    settings.timeFormat.time(snapshot.checkedAt)
                )
            }

            let exceedsThreshold = snapshot.exceedsRainThreshold(settingsSnapshot.rainProbabilityThreshold)
            var summary = AlarmTimeCalculator.nextAlarmDateForWeatherCheck(
                alarmTime: settingsSnapshot.alarmTime,
                leadTimeMinutes: settingsSnapshot.rainLeadTimeMinutes,
                shouldApplyLeadTime: exceedsThreshold,
                rainProbabilityThreshold: settingsSnapshot.rainProbabilityThreshold,
                maximumPrecipitationProbability: snapshot.maximumPrecipitationProbability,
                selectedWeekdays: settingsSnapshot.selectedWeekdays,
                now: now
            )
            summary.wettestSegmentName = snapshot.segments
                .max { $0.precipitationProbability < $1.precipitationProbability }?
                .name
            // The morning this forecast decided: the weekly repeat carries the ring past it.
            summary.decisionNormalAlarmDate = summary.normalAlarmDate

            let body = exceedsThreshold
                ? String(localized: "notification_body_adjusted")
                : String(localized: "notification_body_normal")

            let selectedSound = settingsSnapshot.soundSelection(
                ringDate: summary.scheduledAlarmDate, normalDate: summary.normalAlarmDate)
            // Turned off while the forecast was loading: register nothing.
            guard settings.isAlarmEnabled else { return }
            try await notificationScheduler.scheduleAlarm(
                at: summary.scheduledAlarmDate,
                normalAlarmDate: summary.normalAlarmDate,
                weekdays: settingsSnapshot.selectedWeekdays,
                sound: selectedSound.sound,
                soundFileNameOverride: selectedSound.fileNameOverride,
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
            await CalendarCoverageReminder.cancel()
            await replanEveningPreviews(requestingAuthorization: !isRunningUnattended, summary: summary, settings: settingsSnapshot, now: now)
            // The same ring, re-decided while nobody was looking: say so. A
            // foreground run shows the new time on the status line instead.
            if isRunningUnattended,
               let previousSummary,
               Calendar.current.isDate(previousSummary.normalAlarmDate, equalTo: summary.normalAlarmDate, toGranularity: .minute),
               abs(previousSummary.scheduledAlarmDate.timeIntervalSince(summary.scheduledAlarmDate)) >= 60,
               settingsSnapshot.isEveningPreviewEnabled {
                await previewScheduler.notifyDecisionChange(AlarmDecisionChange(
                    normalAlarmDate: summary.normalAlarmDate,
                    previousRingDate: previousSummary.scheduledAlarmDate,
                    newRingDate: summary.scheduledAlarmDate,
                    maximumProbability: summary.maximumPrecipitationProbability,
                    threshold: summary.rainProbabilityThreshold,
                    place: summary.wettestSegmentName,
                    timeFormat: settings.timeFormat
                ))
            }

            alarmStatus = .weatherDecision(exceedsThreshold: exceedsThreshold,
                forecastAt: snapshot.forecastAt, checkedAt: snapshot.checkedAt)
        } catch {
            scheduleErrorMessage = String.localizedStringWithFormat(
                String(localized: "status_schedule_failed"), Self.userFacingMessage(for: error))
            if settingsSnapshot.isDisasterSuspensionEnabled || previousSummary?.disasterSkips?.isEmpty == false {
                disasterScheduleNeedsAttention = true
                await previewScheduler.cancelPreviews()
            }
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

        // Typed text that Apple matched exactly under the same name ("Taipei main
        // station" → "Taipei Main Station") has nothing to confirm. Keep the user's
        // spelling and save the coordinate so a later lookup cannot move it. A house
        // number still asks: the same street and number exist in many towns.
        let suggestedAddress = location.displayAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        if location.resolution == .exact, let suggestedAddress,
           MapItemResolver.isSameAddressText(trimmedInput, suggestedAddress),
           !MapItemResolver.containsHouseNumber(trimmedInput) {
            suggestedAddressMatches.removeValue(forKey: field)
            setSuggestionSelectedInput(trimmedInput, for: field)
            switch field {
            case .home: settings.homeResolvedLocation = location
            case .work: settings.workResolvedLocation = location
            }
            return
        }


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

    /// Re-plans the previews from the stored summary — the toggle flipping, or
    /// permission arriving after the alarm was registered.
    private func replanEveningPreviews(requestingAuthorization: Bool) async {
        let settings = effectiveSchedulingSettings
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
            canRefreshInBackground: canRefreshInBackground(),
            calendarSettings: settings.calendarSettings,
            holidays: holidayCalendar,
            // What the card shows under a closure, so the preview names the same update time.
            closureSourceUpdatedAt: disasterFeed?.sourceUpdatedAt,
            // Display preference may change while a schedule/permission request
            // is in flight; use the current format with the registered dates.
            timeFormat: self.settings.timeFormat
        )
        await previewScheduler.replacePreviews(previews)
        // Best effort at a forecast fetched just before the first preview fires,
        // so its text is as fresh as the system lets it be.
        BackgroundWeatherRefresh.schedulePreviewRefresh(before: previews.first?.fireDate, now: now)
    }

    static var calendarHorizonDays: Int {
        27
    }

    func dayDecision(on day: Date) -> DayDecision {
        settings.calendarSettings.decision(on: day, weekdays: settings.selectedWeekdays, holidays: holidayCalendar)
    }

    func toggleCalendarDay(_ day: Date) {
        var rules = settings.calendarSettings
        rules.toggleDay(on: day, weekdays: settings.selectedWeekdays, holidays: holidayCalendar)
        settings.calendarSettings = rules
    }

    func calendarDayIsEdited(_ day: Date) -> Bool {
        settings.calendarSettings.hasEffectiveOverride(on: day, weekdays: settings.selectedWeekdays, holidays: holidayCalendar)
    }

    func restoreCalendarDay(_ day: Date) {
        settings.calendarSettings.overrides.removeValue(forKey: AlarmCalendarSettings.key(for: day))
    }

    // MARK: - Master switch (free on every plan)

    /// Whether the Alarm page's switch reads on: enabled and not skipping the next alarm.
    /// Reads the clock, so the page's 30 s tick turns it back on after the skipped morning.
    func isAlarmSwitchOn(now: Date = Date()) -> Bool {
        settings.isAlarmEnabled && liveSkippedAlarmDate(now: now) == nil
    }

    /// The pending one-time skip's morning (its normal time) while still ahead.
    func liveSkippedAlarmDate(now: Date = Date()) -> Date? {
        guard settings.isAlarmEnabled else { return nil }
        return CalendarAlarmPlan.skippedNormalDate(settings: effectiveSchedulingSettings, holidays: holidayCalendar, now: now)
    }

    /// When the alarm rings again after the skipped morning — only once the system holds
    /// the plan without it, so the page never promises an unregistered resume.
    func ringAfterSkip(now: Date = Date()) -> Date? {
        guard let skipped = liveSkippedAlarmDate(now: now),
              scheduledFingerprint?.skippedAlarmDay == settings.skippedAlarmDay,
              let plan = scheduledAlarmSummary?.calendarPlan else { return nil }
        return plan.occurrences.first { $0.normalDate > skipped && $0.ringDate > now }?.normalDate
    }

    /// What "turn off only the next alarm" can offer right now.
    func skipAvailability(now: Date = Date()) -> AlarmSkipAvailability {
        // A run in flight is not "nothing to skip": skipNextAlarm waits for it and re-checks.
        guard settings.isAlarmEnabled, liveSkippedAlarmDate(now: now) == nil,
              let summary = scheduledAlarmSummary else { return .unavailable }
        // A morning that already rang early is not "next": its normal-time ring stays out of
        // every re-registration (datedBasePlan), so the target is the following morning's.
        // A ringing or snoozing weekly relative alarm survives the dated re-registration.
        if summary.calendarPlan == nil, alarmInProgress() { return .alarmInProgress }
        guard let target = summary.nextRegisteredRing(settings: effectiveSchedulingSettings,
                                                      holidays: holidayCalendar, now: now) else { return .unavailable }
        return .available(target)
    }

    /// Turns off only `target`'s morning. Re-validates first: a dialog left open past a
    /// ring must not skip a different morning than the one it named.
    @discardableResult
    func skipNextAlarm(_ target: CalendarAlarmPlan.Occurrence) async -> Bool {
        await waitForSchedulingToSettle()
        guard case .available(let current) = skipAvailability(now: Date()), current.normalDate == target.normalDate,
              !isScheduling, settingsRemovalTask == nil else {
            return false
        }
        cancelPendingAutoRefresh()
        settings.skippedAlarmDay = AlarmCalendarSettings.key(for: target.normalDate)
        cancelPendingAutoRefresh()
        // Immediate and offline: no weather fetch inside a ring window.
        await applyCalendarSettings(userInitiated: true)
        return true
    }

    /// Off until the user turns it back on. Cancels everything at once — even inside a
    /// ring window, and a ringing or snoozing alarm: this is an explicit choice.
    func turnAlarmOff() async {
        let background = beginBackgroundTime("turn-alarm-off")
        defer { endBackgroundTime(background) }
        cancelPendingAutoRefresh()
        var next = settings
        next.isAlarmEnabled = false
        next.skippedAlarmDay = nil
        settings = next
        // Cancel at once, without waiting for an in-flight registration (its weather fetch
        // can take long, and the app may be suspended meanwhile). The removal below sweeps
        // again once that run ends, and registrations re-check the switch before arming.
        await notificationScheduler.cancelScheduledAlarms()
        // Reconcile's off branch removes a stored registration; this also sweeps alarms
        // the system holds without one (a summary that failed to decode).
        if settingsRemovalTask == nil { enqueueSettingsRemoval(statusKey: "status_alarm_turned_off") }
        await settingsRemovalTask?.value
    }

    /// Off, but a registration or system alarms survived (a cancel interrupted by
    /// suspension): remove them. Called from launch, background and push paths.
    func finishTurningOffIfNeeded() async {
        guard !settings.isAlarmEnabled, hasScheduledAlarm || scheduledFingerprint != nil || systemHoldsAlarms() else { return }
        let background = beginBackgroundTime("finish-turning-off")
        defer { endBackgroundTime(background) }
        if settingsRemovalTask == nil { enqueueSettingsRemoval(statusKey: "status_alarm_turned_off") }
        await settingsRemovalTask?.value
    }

    private func waitForSchedulingToSettle(timeout: Duration = .seconds(20)) async {
        if let settingsRemovalTask { await settingsRemovalTask.value }
        let deadline = ContinuousClock.now + timeout
        while isScheduling, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func beginBackgroundTime(_ name: String) -> UIBackgroundTaskIdentifier {
        guard !AppEnvironment.isRunningTests else { return .invalid }
        return UIApplication.shared.beginBackgroundTask(withName: name)
    }

    private func endBackgroundTime(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// iOS 17–25 notification alarms: going back to the weekly plan re-adds today's
    /// repeating follow-up triggers. While today's chain would still be firing, stay on
    /// the dated plan (which already left today's rung morning out).
    private func weeklyRestoreWouldReviveFollowUps(now: Date = Date()) -> Bool {
        guard usesNotificationAlarms else { return false }
        let effective = effectiveSchedulingSettings
        let calendar = AlarmCalendarSettings.calendar
        guard effective.selectedWeekdays.contains(calendar.component(.weekday, from: now)) else { return false }
        let time = calendar.dateComponents([.hour, .minute], from: effective.alarmTime)
        guard let normal = calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: now) else { return false }
        let start = normal.addingTimeInterval(TimeInterval(-effective.rainLeadTimeMinutes * 60))
        let end = normal.addingTimeInterval(LocalNotificationScheduler.weeklyFollowUpWindow(
            weekdayCount: effective.selectedWeekdays.count, snoozeMinutes: effective.effectiveSnoozeMinutes))
        return start <= now && now < end
    }

    /// The switch was turned on: undo a one-time skip, or arm again after "off".
    func turnAlarmOn() async {
        if settings.isAlarmEnabled {
            guard settings.skippedAlarmDay != nil else { return }
            await waitForSchedulingToSettle()
            cancelPendingAutoRefresh()
            settings.skippedAlarmDay = nil
            cancelPendingAutoRefresh()
            await applyCalendarSettings(userInitiated: true, keepDated: weeklyRestoreWouldReviveFollowUps())
            return
        }
        var next = settings
        next.isAlarmEnabled = true
        next.skippedAlarmDay = nil
        lastAutomaticInitialAttempt = nil
        settings = next
        cancelPendingAutoRefresh()
        if let settingsRemovalTask { await settingsRemovalTask.value }
        guard settings.isAlarmEnabled, !hasScheduledAlarm, canSchedule else { return }
        let effective = effectiveSchedulingSettings
        if weeklyComingMorningIsDecided(effective, now: Date()) {
            // Inside this morning's check window the weekly evaluate would decide tomorrow,
            // and a rainy tomorrow would replace this morning's ring. Arm at the usual time.
            await armWithoutForecast()
            return
        }
        await evaluateRouteAndScheduleAlarm()
        // On means armed, like the Clock app: offline, a weekly alarm still rings at its
        // usual time until the rain check can run.
        if !hasScheduledAlarm, settings.isAlarmEnabled, !effective.usesDatedSchedule, canSchedule,
           invalidAddressFields.isEmpty, !isScheduling, settingsRemovalTask == nil,
           await armWithoutForecast() {
            scheduleErrorMessage = String(localized: "alarm_on_without_forecast")
        }
    }

    /// Weekly schedules: the coming morning is a selected day whose rain decision can no
    /// longer change — its check point has passed, or its early ring already went off —
    /// while its normal time is still ahead. A registration made now must carry that
    /// morning's decision, not the next one's (see `restoreWeeklySchedule`).
    private func weeklyComingMorningIsDecided(_ settings: CommuteAlarmSettings, now: Date) -> Bool {
        guard !settings.usesDatedSchedule else { return false }
        let coming = TomorrowWeatherRequest(settings: settings, now: now)
        let weekday = AlarmCalendarSettings.calendar.component(.weekday, from: coming.normalAlarmDate)
        guard settings.selectedWeekdays.contains(weekday) else { return false }
        return coming.forecastDate <= now
            || registeredSummary(now: now)?.hasFiredEarlyRing(forMorning: coming.normalAlarmDate, now: now) == true
    }

    private func cancelPendingAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Registers from settings alone — no forecast, no route re-check — for turning the
    /// alarm back on when the weather cannot or must not be consulted.
    @discardableResult
    private func armWithoutForecast() async -> Bool {
        guard settings.isAlarmEnabled, canSchedule, !isScheduling, settingsRemovalTask == nil else { return false }
        isScheduling = true
        scheduleErrorMessage = nil
        cancelPendingAutoRefresh()
        var succeeded = false
        defer {
            finishScheduling()
            if succeeded { reconcileScheduledAlarmWithSettings() }
        }
        do {
            guard try await notificationScheduler.requestAuthorization() else {
                statusMessage = if #available(iOS 26.0, *) {
                    String(localized: "status_alarm_permission_denied")
                } else { String(localized: "status_permission_denied") }
                scheduleErrorMessage = statusMessage
                return false
            }
            let snapshot = effectiveSchedulingSettings
            if snapshot.usesDatedSchedule {
                try await registerCalendar(settings: snapshot, refreshWeather: false)
            } else {
                try await restoreWeeklySchedule()
            }
            succeeded = true
            return true
        } catch {
            statusMessage = String.localizedStringWithFormat(String(localized: "status_schedule_failed"), Self.userFacingMessage(for: error))
            scheduleErrorMessage = statusMessage
            return false
        }
    }

    /// Clears a spent one-time skip and goes back to the ordinary registration (weekly
    /// users to their single repeating alarm) — only at a moment that cannot disturb a
    /// morning in progress. Deferring is harmless: the dated plan keeps ringing later days.
    @discardableResult
    private func retireSkipIfSafe(now: Date = Date()) async -> Bool {
        let effective = effectiveSchedulingSettings
        guard settings.skippedAlarmDay != nil,
              CalendarAlarmPlan.skippedNormalDate(settings: effective, holidays: holidayCalendar, now: now) == nil,
              !isScheduling, settingsRemovalTask == nil, !alarmInProgress(),
              TomorrowWeatherRequest(settings: effective, now: now).forecastDate > now,
              !weeklyRestoreWouldReviveFollowUps(now: now) else { return false }
        if let summary = scheduledAlarmSummary {
            let recent = (summary.calendarPlan?.occurrences ?? []) + [summary.firedEarlyRing].compactMap { $0 }
            // Within an hour of a ring: follow-up notifications (iOS 17–25) or an alerting alarm.
            if recent.contains(where: { $0.ringDate <= now && now < $0.normalDate.addingTimeInterval(3_600) }) { return false }
        }
        settings.skippedAlarmDay = nil
        cancelPendingAutoRefresh()
        await applyCalendarSettings()
        return true
    }

    /// Updates announcements independently from weather. Failed requests never
    /// masquerade as an empty successful feed, and successful fetches alone never
    /// publish an "alarm skipped" state.
    @discardableResult
    func refreshDisasterSuspensions(force: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let task = disasterRefreshTask {
            // A newer push must trigger a new fetch, not merely reapply the
            // snapshot already in flight. Its completion waits for that fetch.
            if force { pendingForcedDisasterRefresh = true }
            return await task.value
        }
        let task = Task { @MainActor in
            var changed = false
            var shouldForce = force
            repeat {
                pendingForcedDisasterRefresh = false
                let attemptBefore = disasterLastAttemptAt
                let update = await performDisasterRefresh(force: shouldForce)
                changed = changed || update
                shouldForce = true
                // A push that landed while this fetch was in flight (the app was opened,
                // then locked on a slow network) is news the fetch may predate. The alert
                // push does not wake the app, so a caller joining this task on the next
                // open would otherwise settle for the older result. Only after a real
                // attempt, so a run that fetched nothing cannot loop.
                if let attempt = disasterLastAttemptAt, attempt != attemptBefore,
                   let pushedAt = dayOffPushReceivedAt(), pushedAt > attempt {
                    pendingForcedDisasterRefresh = true
                }
            } while pendingForcedDisasterRefresh && !Task.isCancelled
            disasterRefreshTask = nil
            return changed
        }
        disasterRefreshTask = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performDisasterRefresh(force: Bool) async -> Bool {
        if !self.settings.isAlarmEnabled { await finishTurningOffIfNeeded() }
        let settings = effectiveSchedulingSettings
        // Turning the feature off must retry an unfinished restore, even with
        // fresh weather or no network. A persisted skip remains real until the
        // system accepts the replacement.
        if !settings.isDisasterSuspensionEnabled {
            guard hasScheduledAlarm,
                  scheduledFingerprint?.disasterSettings != nil || disasterScheduleNeedsAttention
                    || scheduledAlarmSummary?.disasterSkips?.isEmpty == false else { return false }
            if isScheduling { pendingDisasterUpdate = true; return false }
            let before = scheduledAlarmSummary
            await applyCalendarSettings()
            return before != scheduledAlarmSummary
        }
        if !force, let last = disasterLastAttemptAt, Date().timeIntervalSince(last) < 5 * 60 {
            // The alert push does not wake the app, and its text asks the user to
            // open it. A push since the last attempt means there is news to fetch.
            guard let pushedAt = dayOffPushReceivedAt(), pushedAt > last else { return false }
        }
        isRefreshingDisasters = true
        disasterLastAttemptAt = Date()
        defer { isRefreshingDisasters = false }
        do {
            let fresh = try await disasterFeedProvider.fetch()
            try Task.checkCancellation()
            // A slower/older upstream response cannot overwrite a newer snapshot.
            if disasterFeed == nil || fresh.checkedAt >= disasterFeed!.checkedAt {
                disasterFeed = fresh
                if let data = try? JSONEncoder().encode(fresh) { settingsStorage.set(data, forKey: Self.disasterFeedStorageKey) }
            }
            disasterRefreshFailed = false
        } catch {
            if Task.isCancelled { return false }
            disasterRefreshFailed = true
        }
        if isScheduling { pendingDisasterUpdate = true; return false }
        guard hasScheduledAlarm else {
            await reportDisasterSync(feed: disasterFeed)
            return false
        }
        let now = Date()
        let base = datedBasePlan(settings: settings, now: now).plan
        let new = DisasterAlarmPlan.filtering(base, settings: settings,
            feed: disasterRefreshFailed ? nil : disasterFeed, now: now).skips
        let old = (scheduledAlarmSummary?.disasterSkips ?? []).filter { $0.normalDate > now }
        let changed = disasterScheduleNeedsAttention || new.map(\.normalDate) != old.map(\.normalDate)
            || new.map(\.noticeIDs) != old.map(\.noticeIDs)
            || scheduledFingerprint?.disasterSettings != effectiveSchedulingSettings.scheduleFingerprint().disasterSettings
        guard changed else {
            await reportDisasterSync(feed: disasterFeed)
            return false
        }
        let before = scheduledAlarmSummary
        let wasUnattended = isRunningUnattended
        isRunningUnattended = true
        await applyCalendarSettings()
        isRunningUnattended = wasUnattended
        return before != scheduledAlarmSummary
    }

    /// This is a historical acknowledgement of local processing, not proof that
    /// APNs delivered or that every later alarm will stay in this state. A fetch
    /// alone, failed registration, stale settings or superseded feed cannot ACK.
    private func reportDisasterSync(feed: DisasterFeed?, committedDuringScheduling: Bool = false) async {
        let settings = effectiveSchedulingSettings
        let now = Date()
        guard !Task.isCancelled, settings.isDisasterSuspensionEnabled,
              !disasterRefreshFailed, !disasterScheduleNeedsAttention,
              !pendingForcedDisasterRefresh,
              !isScheduling || committedDuringScheduling,
              let feed, feed == disasterFeed, feed.schemaVersion == 1,
              now.timeIntervalSince(feed.checkedAt) <= 15 * 60,
              feed.checkedAt.timeIntervalSince(now) <= 5 * 60 else { return }
        let result: DisasterSyncReceipt.Result
        if let summary = scheduledAlarmSummary {
            guard scheduledFingerprint == effectiveSchedulingSettings.scheduleFingerprint(),
                  let plan = summary.calendarPlan, plan.coveredUntil > now else { return }
            let base = datedBasePlan(settings: settings, now: now).plan
            let expected = DisasterAlarmPlan.filtering(base, settings: settings, feed: feed, now: now).skips
            let actual = (summary.disasterSkips ?? []).filter { $0.normalDate > now }
            guard expected.map(\.normalDate) == actual.map(\.normalDate),
                  expected.map(\.noticeIDs) == actual.map(\.noticeIDs) else { return }
            result = .applied
        } else {
            guard scheduledFingerprint == nil else { return }
            result = .noAlarm
        }
        guard let receipt = DisasterSyncReceipt(revision: feed.revision, checkedAt: feed.checkedAt,
            appliedAt: now, result: result) else { return }
        await disasterSyncReporter.report(receipt)
    }

    var nextAppliedDisasterSkip: AppliedDisasterSkip? {
        (scheduledAlarmSummary?.disasterSkips ?? []).first { $0.normalDate > Date() }
    }

    func refreshHolidays(force: Bool = false) async {
        let settings = effectiveSchedulingSettings
        guard !isRefreshingHolidays, settings.calendarSettings.isEnabled, settings.calendarSettings.source == .taiwan else { return }
        if !force, let last = holidayCalendar.fetchedAt, Date().timeIntervalSince(last) < 30 * 86_400 { return }
        isRefreshingHolidays = true
        defer { isRefreshingHolidays = false }
        do {
            let year = AlarmCalendarSettings.calendar.component(.year, from: Date())
            let fresh = try await HolidayCalendar.fetch(years: [year, year + 1])
            let old = holidayCalendar.days
            holidayCalendar.days.merge(fresh.days) { _, new in new }
            holidayCalendar.fetchedAt = fresh.fetchedAt
            holidayRefreshFailed = false
            if let data = try? JSONEncoder().encode(holidayCalendar) { settingsStorage.set(data, forKey: HolidayCalendar.cacheKey) }
            if old != holidayCalendar.days {
                if isScheduling { pendingHolidayUpdate = true }
                else { await applyCalendarSettings() }
            }
        } catch { holidayRefreshFailed = true }
    }

    /// Calendar edits must work offline. They reuse a decision only for the same
    /// morning; an unforecast future morning keeps the configured normal time.
    /// - Parameter userInitiated: an explicit tap (the master switch's skip or undo). It may
    ///   re-register inside the current ring window, which automatic runs never do.
    /// - Parameter keepDated: register the dated plan even when the settings no longer need
    ///   one (see `weeklyRestoreWouldReviveFollowUps`).
    func applyCalendarSettings(userInitiated: Bool = false, keepDated: Bool = false) async {
        guard settings.isAlarmEnabled else { return }
        let saved = settings
        let settings = effectiveSchedulingSettings
        let rulesRestricted = saved.scheduleFingerprint() != settings.scheduleFingerprint()
        if rulesRestricted {
            // Keep already armed alarms through the current ring window. If calendar
            // exceptions were the only enabled days, do not erase the existing plan;
            // the user needs to choose basic repeat days before a replacement exists.
            guard hasEnabledAlarmDay, userInitiated || restrictedRulesTransitionIsSafe else { return }
        }
        guard hasScheduledAlarm, !isScheduling, settingsRemovalTask == nil, let registered = scheduledFingerprint else { return }
        let current = effectiveSchedulingSettings.scheduleFingerprint()
        guard current.homeAddress == registered.homeAddress, current.workAddress == registered.workAddress else { return }
        if !settings.calendarSettings.isActive, settings.selectedWeekdays.isEmpty {
            await removeScheduledAlarm(statusKey: "calendar_off_no_weekdays")
            return
        }
        isScheduling = true
        scheduleErrorMessage = nil
        autoRefreshTask?.cancel()
        var succeeded = false
        defer {
            finishScheduling()
            if succeeded { reconcileScheduledAlarmWithSettings() }
        }
        do {
            guard try await notificationScheduler.requestAuthorization() else {
                statusMessage = if #available(iOS 26.0, *) {
                    String(localized: "status_alarm_permission_denied")
                } else { String(localized: "status_permission_denied") }
                scheduleErrorMessage = statusMessage
                return
            }
            if settings.usesDatedSchedule || keepDated {
                try await registerCalendar(settings: settings, refreshWeather: false)
            } else {
                try await restoreWeeklySchedule()
            }
            succeeded = true
        } catch {
            if settings.isDisasterSuspensionEnabled || scheduledFingerprint?.disasterSettings != nil {
                disasterScheduleNeedsAttention = true
                await previewScheduler.cancelPreviews()
            }
            updateScheduleStaleness()
            statusMessage = String.localizedStringWithFormat(String(localized: "status_schedule_failed"), Self.userFacingMessage(for: error))
            scheduleErrorMessage = statusMessage
        }
    }

    private func finishScheduling() {
        isScheduling = false
        if pendingHolidayUpdate || pendingDisasterUpdate {
            pendingHolidayUpdate = false
            pendingDisasterUpdate = false
            Task { await applyCalendarSettings() }
        }
    }

    private func restoreWeeklySchedule(settings frozen: CommuteAlarmSettings? = nil) async throws {
        let snapshot = frozen ?? effectiveSchedulingSettings
        let previous = scheduledAlarmSummary
        let probability = previous?.maximumPrecipitationProbability ?? 0
        var summary = AlarmTimeCalculator.nextAlarmDateForWeatherCheck(alarmTime: snapshot.alarmTime,
            leadTimeMinutes: snapshot.rainLeadTimeMinutes, shouldApplyLeadTime: probability >= snapshot.rainProbabilityThreshold,
            rainProbabilityThreshold: snapshot.rainProbabilityThreshold, maximumPrecipitationProbability: probability,
            selectedWeekdays: snapshot.selectedWeekdays)
        let now = Date()
        let base = CalendarAlarmPlan.make(settings: snapshot, holidays: holidayCalendar, rain: false, now: now, days: 8)
        if let next = base.occurrences.first {
            // Undoing a skip: the skipped morning's own forecast, kept through the skip.
            let saved = previous?.skippedMorningForecast.flatMap { $0.normalDate == next.normalDate ? $0 : nil }
            // A weekly summary's own normal date may have been rolled on (a relaunch after its
            // early ring); the morning its forecast decided is `decidedNormalAlarmDate`.
            let hasSameForecast = saved != nil || previous?.calendarForecastDate == next.normalDate
                || (previous?.calendarPlan == nil && previous?.decidedNormalAlarmDate == next.normalDate)
            let probability = saved?.probability ?? probability
            let earlier = next.normalDate.addingTimeInterval(Double(-snapshot.rainLeadTimeMinutes * 60))
            let rain = hasSameForecast && probability >= snapshot.rainProbabilityThreshold && earlier > now
            // This morning already rang early: the one repeating clock time stays on that
            // ring, which has passed. The normal time would ring the same morning again.
            // Read from the registration as a relaunch reads it: held since an earlier
            // morning, the weekly repeat's ring for this one is not recognised otherwise.
            let rang = registeredSummary(now: now)?.earlyRingThatWentOff(forMorning: next.normalDate, now: now)
            summary.normalAlarmDate = next.normalDate
            summary.scheduledAlarmDate = rang?.ringDate ?? (rain ? earlier : next.normalDate)
            summary.weatherRefreshDate = earlier
            summary.exceedsRainThreshold = rain || rang != nil
            summary.leadTimeMinutes = rang.map { Int(next.normalDate.timeIntervalSince($0.ringDate) / 60) }
                ?? (rain ? snapshot.rainLeadTimeMinutes : 0)
            summary.maximumPrecipitationProbability = hasSameForecast ? probability : 0
            summary.firedEarlyRing = rang
            // This registration describes `next`: a rain lead only survives `hasSameForecast`
            // (this very morning's forecast), and a ring that already went off (`rang`) is this
            // morning's own, whichever forecast decided it. Rolling never moves this date, so
            // the lead reads as carried over on the mornings after it (D-D).
            summary.decisionNormalAlarmDate = next.normalDate
        } else {
            // No selected day ahead: whatever lead remains is the previous decision's.
            summary.decisionNormalAlarmDate = previous?.decisionNormalAlarmDate ?? previous?.normalAlarmDate
        }
        let selectedSound = snapshot.soundSelection(ringDate: summary.scheduledAlarmDate, normalDate: summary.normalAlarmDate)
        guard settings.isAlarmEnabled else { return }
        try await notificationScheduler.scheduleAlarm(at: summary.scheduledAlarmDate, normalAlarmDate: summary.normalAlarmDate,
            weekdays: snapshot.selectedWeekdays, sound: selectedSound.sound, soundFileNameOverride: selectedSound.fileNameOverride,
            snoozeMinutes: snapshot.effectiveSnoozeMinutes, title: String(localized: "notification_title"), body: String(localized: "notification_body_normal"))
        scheduledAlarmSummary = summary
        scheduledFingerprint = snapshot.scheduleFingerprint()
        updateScheduleStaleness()
        updateAlarmKitRescheduleNotice()
        statusMessage = String(localized: "status_alarm_scheduled")
        // Inside this morning's window its check point has been answered; aim at the next.
        BackgroundWeatherRefresh.scheduleNextRun(before: summary.weatherRefreshDate > now
            ? summary.weatherRefreshDate : nextWeatherCheckDate(for: snapshot, now: now))
        await CalendarCoverageReminder.cancel()
        await replanEveningPreviews(requestingAuthorization: !isRunningUnattended)
    }

    /// `CalendarAlarmPlan.make` without the morning whose early (rain) ring already went
    /// off, plus that ring. Its normal-time ring must not come back — however many times
    /// the plan is re-registered, and whether or not a relaunch has rolled the summary on —
    /// and a closure announced after that ring has nothing left to skip. Registration, the
    /// closure refresh and its receipt all start here, so the skips they compare stay equal.
    private func datedBasePlan(settings: CommuteAlarmSettings, now: Date)
        -> (plan: CalendarAlarmPlan, firedEarlyRing: CalendarAlarmPlan.Occurrence?) {
        var plan = CalendarAlarmPlan.make(settings: settings, holidays: holidayCalendar, rain: false, now: now, days: Self.calendarHorizonDays)
        // A weekly registration being replaced (the one-time skip, a calendar edit) is read as
        // a relaunch reads it, so the weekly repeat's early ring this morning is found too.
        guard let summary = registeredSummary(now: now) else { return (plan, nil) }
        var fired = summary.firedEarlyRing.flatMap { $0.normalDate > now ? $0 : nil }
        plan.occurrences.removeAll { occurrence in
            guard let ring = summary.earlyRingThatWentOff(forMorning: occurrence.normalDate, now: now) else { return false }
            fired = ring
            return true
        }
        return (plan, fired)
    }

    private func registerCalendar(settings snapshot: CommuteAlarmSettings, refreshWeather: Bool) async throws {
        let now = Date()
        let previous = scheduledAlarmSummary
        let base = datedBasePlan(settings: snapshot, now: now)
        var plan = base.plan
        let firedEarlyRing = base.firedEarlyRing
        let appliedFeed = disasterRefreshFailed ? nil : disasterFeed
        let filtered = DisasterAlarmPlan.filtering(plan, settings: snapshot,
            feed: appliedFeed, now: now)
        plan = filtered.plan
        var next = plan.occurrences.first
        var probability = 0.0
        var rain = false
        var place: String?
        var checkedAt: Date?
        var forecastDate: Date?
        if let next, let previous,
           previous.calendarForecastDate == next.normalDate
            || (previous.calendarPlan == nil && previous.decidedNormalAlarmDate == next.normalDate) {
            forecastDate = next.normalDate
            probability = previous.maximumPrecipitationProbability
            rain = probability >= snapshot.rainProbabilityThreshold
            place = previous.wettestSegmentName
        } else if let next, let saved = previous?.skippedMorningForecast, saved.normalDate == next.normalDate {
            // Undoing a skip: the morning comes back with the decision it had.
            forecastDate = next.normalDate
            probability = saved.probability
            rain = probability >= snapshot.rainProbabilityThreshold
            place = saved.place
        }
        // A live skip keeps the skipped morning's forecast for a later undo.
        let skippedMorning = CalendarAlarmPlan.skippedNormalDate(settings: snapshot, holidays: holidayCalendar, now: now)
        var skippedMorningForecast: SkippedMorningForecast?
        if let skippedMorning, let previous {
            if let kept = previous.skippedMorningForecast, kept.normalDate == skippedMorning {
                skippedMorningForecast = kept
            } else if previous.calendarForecastDate == skippedMorning
                        || (previous.calendarPlan == nil && previous.decidedNormalAlarmDate == skippedMorning) {
                // Only the skipped morning's own decision: a lead the weekly repeat carried onto
                // it (a relaunch rolled `normalAlarmDate` there) must not come back on undo (D-D).
                skippedMorningForecast = .init(normalDate: skippedMorning, probability: previous.maximumPrecipitationProbability,
                                               place: previous.wettestSegmentName)
            }
        }
        if refreshWeather, let next {
            do {
                let checkDate = next.normalDate.addingTimeInterval(Double(-snapshot.rainLeadTimeMinutes * 60))
                let service = routeWeatherService
                let timeout = calendarWeatherTimeout
                let weather = try await withThrowingTaskGroup(of: RouteWeatherSnapshot.self) { group in
                    group.addTask {
                        try await service.fetchRouteWeather(from: snapshot.homeAddress, homeLocation: snapshot.homeResolvedLocation,
                            to: snapshot.workAddress, workLocation: snapshot.workResolvedLocation, mode: snapshot.commuteMode, around: checkDate)
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                probability = weather.maximumPrecipitationProbability
                rain = weather.exceedsRainThreshold(snapshot.rainProbabilityThreshold)
                place = weather.segments.max { $0.precipitationProbability < $1.precipitationProbability }?.name
                checkedAt = weather.checkedAt
                forecastDate = next.normalDate
                routeWeatherSnapshot = weather
            } catch {
                try Task.checkCancellation()
                // Date exceptions still apply when the forecast cannot update.
            }
        }
        // Network work may have crossed the normal alarm minute. Never submit a
        // fixed alarm in the past or attach that forecast to the following day.
        plan.occurrences.removeAll { $0.ringDate <= Date() }
        next = plan.occurrences.first
        if forecastDate != next?.normalDate {
            forecastDate = nil; rain = false; probability = 0; place = nil
        }
        // Only the next occurrence has a forecast; later dates retain normal time
        // until a foreground/background run evaluates their own morning.
        if rain, let next {
            let earlier = next.normalDate.addingTimeInterval(Double(-snapshot.rainLeadTimeMinutes * 60))
            if earlier > Date() { plan.occurrences[0].ringDate = earlier } else { rain = false }
        }
        plan.applySounds(from: snapshot)
        guard settings.isAlarmEnabled else { return }
        try await notificationScheduler.scheduleCalendar(plan, sound: snapshot.alarmSound, soundFileNameOverride: snapshot.soundFileNameOverride,
            snoozeMinutes: snapshot.effectiveSnoozeMinutes, title: String(localized: "notification_title"), body: String(localized: "notification_body_normal"))
        let normal = next?.normalDate ?? plan.coveredUntil
        let summary = ScheduledAlarmSummary(normalAlarmDate: normal, scheduledAlarmDate: plan.occurrences.first?.ringDate ?? normal,
            weatherRefreshDate: normal.addingTimeInterval(Double(-snapshot.rainLeadTimeMinutes * 60)), exceedsRainThreshold: rain,
            leadTimeMinutes: rain ? snapshot.rainLeadTimeMinutes : 0, rainProbabilityThreshold: snapshot.rainProbabilityThreshold,
            maximumPrecipitationProbability: probability, wettestSegmentName: place, calendarPlan: plan, calendarForecastDate: forecastDate)
        var committedSummary = summary
        committedSummary.disasterSkips = filtered.skips
        committedSummary.firedEarlyRing = firedEarlyRing
        committedSummary.userSkippedNormalDate = skippedMorning
        committedSummary.skippedMorningForecast = skippedMorningForecast
        scheduledAlarmSummary = committedSummary
        scheduledFingerprint = snapshot.scheduleFingerprint()
        if let checkedAt { lastWeatherEvaluationAt = checkedAt }
        updateScheduleStaleness()
        updateAlarmKitRescheduleNotice()
        statusMessage = String(localized: plan.occurrences.isEmpty ? "calendar_all_silent" : "calendar_schedule_saved")
        let nextRefresh = min(summary.weatherRefreshDate, now.addingTimeInterval(24 * 3_600))
        BackgroundWeatherRefresh.scheduleNextRun(before: nextRefresh, now: now)
        await replanEveningPreviews(requestingAuthorization: !isRunningUnattended, summary: committedSummary, settings: snapshot, now: now)
        await CalendarCoverageReminder.replace(coveredUntil: plan.coveredUntil,
            keepsWeeklyAlarm: !snapshot.calendarSettings.isActive && !snapshot.isDisasterSuspensionEnabled)
        if isRunningUnattended, snapshot.isEveningPreviewEnabled, let previous,
           Calendar.current.isDate(previous.normalAlarmDate, equalTo: normal, toGranularity: .minute),
           abs(previous.scheduledAlarmDate.timeIntervalSince(summary.scheduledAlarmDate)) >= 60 {
            await previewScheduler.notifyDecisionChange(.init(normalAlarmDate: normal, previousRingDate: previous.scheduledAlarmDate,
                newRingDate: summary.scheduledAlarmDate, maximumProbability: probability, threshold: snapshot.rainProbabilityThreshold, place: place, timeFormat: settings.timeFormat))
        }
        await reportDisasterSync(feed: appliedFeed, committedDuringScheduling: true)
    }

    private func nextWeatherCheckDate(for settings: CommuteAlarmSettings, now: Date = Date()) -> Date {
        if settings.usesDatedSchedule {
            let plan = CalendarAlarmPlan.make(settings: settings, holidays: holidayCalendar, rain: true, now: now, days: Self.calendarHorizonDays)
            return plan.occurrences.first?.ringDate ?? now.addingTimeInterval(24 * 3_600)
        }
        return AlarmTimeCalculator.nextAlarmDateForWeatherCheck(
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
        mirrorDayOffSharedState()
    }

    private func saveScheduledAlarmSummary() {
        defer { mirrorDayOffSharedState() }
        guard let summary = scheduledAlarmSummary else {
            settingsStorage.removeObject(forKey: Self.scheduledSummaryStorageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(summary) else {
            return
        }

        settingsStorage.set(data, forKey: Self.scheduledSummaryStorageKey)
    }

    /// What the notification service extension may read while the app is closed:
    /// the *effective* disaster rules (so the release gate and membership
    /// gates apply there too), the next alarm's normal date, and the next few
    /// scheduled normal dates including those already skipped for a closure — a
    /// repeat announcement for a skipped day must still be recognised. Never addresses.
    private func mirrorDayOffSharedState() {
        guard !AppEnvironment.isRunningTests else { return }
        let effective = effectiveSchedulingSettings
        let now = Date()
        let dates = scheduledAlarmSummary?.dayOffAlarmDates(after: now)
        DayOffSharedState(enabled: effective.isDisasterSuspensionEnabled,
                          observesWork: effective.observesWorkSuspensions,
                          observesSchool: effective.observesSchoolSuspensions,
                          home: effective.homeSuspensionRegion,
                          destination: effective.workSuspensionRegion,
                          normalAlarmDate: scheduledAlarmSummary?.normalAlarmDate,
                          serviceURL: AppEnvironment.dayOffServiceURL,
                          updatedAt: now,
                          upcomingNormalAlarmDates: dates?.upcoming,
                          skippedNormalAlarmDates: dates?.skipped,
                          keptNormalAlarmDates: dates?.upcoming.filter {
                              effective.calendarSettings.forcesRing(on: $0) && !(dates?.userSkipped.contains($0) ?? false)
                          },
                          alarmOff: effective.isAlarmEnabled ? nil : true,
                          userSkippedNormalAlarmDates: dates?.userSkipped).save()
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
