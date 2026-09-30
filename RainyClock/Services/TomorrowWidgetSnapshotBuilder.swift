import Foundation

/// Maps the Alarm page card to widget data. The selection rules here are ALSO what
/// ContentView's AlarmHomeView renders (scheduleIssue / weatherNotice / reason),
/// so the widget says what the card says by construction.
///
/// Snapshot semantics:
/// - Every entry is what the card would show about that morning at its `validFrom`,
///   resolved by the same `TomorrowAlarmStatus.resolve` from the same pair-rolled summary,
///   with these deliberate differences:
/// - Staleness (D-B): the widget only warns that the weather is stale once it is older than
///   `widgetWeatherLifetime` (3 h), where the card warns after
///   `TomorrowAlarmStatus.weatherLifetime` (30 min). A widget sits on a screen all day and
///   cannot refresh anything itself; the card is looked at for seconds and refreshes on
///   sight. The decision (ring time, reason) is the card's either way.
/// - Which morning (D-C, kept after the card's 2026-09-29 rule): the widget names calendar
///   days. Between local midnight and today's ring (or, for a day that does not ring, its
///   normal time) it shows TODAY's alarm (`todayStatus(now:)`), labelled 今天 / Today; one
///   second after the ring (inclusive) it shows calendar tomorrow
///   (`calendarTomorrowStatus(now:)`). The card now also describes today after midnight
///   (the coming morning), but under the header 下次鬧鐘 / Next alarm, and it stays on today
///   until the NORMAL time, saying 已響鈴 / Rang at between an early ring and it; the
///   widget has moved on to tomorrow by then. Today's entries carry no forecast (see
///   `todayWeatherNotice`), and the time is what AlarmKit will ring: the registered ring,
///   or an outdated registration's still armed for today, flagged "update needed".
/// - A ring that already fired the evening before its day (a rain lead across midnight,
///   e.g. 00:10 rung at 23:40) is not replaced by a later time AlarmKit will not fire;
///   until midnight the widget keeps the entry it showed before that ring.
/// - After its ring the card's rain line never shows a percentage (both), and a carried-over
///   lead that has rung reads 因雨提早 on the card only (`ContentView`): no widget entry
///   describes a morning after its ring.
/// - Card flags (the scheduling error, the AlarmKit reschedule notice and the stale
///   schedule) carry forward unchanged, so the widget never drops a warning the app
///   has not cleared (a today entry the committed schedule lacks stays, flagged, until its
///   normal time, as on the card: `todayShownUntil`).
/// - Alarm off: no stale or failed weather notice. On the widget it would badge 鬧鐘已關閉,
///   where only a failure to turn off may warn; the card's weather card still says its
///   weather is old, beside a card that shows no warning.
/// - A closure carries the feed's own update time (`Context.closureSourceUpdatedAt`), which
///   the widget prints beside the source, as the card does (DAYOFF-SPEC §7).
/// - A typical 36–48 h window yields about 5 to 12 entries, around 5 KB.
@MainActor
enum TomorrowWidgetSnapshotBuilder {
    static let maximumEntries = 24
    static let epsilon: TimeInterval = 1
    /// How old the weather may get before the WIDGET says it needs an update (D-B). Display
    /// only: `TomorrowAlarmStatus.resolve` still decides with its own 30-minute lifetime.
    static let widgetWeatherLifetime: TimeInterval = 3 * 3_600

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
        /// The closure feed's own update time (`DisasterFeed.sourceUpdatedAt`), which the card
        /// prints under a closure beside the source (DAYOFF-SPEC §7). Closure entries carry it.
        var closureSourceUpdatedAt: Date? = nil
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
            if status.rainLeadIsCarriedOver {
                .awaitingForecast
            } else if !status.hasRung, let weather = status.weather, !status.weatherIsStale {
                // After the ring a newer forecast must not print a percentage that contradicts it.
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
        case .alarmOff: .alarmOff
        case .skippedOnce: .skippedOnce
        }
    }

    static func weatherNotice(for status: TomorrowAlarmStatus, addressesMissing: Bool) -> TomorrowWidgetSnapshot.WeatherNotice? {
        if status.weatherRefreshFailed { return .failed }
        if status.weatherIsStale { return .stale }
        if status.weather == nil { return addressesMissing ? .routeNeeded : .noForecast }
        return nil
    }

    /// The card's notice, except that weather counts as stale only once it is older than
    /// `widgetWeatherLifetime` at `moment` (the entry's `validFrom`). A failed refresh still
    /// says so at once, as on the card: that is not about age.
    static func widgetWeatherNotice(for status: TomorrowAlarmStatus, addressesMissing: Bool,
                                    at moment: Date) -> TomorrowWidgetSnapshot.WeatherNotice? {
        if status.weatherRefreshFailed { return .failed }
        if let weather = status.weather {
            return moment.timeIntervalSince(weather.checkedAt) > widgetWeatherLifetime ? .stale : nil
        }
        return addressesMissing ? .routeNeeded : .noForecast
    }

    /// First match wins. `isScheduleVerified` is deliberately never read: the card
    /// never displays it.
    static func scheduleIssue(for status: TomorrowAlarmStatus, flags: CardFlags) -> TomorrowWidgetSnapshot.ScheduleIssue? {
        // Off: only a failure to turn off is worth a banner; every other notice is about an
        // alarm the user chose not to have.
        if status.reason == .alarmOff { return flags.hasSchedulingError ? .schedulingFailed : nil }
        if flags.hasSchedulingError { return .schedulingFailed }
        if flags.requiresAlarmKitReschedule { return .alarmKitReschedule }
        if flags.closureScheduleUncertain { return .closureUncertain }
        if flags.closureRefreshFailed { return .closureUpdateFailed }
        if flags.isScheduleStale && !flags.isScheduling { return .updateNeeded }
        if !flags.isScheduling, let registered = status.registeredRingDate, registered != status.expectedRingDate {
            return .updateNeeded
        }
        // The card expects a ring the committed schedule does not hold: a closure skip the
        // live preview no longer supports, or a plan that lost the morning.
        if !flags.isScheduling, status.ringIsNotRegistered { return .updateNeeded }
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

    /// Today's entries carry no forecast and no weather notice except "complete your route".
    /// The app only ever fetches tomorrow's forecast: the one that decided today is last
    /// evening's, hours old by midnight, and nothing can refresh it (a stale warning nobody
    /// could clear), while the card's other notices name 明天. Today's decision is the
    /// registration's, which the reason line already states; the medium drops its weather
    /// column for these entries.
    static func todayWeatherNotice(for status: TomorrowAlarmStatus, addressesMissing: Bool) -> TomorrowWidgetSnapshot.WeatherNotice? {
        status.weather == nil && addressesMissing ? .routeNeeded : nil
    }

    /// The last moment a today entry is shown, for `status` = today's status at that moment.
    /// Inclusive: at that exact second the alarm is ringing, and the registration only rolls
    /// on to the next ring once this one is strictly past.
    /// - Today's registered ring: what AlarmKit fires, even where the forecast or a closure
    ///   now says otherwise (the entry then carries "update needed"). A weekly registration
    ///   made for a later morning still counts when today's slot of it is ahead.
    /// - An outdated registration (other settings; its replacement failed or was deferred)
    ///   still armed for today: its ring, which AlarmKit fires. Once that ring has fired,
    ///   today is over, whatever the new settings say.
    /// - A day that does not ring: its normal time.
    /// - A ring day the committed schedule does not hold although nothing explains the gap (a
    ///   closure skip the live notice no longer supports, a plan that lost the morning):
    ///   its normal time, as on the card, with "update needed" (`ringIsNotRegistered`). The
    ///   card's 鬧鐘設定尚未更新完成 must not vanish from the widget while AlarmKit skips a
    ///   morning that should ring.
    /// - A ring day whose current registration has no ring left for today: that ring has
    ///   fired (the weekly pair rolled on, the dated occurrence was consumed, or a lead
    ///   crossed midnight), so today is over; `.distantPast`.
    /// - Nothing registered: the configured time, which is all there is to show.
    /// - The master switch is off: no today entry at all, only "Alarm Off", which names no day.
    static func todayShownUntil(_ status: TomorrowAlarmStatus) -> Date {
        if status.reason == .alarmOff { return .distantPast }
        // Today's slot of the current registration is behind: it rang (a fired early ring, the
        // weekly repeat's slot), or a weekly registration for a later morning left none.
        if let passed = status.passedRingDate { return passed }
        if let registered = status.registeredRingDate { return registered }
        if let outdated = status.outdatedRegistrationRingDate { return outdated }
        if status.outdatedRegistrationHasRung { return .distantPast }
        guard let expected = status.expectedRingDate else { return status.normalAlarmDate }
        if status.ringIsNotRegistered { return max(expected, status.normalAlarmDate) }
        return status.isRegistrationCurrent ? .distantPast : expected
    }

    static func entry(for status: TomorrowAlarmStatus, context: Context, validFrom: Date,
                      isToday: Bool = false) -> TomorrowWidgetSnapshot.Entry {
        var entry = cardEntry(for: status, context: context, validFrom: validFrom, isToday: isToday)
        if isToday, let outdated = status.outdatedRegistrationRingDate ?? status.keptRingDate {
            // AlarmKit still holds the old registration and rings at its time today; the new
            // settings' decision is not registered. Show the ring that will happen, flagged.
            // The same for a kept early ring past today's check point under a raised lead.
            entry.expectedRingDate = outdated
            entry.ringIsOnAnotherDay = !context.calendar.isDate(outdated, inSameDayAs: status.day)
            entry.reason = .normal
            entry.reasonLine = nil
            entry.leadTimeMinutes = 0
            entry.scheduleIssue = entry.scheduleIssue ?? .updateNeeded
        }
        return entry
    }

    private static func cardEntry(for status: TomorrowAlarmStatus, context: Context, validFrom: Date,
                                  isToday: Bool) -> TomorrowWidgetSnapshot.Entry {
        let reason: TomorrowWidgetSnapshot.Reason = switch status.reason {
        case .normal: .normal
        case .rain: .rain
        case .holiday: .holiday
        case .manual: .manual
        case .weekend: .weekend
        case .unselectedWeekday: .unselectedWeekday
        case .disaster: .disaster
        case .routeIncomplete: .routeIncomplete
        case .alarmOff: .alarmOff
        case .skippedOnce: .skippedOnce
        }
        var weatherNotice = isToday ? todayWeatherNotice(for: status, addressesMissing: context.addressesMissing)
            : widgetWeatherNotice(for: status, addressesMissing: context.addressesMissing, at: validFrom)
        // Off (2026-10-01): only a failure to turn off warns. Stale or failed weather is about
        // a decision nobody asked for; it would put an orange badge on 鬧鐘已關閉.
        if status.reason == .alarmOff, weatherNotice == .stale || weatherNotice == .failed { weatherNotice = nil }
        return .init(validFrom: validFrom, isToday: isToday, day: status.day, normalAlarmDate: status.normalAlarmDate,
                     expectedRingDate: status.expectedRingDate,
                     ringIsOnAnotherDay: status.expectedRingDate.map { !context.calendar.isDate($0, inSameDayAs: status.day) } ?? false,
                     reason: reason, reasonLine: snapshotReasonLine(for: status), leadTimeMinutes: status.leadTimeMinutes,
                     forecast: isToday ? nil : forecast(from: status.weather),
                     weatherNotice: weatherNotice,
                     scheduleIssue: scheduleIssue(for: status, flags: context.flags),
                     closureSourceUpdatedAt: status.reason == .disaster ? context.closureSourceUpdatedAt : nil)
    }

    // MARK: Timeline

    /// The second local midnight after `now`: with no app or background run for over
    /// a day no morning has been decided, so "open the app" is the honest message.
    static func expiresAt(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(2 * 86_400)
    }

    /// Sorted, unique moments in (now, expiresAt) where the widget's content can change.
    /// Over-generating is fine: identical neighbours are merged by `snapshot`. `todays` are
    /// today's statuses at `now` and at the first midnight (none without a today provider).
    static func boundaries(now: Date, first: TomorrowAlarmStatus, atFirstMidnight: TomorrowAlarmStatus,
                           todays: [TomorrowAlarmStatus] = [], context: Context, expiresAt: Date) -> [Date] {
        let calendar = context.calendar
        let day0 = calendar.startOfDay(for: now)
        let days = (0...2).compactMap { calendar.date(byAdding: .day, value: $0, to: day0) }
        var candidates: [Date] = []
        // "Tomorrow" moves on; weather and the failure flag drop because the request changes.
        if days.count > 1 { candidates.append(days[1]) }
        // Staleness is a strict `>`: at weatherLifetime the decision stops reading the forecast
        // (the card's rule); at widgetWeatherLifetime the widget starts to warn.
        for checkedAt in ([first] + todays).compactMap(\.weather?.checkedAt) {
            candidates.append(checkedAt.addingTimeInterval(TomorrowAlarmStatus.weatherLifetime + epsilon))
            candidates.append(checkedAt.addingTimeInterval(widgetWeatherLifetime + epsilon))
        }
        // The `earlier > now` guard: matters only for leads that cross midnight.
        for normal in ([first, atFirstMidnight] + todays).map(\.normalAlarmDate) {
            candidates.append(normal.addingTimeInterval(-Double(context.rainLeadTimeMinutes) * 60 + epsilon))
        }
        // Today's entry ends after its ring (or normal time) second; the exact second too,
        // so the switch is never late by ε.
        for today in todays {
            candidates.append(todayShownUntil(today).addingTimeInterval(epsilon))
            candidates.append(today.normalAlarmDate.addingTimeInterval(epsilon))
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

    /// `status` resolves calendar tomorrow (`AlarmViewModel.calendarTomorrowStatus`), and
    /// `today` the day that has begun (`AlarmViewModel.todayStatus`); without it every entry
    /// describes tomorrow.
    static func snapshot(now: Date, context: Context, status: (Date) -> TomorrowAlarmStatus,
                         today: ((Date) -> TomorrowAlarmStatus)? = nil) -> TomorrowWidgetSnapshot {
        let expires = expiresAt(now: now, calendar: context.calendar)
        let first = status(now)
        let midnight = context.calendar.date(byAdding: .day, value: 1, to: context.calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        let atMidnight = status(midnight)
        let todays = today.map { provider in [now, midnight].map(provider) } ?? []
        func shown(at moment: Date) -> TomorrowWidgetSnapshot.Entry {
            if let today {
                let value = today(moment)
                if moment <= todayShownUntil(value) {
                    return entry(for: value, context: context, validFrom: moment, isToday: true)
                }
            }
            let value = moment == now ? first : status(moment)
            if let passed = value.passedRingDate {
                // Tomorrow's ring already fired this evening (its rain lead crossed midnight).
                // Until the day begins, and today's entry hands straight over to the day after,
                // keep saying what that ring was: never a later time AlarmKit will not fire.
                return entry(for: status(passed.addingTimeInterval(-epsilon)), context: context, validFrom: moment)
            }
            return entry(for: value, context: context, validFrom: moment)
        }
        var entries = [shown(at: now)]
        var cutoff = expires
        for moment in boundaries(now: now, first: first, atFirstMidnight: atMidnight, todays: todays,
                                 context: context, expiresAt: expires) {
            let next = shown(at: moment)
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
            // A morning dropped from the dated plan after its early ring still has a ring.
            if let fired = summary.firedEarlyRing { anchors += [fired.ringDate, fired.normalDate] }
        }
        return Context(
            calendar: AlarmCalendarSettings.calendar,
            clockFormat: settings.timeFormat,
            mode: TomorrowWidgetSnapshot.CommuteMode(rawValue: settings.commuteMode.rawValue) ?? .car,
            addressesMissing: settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            flags: flags,
            rainLeadTimeMinutes: effective.rainLeadTimeMinutes,
            ringAnchors: anchors,
            closureSourceUpdatedAt: model.disasterFeed?.sourceUpdatedAt)
    }

    /// Calendar days (D-C), not the card's coming morning: today until its ring, then
    /// calendar tomorrow.
    static func snapshot(for model: AlarmViewModel, now: Date = Date()) -> TomorrowWidgetSnapshot {
        snapshot(now: now, context: context(for: model), status: { model.calendarTomorrowStatus(now: $0) },
                 today: { model.todayStatus(now: $0) })
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
