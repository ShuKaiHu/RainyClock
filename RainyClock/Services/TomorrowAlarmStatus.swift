import Foundation

/// One morning's configured behavior, separate from system registration.
///
/// The card, and the forecast the app fetches, describe the coming morning: today's alarm
/// until its normal time has passed, then tomorrow's (`dayOffset: nil`). "Tomorrow" in these
/// type names predates that rule: until 2026-09-29 the card switched at midnight, and at
/// 00:39 it described Wednesday while the morning the user was about to sleep through (a
/// skipped Tuesday) appeared nowhere.
///
/// The Home Screen widget names calendar days instead (`dayOffset: 0` today, `1` tomorrow):
/// from midnight to today's ring it shows today, then tomorrow (D-C). Everything else is
/// the same rule and the same registration reading, so the card and the widget describe
/// one morning the same way; `TomorrowWidgetSnapshotBuilder` lists where they differ.
struct TomorrowAlarmStatus: Equatable {
    enum Reason: Equatable {
        case normal, rain, holiday, manual, weekend, unselectedWeekday, disaster, routeIncomplete
        /// The master switch is off (until the user turns it back on).
        case alarmOff
        /// The user turned off only this morning's alarm.
        case skippedOnce
    }

    var day: Date
    var normalAlarmDate: Date
    var expectedRingDate: Date?
    var reason: Reason
    var holidayName: String?
    var leadTimeMinutes: Int
    var weather: RouteWeatherSnapshot?
    var weatherIsStale: Bool
    var weatherRefreshFailed: Bool
    var registeredRingDate: Date?
    var isScheduleVerified: Bool
    var disasterNoticeIDs: [String]
    /// The described morning is today's (after midnight, before its normal time on the card).
    var isToday = false
    /// The described morning's alarm already went off (an early rain ring before the normal
    /// time, or, read from a rolled weekly summary, the repeat's slot for this morning).
    var hasRung = false
    /// The committed schedule skipped this morning for a closure — true even when the live
    /// preview no longer supports it, which the page must then flag instead of hiding.
    var hasCommittedClosureSkip = false
    /// A current dated plan covers this morning but holds no ring for it, and nothing
    /// (a closure skip, a one-time skip, an early ring that already went off) explains why.
    var isMissingFromPlan = false
    /// The early ring is the weekly repeat of an earlier morning's rain decision, rolled
    /// past that morning's ring, and no fresh forecast for this day has decided it yet.
    /// The time is still what AlarmKit will ring, so it stays; what it must not claim is
    /// that rain moved it (`TomorrowWidgetSnapshot.ReasonLine.awaitingForecast`).
    var rainLeadIsCarriedOver = false
    /// A registration exists and was made with these settings (the fingerprint matches).
    /// With it, a ring day that has no registered ring left has already rung.
    var isRegistrationCurrent = false
    /// This day's ring under the current registration is already behind `now`: it fired (a
    /// rain lead that crossed midnight rang the evening before, or the weekly repeat's slot
    /// for this morning), or a weekly registration made for a later morning left nothing
    /// for it. Nothing rings for this day again. The widget keeps saying what that ring was
    /// until the day begins, never a later time AlarmKit will not fire, and ends today there.
    var passedRingDate: Date?
    /// The ring a registration made with OTHER settings (the fingerprint no longer matches:
    /// a re-registration failed or was deferred) still fires on this day, still ahead of
    /// `now`. AlarmKit keeps that alarm until a replacement succeeds, so the widget's today
    /// entry shows it, with "update needed". Display only.
    var outdatedRegistrationRingDate: Date?
    /// The outdated registration's ring on this day has already fired: it will not ring again.
    var outdatedRegistrationHasRung = false
    /// A weekly registration's kept early ring (`firedEarlyRing`'s lead, carried onto this
    /// morning by the repeat) that is still ahead but no longer stands for this morning: its
    /// check point under the current lead has passed (a lead raised after that early ring), so
    /// `expectedRingDate` is the current settings' time and the mismatch reads "update needed".
    /// AlarmKit still rings it, so the widget's today entry shows it, flagged, as it shows an
    /// outdated registration's ring. Display only.
    var keptRingDate: Date?

    /// The card expects a ring the committed schedule does not hold for this morning.
    var ringIsNotRegistered: Bool {
        expectedRingDate != nil && (hasCommittedClosureSkip || isMissingFromPlan)
    }

    /// The card's (and the decision's) freshness rule. The widget only marks weather stale after
    /// `TomorrowWidgetSnapshotBuilder.widgetWeatherLifetime` and shows no warning for it (owner,
    /// 2026-10-09); this is unchanged by that.
    static let weatherLifetime: TimeInterval = 30 * 60

    /// `summary` is the registration as the model reads it: a weekly summary rolled forward
    /// as a pair (`ScheduledAlarmSummary.rollingForwardAsPair`), or one rolled a date at a
    /// time by a relaunch, or not rolled at all; each reads the same.
    static func resolve(settings: CommuteAlarmSettings, holidays: HolidayCalendar,
                        weatherRecord: TomorrowWeatherRecord?, weatherRefreshFailed: Bool,
                        routeIsReady: Bool = true,
                        summary: ScheduledAlarmSummary?, registeredFingerprint: AlarmScheduleFingerprint?,
                        disasterFeed: DisasterFeed?, disasterSourceFailed: Bool,
                        now: Date, calendar: Calendar = AlarmCalendarSettings.calendar, dayOffset: Int? = nil) -> Self {
        let request = TomorrowWeatherRequest(settings: settings, now: now, calendar: calendar, dayOffset: dayOffset)
        let day = calendar.startOfDay(for: request.normalAlarmDate)
        let decision = settings.calendarSettings.decision(on: day, weekdays: settings.selectedWeekdays,
                                                        holidays: holidays, calendar: calendar)
        let weather = weatherRecord.flatMap { record in
            record.request == request && record.isValid(at: now) ? record.snapshot : nil
        }
        let stale = weather.map { now.timeIntervalSince($0.checkedAt) > weatherLifetime } ?? false
        let freshWeather = stale ? nil : weather
        // Past this morning's check point the scheduler no longer re-decides rain.
        let decisionIsFinal = request.forecastDate <= now
        let key = AlarmCalendarSettings.key(for: day, calendar: calendar)
        let manualRing = settings.calendarSettings.isEnabled && settings.calendarSettings.overrides[key] == .ring
        let skippedByUser = settings.skippedAlarmDay == key
        var expected: Date? = decision.rings ? request.normalAlarmDate : nil
        var reason: Reason = .normal
        var holidayName: String?
        var lead = 0
        var noticeIDs: [String] = []

        // What the system actually holds for this morning. Read first: once the morning's
        // own ring has gone off, nothing announced or forecast afterwards may relabel it.
        let registrationIsCurrent = summary != nil && registeredFingerprint == settings.scheduleFingerprint(calendar: calendar)
        var registered: Date?
        var firedRing: Date?
        var passedRing: Date?
        var planCoversDay = false
        var committedSkip = false
        var missingFromPlan = false
        if registrationIsCurrent, let summary {
            committedSkip = summary.disasterSkips?.contains { $0.normalDate == request.normalAlarmDate } ?? false
            if let plan = summary.calendarPlan {
                if plan.timeZoneID == calendar.timeZone.identifier, plan.coveredUntil > request.normalAlarmDate {
                    planCoversDay = true
                    if let occurrence = plan.occurrences.first(where: { $0.normalDate == request.normalAlarmDate }) {
                        registered = occurrence.ringDate
                    } else if let fired = summary.firedEarlyRing, fired.normalDate == request.normalAlarmDate {
                        // Dropped by registerCalendar because its early ring already went off.
                        // The recorded time, not one rebuilt from the current lead.
                        registered = fired.ringDate
                        firedRing = fired.ringDate
                    } else if decision.rings, !committedSkip, !skippedByUser {
                        missingFromPlan = true
                    }
                    // A dated ring that has fired: this morning's early ring, or one the evening
                    // before (a lead across midnight).
                    if let ring = registered, ring < now { passedRing = ring }
                }
            } else if settings.selectedWeekdays.contains(calendar.component(.weekday, from: day)) {
                let clock = { (date: Date) in calendar.dateComponents([.hour, .minute], from: date) }
                if summary.normalAlarmDate == request.normalAlarmDate {
                    // Never roll another morning's summary or rain decision into this one. After a
                    // relaunch past an early ring, rollingForward has already moved scheduledAlarmDate
                    // to the next week's ring: read its clock time, not its day.
                    let scheduled = clock(summary.scheduledAlarmDate)
                    registered = scheduled == clock(request.normalAlarmDate) ? request.normalAlarmDate
                        : scheduled == clock(request.forecastDate) ? request.forecastDate : summary.scheduledAlarmDate
                } else if summary.normalAlarmDate > request.normalAlarmDate {
                    // The weekly repeat rings every selected day at the registration's clock time,
                    // so this morning has a slot of its own.
                    let slot = request.normalAlarmDate.addingTimeInterval(
                        -summary.normalAlarmDate.timeIntervalSince(summary.scheduledAlarmDate))
                    if slot >= now {
                        // Still ahead (inclusive, like the roll: at its own second a ring is still
                        // ahead). A registration made for a later morning — inside this morning's
                        // window, say — rings this morning at its clock time too.
                        registered = slot
                    } else if summary.decidedNormalAlarmDate <= request.normalAlarmDate {
                        // Behind, and the registration was in place for it: made for this morning
                        // (or an earlier one whose lead the repeat carried here), and the pair roll
                        // has moved past its ring. It rang; nothing rings for this morning again.
                        registered = slot
                        firedRing = slot
                        passedRing = slot
                    } else {
                        // Behind, and registered for a later morning after this slot had passed:
                        // nothing is left for this morning. The later ring makes the card flag the
                        // mismatch instead of promising one; the widget drops the morning.
                        registered = summary.scheduledAlarmDate
                        passedRing = slot
                    }
                }
            }
        }

        if !settings.isAlarmEnabled {
            expected = nil
            reason = .alarmOff
        } else if !decision.rings {
            switch decision.reason {
            case .manual: reason = .manual
            case .holiday:
                holidayName = holidays.day(on: day, source: settings.calendarSettings.source, calendar: calendar)?.name
                reason = calendar.isDateInWeekend(day) && (holidayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    ? .weekend : .holiday
            case .weekday, .unavailable:
                reason = calendar.isDateInWeekend(day) ? .weekend : .unselectedWeekday
            }
        } else if !request.hasRoute || !routeIsReady {
            expected = nil
            reason = .routeIncomplete
        } else if skippedByUser {
            expected = nil
            reason = .skippedOnce
        } else {
            reason = manualRing ? .manual : .normal
            // The same rule as DisasterAlarmPlan.filtering: a closure announced after this
            // morning's ring went off must not relabel it.
            if settings.isDisasterSuspensionEnabled && !manualRing && (registered ?? request.normalAlarmDate) > now {
                let disaster = DisasterSuspensionEvaluator.decision(
                    feed: disasterSourceFailed ? nil : disasterFeed,
                    normalAlarmDate: request.normalAlarmDate, now: now,
                    home: settings.homeSuspensionRegion, destination: settings.workSuspensionRegion,
                    observesWork: settings.observesWorkSuspensions, observesSchool: settings.observesSchoolSuspensions)
                if disaster.shouldSkip {
                    expected = nil
                    reason = .disaster
                    noticeIDs = disaster.noticeIDs.sorted()
                }
            }
            if expected != nil, let freshWeather,
               freshWeather.exceedsRainThreshold(settings.rainProbabilityThreshold), settings.rainLeadTimeMinutes > 0 {
                let earlier = request.forecastDate
                // A late forecast must not promise a new alarm in the past.
                if earlier > now {
                    expected = earlier
                    lead = settings.rainLeadTimeMinutes
                    reason = .rain
                }
            }
        }

        var verified = false
        if registrationIsCurrent, let summary {
            if summary.calendarPlan != nil {
                if planCoversDay {
                    verified = registered == expected && reason != .routeIncomplete
                    if reason == .disaster {
                        let applied = summary.disasterSkips?.first { $0.normalDate == request.normalAlarmDate }
                        verified = verified && applied?.noticeIDs.sorted() == noticeIDs
                    }
                }
            } else if !settings.selectedWeekdays.contains(calendar.component(.weekday, from: day)) {
                verified = expected == nil
            } else if summary.normalAlarmDate == request.normalAlarmDate {
                verified = registered == expected && freshWeather != nil && reason != .routeIncomplete
            }
        }
        // A registration with other settings is still armed until a replacement succeeds.
        var outdatedRing: Date?
        var outdatedHasRung = false
        if !registrationIsCurrent, let summary, let fingerprint = registeredFingerprint {
            if let plan = summary.calendarPlan {
                if plan.timeZoneID == calendar.timeZone.identifier,
                   let ring = plan.occurrences.first(where: { calendar.isDate($0.normalDate, inSameDayAs: day) })?.ringDate {
                    if ring >= now { outdatedRing = ring } else { outdatedHasRung = true }
                }
            } else if calendar.isDate(summary.normalAlarmDate, inSameDayAs: day), summary.scheduledAlarmDate >= now {
                // The caller rolls the summary with the registration's own weekdays.
                outdatedRing = summary.scheduledAlarmDate
            } else if summary.normalAlarmDate > day, !calendar.isDate(summary.normalAlarmDate, inSameDayAs: day),
                      fingerprint.selectedWeekdays.contains(calendar.component(.weekday, from: day)) {
                // One of its days, and its next ring is a later day's: this day's has fired.
                outdatedHasRung = true
            }
        }
        // A weekly lead decided for an earlier morning (the repeat carried it here) is not
        // this morning's rain. One decided for this very morning keeps its reason even once
        // that forecast has gone stale; a summary stored before 1.8.0 names no morning and
        // reads as decided. Calendar plans only put rain on the occurrence it was decided for.
        func isCarriedOver(lead: Int) -> Bool {
            guard lead > 0, let summary, summary.calendarPlan == nil,
                  let decided = summary.decisionNormalAlarmDate else { return false }
            return decided != request.normalAlarmDate
        }
        // A weekly registration made after a morning's early ring keeps its one repeating clock
        // time on that ring (`restoreWeeklySchedule` records it as `firedEarlyRing`), even when
        // the lead has changed since. The mornings after it carry that ring's lead: what
        // AlarmKit rings (D-D), not an update a retry could make before that normal time.
        // Only until this morning's own check point under the current lead: past it the
        // scheduler no longer re-decides this morning, a retry would register the current
        // settings' time, and a kept ring still ahead — a lead raised after the early ring
        // puts the new check point before it — is an outdated registration, flagged as one.
        let firedLead = summary.flatMap { $0.calendarPlan == nil ? $0.firedEarlyRing : nil }
            .map { $0.normalDate.timeIntervalSince($0.ringDate) }
        let keptLead = decisionIsFinal ? nil : firedLead
        var keptRing: Date?
        var carriedOver = false
        if let firedRing, expected != nil {
            // This morning already rang. Final, whatever the lead or forecast say now.
            expected = firedRing
            lead = max(0, Int(request.normalAlarmDate.timeIntervalSince(firedRing) / 60))
            reason = lead > 0 ? .rain : (manualRing ? .manual : .normal)
            verified = true
            carriedOver = isCarriedOver(lead: lead)
        } else if expected != nil, freshWeather == nil || decisionIsFinal, let registered {
            let offset = request.normalAlarmDate.timeIntervalSince(registered)
            if offset == 0 || offset == Double(settings.rainLeadTimeMinutes * 60) || offset == keptLead {
                // Until the forecast arrives — and for good once the check point has passed —
                // show the exact registered time instead of claiming a different one. This
                // does not turn the old schedule's weather into new weather.
                expected = registered
                lead = max(0, Int(offset / 60))
                reason = lead > 0 ? .rain : (manualRing ? .manual : .normal)
                verified = decisionIsFinal || summary?.calendarPlan != nil
                carriedOver = isCarriedOver(lead: lead)
            } else if registrationIsCurrent, offset == firedLead, registered >= now {
                // The kept ring, past this morning's check point: expected stays the current
                // settings' time, and the mismatch flags "update needed". AlarmKit still rings it.
                keptRing = registered
            }
        }

        return Self(day: day, normalAlarmDate: request.normalAlarmDate, expectedRingDate: expected,
                    reason: reason, holidayName: holidayName, leadTimeMinutes: lead, weather: weather,
                    weatherIsStale: stale, weatherRefreshFailed: weatherRefreshFailed,
                    registeredRingDate: registered, isScheduleVerified: verified, disasterNoticeIDs: noticeIDs,
                    isToday: calendar.isDate(day, inSameDayAs: now),
                    hasRung: expected.map { $0 <= now } ?? false,
                    hasCommittedClosureSkip: committedSkip, isMissingFromPlan: missingFromPlan,
                    rainLeadIsCarriedOver: carriedOver, isRegistrationCurrent: registrationIsCurrent,
                    passedRingDate: passedRing,
                    outdatedRegistrationRingDate: outdatedRing, outdatedRegistrationHasRung: outdatedHasRung,
                    keptRingDate: keptRing)
    }
}

/// Provenance travels with the snapshot: equal text with different selected map
/// coordinates, a mode change, and a new normal alarm day all require a new fetch.
/// The day is the coming morning (see `TomorrowAlarmStatus`), so the request — and the
/// cached forecast — carry across midnight unchanged and move on at the normal alarm time.
struct TomorrowWeatherRequest: Codable, Equatable {
    var normalAlarmDate: Date
    var forecastDate: Date
    var timeZoneID: String
    var homeAddress: String
    var workAddress: String
    var homeLocation: ResolvedMapLocation?
    var workLocation: ResolvedMapLocation?
    var mode: CommuteAlarmSettings.CommuteMode

    /// `dayOffset` nil is the coming morning: the card's, and the only one the app fetches a
    /// forecast for. 0 (today) and 1 (tomorrow) name a calendar day, which only the widget
    /// asks about (D-C); its request matches the fetched forecast only when that day is
    /// also the coming morning.
    init(settings: CommuteAlarmSettings, now: Date, calendar: Calendar = AlarmCalendarSettings.calendar, dayOffset: Int? = nil) {
        let time = calendar.dateComponents([.hour, .minute], from: settings.alarmTime)
        func normal(daysFromToday offset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: day)!
        }
        if let dayOffset {
            normalAlarmDate = normal(daysFromToday: dayOffset)
        } else {
            // The coming morning: today's alarm until its normal time has passed (strict >, as
            // in CalendarAlarmPlan.make and DisasterSuspensionEvaluator), then tomorrow's.
            let today = normal(daysFromToday: 0)
            normalAlarmDate = today > now ? today : normal(daysFromToday: 1)
        }
        forecastDate = calendar.date(byAdding: .minute, value: -settings.rainLeadTimeMinutes, to: normalAlarmDate)!
        timeZoneID = calendar.timeZone.identifier
        homeAddress = settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        workAddress = settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        homeLocation = settings.homeResolvedLocation
        workLocation = settings.workResolvedLocation
        mode = settings.commuteMode
    }

    var hasRoute: Bool { !homeAddress.isEmpty && !workAddress.isEmpty }
}

struct TomorrowWeatherRecord: Codable, Equatable {
    static let cacheKey = "tomorrowWeatherRecord.v1"
    private static let maximumCacheBytes = 256_000

    var request: TomorrowWeatherRequest
    var snapshot: RouteWeatherSnapshot

    /// Restore synchronously, before the UI starts a network task. An old date or
    /// route stays unusable even if its weather timestamp is still fresh.
    static func load(from storage: UserDefaults, matching request: TomorrowWeatherRequest, now: Date) -> Self? {
        guard request.hasRoute, let data = storage.data(forKey: cacheKey), data.count <= maximumCacheBytes,
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.request == request, record.isValid(at: now) else { return nil }
        return record
    }

    func save(to storage: UserDefaults, now: Date) {
        guard request.hasRoute, isValid(at: now), let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumCacheBytes else { return }
        storage.set(data, forKey: Self.cacheKey)
    }

    func isValid(at now: Date) -> Bool {
        // forecastAt is the requested lead-time point, which can be today at night.
        abs(snapshot.forecastAt.timeIntervalSince(request.forecastDate)) < 60
            && snapshot.checkedAt <= now.addingTimeInterval(5 * 60)
            && !snapshot.segments.isEmpty
            && snapshot.segments.allSatisfy { $0.precipitationProbability.isFinite && (0...1).contains($0.precipitationProbability) }
    }
}

/// The request whose refresh last failed, kept beside `TomorrowWeatherRecord`. A launch that
/// publishes without trying the fetch (a background run out of time, a closure push) builds a
/// fresh model; without this it would forget the failure and publish the old forecast with no
/// warning, which the widget no longer shows for age alone (owner, 2026-10-09). It only counts
/// while it equals the current request, so an older morning or another route never inherits it.
enum TomorrowWeatherFailure {
    static let cacheKey = "tomorrowWeatherFailedRequest.v1"
    private static let maximumCacheBytes = 16_384

    static func load(from storage: UserDefaults, matching request: TomorrowWeatherRequest) -> TomorrowWeatherRequest? {
        guard request.hasRoute, let data = storage.data(forKey: cacheKey), data.count <= maximumCacheBytes,
              let failed = try? JSONDecoder().decode(TomorrowWeatherRequest.self, from: data), failed == request else { return nil }
        return failed
    }

    /// nil removes it: a successful fetch, or a failure the model no longer holds.
    static func save(_ request: TomorrowWeatherRequest?, to storage: UserDefaults) {
        guard let request, let data = try? JSONEncoder().encode(request), data.count <= maximumCacheBytes else {
            storage.removeObject(forKey: cacheKey)
            return
        }
        storage.set(data, forKey: cacheKey)
    }
}
