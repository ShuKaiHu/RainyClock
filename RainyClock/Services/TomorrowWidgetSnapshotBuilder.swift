import Foundation

/// Maps the tomorrow card to widget data. The selection rules here are ALSO what
/// ContentView's AlarmHomeView renders (scheduleIssue / weatherNotice / reason),
/// so the widget says what the card says by construction.
///
/// Snapshot semantics:
/// - Every entry is exactly what the card would show at its `validFrom`. The model
///   rolls a weekly summary forward inside `tomorrowStatus(now:)`, ring and normal time
///   as one pair, so a process that stays alive and a relaunch agree.
/// - Card flags (the scheduling error, the AlarmKit reschedule notice and the stale
///   schedule) carry forward unchanged, so the widget never drops a warning the app
///   has not cleared.
/// - A typical 36–48 h window yields about 5 to 12 entries, around 5 KB.
@MainActor
enum TomorrowWidgetSnapshotBuilder {
    static let maximumEntries = 24
    static let epsilon: TimeInterval = 1

    struct CardFlags: Equatable, Sendable {
        var hasSchedulingError = false        // model.scheduleErrorMessage != nil (text never copied)
        var requiresAlarmKitReschedule = false
        var closureScheduleUncertain = false  // AppEnvironment.supportsTemporaryClosures && model.disasterScheduleNeedsAttention
        var closureRefreshFailed = false      // effective isDisasterSuspensionEnabled && model.disasterRefreshFailed
        var isScheduleStale = false
        var isScheduling = false

        init(hasSchedulingError: Bool = false, requiresAlarmKitReschedule: Bool = false, closureScheduleUncertain: Bool = false,
             closureRefreshFailed: Bool = false, isScheduleStale: Bool = false, isScheduling: Bool = false) {
            self.hasSchedulingError = hasSchedulingError
            self.requiresAlarmKitReschedule = requiresAlarmKitReschedule
            self.closureScheduleUncertain = closureScheduleUncertain
            self.closureRefreshFailed = closureRefreshFailed
            self.isScheduleStale = isScheduleStale
            self.isScheduling = isScheduling
        }

        @MainActor
        init(model: AlarmViewModel) {
            self.init(hasSchedulingError: model.scheduleErrorMessage != nil,
                      requiresAlarmKitReschedule: model.requiresAlarmKitReschedule,
                      closureScheduleUncertain: AppEnvironment.supportsTemporaryClosures && model.disasterScheduleNeedsAttention,
                      closureRefreshFailed: model.effectiveSchedulingSettings.isDisasterSuspensionEnabled && model.disasterRefreshFailed,
                      isScheduleStale: model.isScheduleStale,
                      isScheduling: model.isScheduling)
        }
    }

    struct Context: Sendable {
        var calendar: Calendar                       // AlarmCalendarSettings.calendar in production
        var clockFormat: ClockTimeFormat
        var mode: TomorrowWidgetSnapshot.CommuteMode
        var addressesMissing: Bool                   // raw home or work address trimmed empty (the card's routeIncomplete)
        var flags: CardFlags
        var rainLeadTimeMinutes: Int                 // effective settings
        var ringAnchors: [Date]                      // summary ring/normal dates and calendar-plan occurrences
    }

    // MARK: Card rules (ContentView uses these)

    /// The card's line in the UI's `language`: it decides whether a Taiwan holiday keeps
    /// its Chinese name, see `HolidayDisplayName`.
    static func reasonLine(for status: TomorrowAlarmStatus,
                           language: String = Bundle.main.preferredLocalizations.first ?? "en")
        -> TomorrowWidgetSnapshot.ReasonLine? {
        snapshotReasonLine(for: status)?.displayed(in: language)
    }

    /// What the snapshot stores: a holiday keeps DGPA's own name, and the widget names it
    /// in the language it renders in (`TomorrowWidgetPresentation`), so a language switch
    /// never leaves the other language's name on it until the app next publishes.
    static func snapshotReasonLine(for status: TomorrowAlarmStatus) -> TomorrowWidgetSnapshot.ReasonLine? {
        switch status.reason {
        case .normal: nil
        case .rain:
            if let weather = status.weather, !status.weatherIsStale {
                .rainForecast(percent: Int((weather.maximumPrecipitationProbability * 100).rounded()),
                              minutes: status.leadTimeMinutes)
            } else {
                .rainEarlier(minutes: status.leadTimeMinutes)
            }
        case .holiday:
            if let name = status.holidayName, !name.isEmpty { .holidayNamed(name) } else { .holiday }
        case .manual: status.expectedRingDate == nil ? .manualSkip : .manualRing
        case .weekend: .weekend
        case .unselectedWeekday: .unselectedWeekday
        case .disaster: .closure
        case .routeIncomplete: .routeNeeded
        }
    }

    static func weatherNotice(for status: TomorrowAlarmStatus, addressesMissing: Bool) -> TomorrowWidgetSnapshot.WeatherNotice? {
        if status.weatherRefreshFailed { return .failed }
        if status.weatherIsStale { return .stale }
        if status.weather == nil { return addressesMissing ? .routeNeeded : .noForecast }
        return nil
    }

    /// First match wins. `isScheduleVerified` is deliberately never read: the card
    /// never displays it.
    static func scheduleIssue(for status: TomorrowAlarmStatus, flags: CardFlags) -> TomorrowWidgetSnapshot.ScheduleIssue? {
        if flags.hasSchedulingError { return .schedulingFailed }
        if flags.requiresAlarmKitReschedule { return .alarmKitReschedule }
        if flags.closureScheduleUncertain { return .closureUncertain }
        if flags.closureRefreshFailed { return .closureUpdateFailed }
        if flags.isScheduleStale && !flags.isScheduling { return .updateNeeded }
        if !flags.isScheduling, let registered = status.registeredRingDate, registered != status.expectedRingDate {
            return .updateNeeded
        }
        return nil
    }

    /// Endpoints only, as CommuteWeatherCard shows them. Segment names and ids are never read.
    static func forecast(from weather: RouteWeatherSnapshot?) -> TomorrowWidgetSnapshot.RouteForecast? {
        guard let weather, let first = weather.segments.first else { return nil }
        func endpoint(_ segment: RouteWeatherSegment) -> TomorrowWidgetSnapshot.Endpoint {
            .init(condition: condition(segment.condition), percent: percent(segment.precipitationProbability))
        }
        return .init(checkedAt: weather.checkedAt, home: endpoint(first),
                     work: weather.segments.count >= 2 ? weather.segments.last.map(endpoint) : nil,
                     maximumPercent: percent(weather.maximumPrecipitationProbability))
    }

    static func entry(for status: TomorrowAlarmStatus, context: Context, validFrom: Date) -> TomorrowWidgetSnapshot.Entry {
        let reason: TomorrowWidgetSnapshot.Reason = switch status.reason {
        case .normal: .normal
        case .rain: .rain
        case .holiday: .holiday
        case .manual: .manual
        case .weekend: .weekend
        case .unselectedWeekday: .unselectedWeekday
        case .disaster: .disaster
        case .routeIncomplete: .routeIncomplete
        }
        return .init(validFrom: validFrom, day: status.day, normalAlarmDate: status.normalAlarmDate,
                     expectedRingDate: status.expectedRingDate,
                     ringIsOnAnotherDay: status.expectedRingDate.map { !context.calendar.isDate($0, inSameDayAs: status.day) } ?? false,
                     reason: reason, reasonLine: snapshotReasonLine(for: status), leadTimeMinutes: status.leadTimeMinutes,
                     forecast: forecast(from: status.weather),
                     weatherNotice: weatherNotice(for: status, addressesMissing: context.addressesMissing),
                     scheduleIssue: scheduleIssue(for: status, flags: context.flags))
    }

    // MARK: Timeline

    /// The second local midnight after `now`: with no app or background run for over
    /// a day no morning has been decided, so "open the app" is the honest message.
    static func expiresAt(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(2 * 86_400)
    }

    /// Sorted, unique moments in (now, expiresAt) where the card's content can change.
    /// Over-generating is fine: identical neighbours are merged by `snapshot`.
    static func boundaries(now: Date, first: TomorrowAlarmStatus, atFirstMidnight: TomorrowAlarmStatus,
                           context: Context, expiresAt: Date) -> [Date] {
        let calendar = context.calendar
        let day0 = calendar.startOfDay(for: now)
        let days = (0...2).compactMap { calendar.date(byAdding: .day, value: $0, to: day0) }
        var candidates: [Date] = []
        // "Tomorrow" moves on; weather and the failure flag drop because the request changes.
        if days.count > 1 { candidates.append(days[1]) }
        // Staleness is a strict `>` against weatherLifetime.
        if let checkedAt = first.weather?.checkedAt {
            candidates.append(checkedAt.addingTimeInterval(TomorrowAlarmStatus.weatherLifetime + epsilon))
        }
        // The `earlier > now` guard: matters only for leads that cross midnight.
        for normal in [first.normalAlarmDate, atFirstMidnight.normalAlarmDate] {
            candidates.append(normal.addingTimeInterval(-Double(context.rainLeadTimeMinutes) * 60 + epsilon))
        }
        // Where `rollingForwardAsPair` changes the rolled summary (a ring passing).
        for anchor in context.ringAnchors {
            candidates.append(anchor.addingTimeInterval(epsilon))
            let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)
            for day in days {
                if let projected = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                                 second: time.second ?? 0, of: day) {
                    candidates.append(projected.addingTimeInterval(epsilon))
                }
            }
        }
        // Each point is also emitted exactly, not only ε after: the roll already
        // moves a past date on at the projected time itself (its next candidate must be
        // `> now`), and the `earlier > now` guard flips at `earlier`. Without the exact
        // point the widget would lag the card by up to ε.
        let points = candidates.flatMap { [$0.addingTimeInterval(-epsilon), $0] }
        return Set(points.filter { $0 > now && $0 < expiresAt }).sorted()
    }

    static func snapshot(now: Date, context: Context, status: (Date) -> TomorrowAlarmStatus) -> TomorrowWidgetSnapshot {
        let expires = expiresAt(now: now, calendar: context.calendar)
        let first = status(now)
        let midnight = context.calendar.date(byAdding: .day, value: 1, to: context.calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        let atMidnight = status(midnight)
        var entries = [entry(for: first, context: context, validFrom: now)]
        var cutoff = expires
        for moment in boundaries(now: now, first: first, atFirstMidnight: atMidnight, context: context, expiresAt: expires) {
            let next = entry(for: status(moment), context: context, validFrom: moment)
            if let last = entries.last, next.hasSameContent(as: last) { continue }
            // Never let the last entry outlive its truth: stop the snapshot where it would change.
            if entries.count == maximumEntries { cutoff = moment; break }
            entries.append(next)
        }
        return TomorrowWidgetSnapshot(version: TomorrowWidgetSnapshot.currentVersion, publishedAt: now,
                                      timeZoneID: context.calendar.timeZone.identifier,
                                      clockFormat: context.clockFormat, mode: context.mode,
                                      expiresAt: cutoff, entries: entries)
    }

    // MARK: Model adapter

    /// `flags.isScheduling` is forced false: an in-flight registration then reads as
    /// "not updated yet", which is literally true, and the republish that follows fixes it.
    static func context(for model: AlarmViewModel) -> Context {
        let settings = model.settings
        let effective = model.effectiveSchedulingSettings
        var flags = CardFlags(model: model)
        flags.isScheduling = false
        var anchors: [Date] = []
        if let summary = model.scheduledAlarmSummary {
            anchors += [summary.scheduledAlarmDate, summary.normalAlarmDate]
            for occurrence in summary.calendarPlan?.occurrences ?? [] {
                anchors += [occurrence.ringDate, occurrence.normalDate]
            }
        }
        return Context(
            calendar: AlarmCalendarSettings.calendar,
            clockFormat: settings.timeFormat,
            mode: TomorrowWidgetSnapshot.CommuteMode(rawValue: settings.commuteMode.rawValue) ?? .car,
            addressesMissing: settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            flags: flags,
            rainLeadTimeMinutes: effective.rainLeadTimeMinutes,
            ringAnchors: anchors)
    }

    static func snapshot(for model: AlarmViewModel, now: Date = Date()) -> TomorrowWidgetSnapshot {
        snapshot(now: now, context: context(for: model)) { model.tomorrowStatus(now: $0) }
    }

    private static func percent(_ probability: Double) -> Int {
        Int((probability * 100).rounded())
    }

    private static func condition(_ condition: RouteWeatherSegment.Condition) -> TomorrowWidgetSnapshot.Condition {
        switch condition {
        case .clear: .clear
        case .cloudy: .cloudy
        case .rain: .rain
        }
    }
}
