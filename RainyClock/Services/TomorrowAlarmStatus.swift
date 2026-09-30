import Foundation

/// The coming morning's configured behavior — today's alarm until its normal time has
/// passed, then tomorrow's — separate from system registration. "Tomorrow" in these type
/// names predates that rule: until 2026-09-29 the card switched at midnight, and at 00:39
/// it described Wednesday while the morning the user was about to sleep through (a skipped
/// Tuesday) appeared nowhere.
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
    /// The described morning is today's (after midnight, before its normal time).
    var isToday: Bool
    /// The described morning's alarm already went off (an early rain ring before the normal time).
    var hasRung: Bool
    /// The committed schedule skipped this morning for a closure — true even when the live
    /// preview no longer supports it, which the page must then flag instead of hiding.
    var hasCommittedClosureSkip: Bool
    /// A current dated plan covers this morning but holds no ring for it, and nothing
    /// (a closure skip, an early ring that already went off) explains why.
    var isMissingFromPlan: Bool

    /// The card expects a ring the committed schedule does not hold for this morning.
    var ringIsNotRegistered: Bool {
        expectedRingDate != nil && (hasCommittedClosureSkip || isMissingFromPlan)
    }

    static let weatherLifetime: TimeInterval = 30 * 60

    static func resolve(settings: CommuteAlarmSettings, holidays: HolidayCalendar,
                        weatherRecord: TomorrowWeatherRecord?, weatherRefreshFailed: Bool,
                        routeIsReady: Bool = true,
                        summary: ScheduledAlarmSummary?, registeredFingerprint: AlarmScheduleFingerprint?,
                        disasterFeed: DisasterFeed?, disasterSourceFailed: Bool,
                        now: Date, calendar: Calendar = AlarmCalendarSettings.calendar) -> Self {
        let request = TomorrowWeatherRequest(settings: settings, now: now, calendar: calendar)
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
        let fingerprintMatches = registeredFingerprint == settings.scheduleFingerprint(calendar: calendar)
        var registered: Date?
        var firedRing: Date?
        var planCoversDay = false
        var committedSkip = false
        var missingFromPlan = false
        if fingerprintMatches, let summary {
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
                    // Re-registered inside this morning's window for a later morning. The weekly
                    // repeating alarm's clock time now governs this morning too: if that ring is
                    // still ahead it is this morning's ring; if it has passed, nothing is left, and
                    // the later ring makes the page flag the mismatch instead of promising one.
                    let ring = request.normalAlarmDate.addingTimeInterval(
                        -summary.normalAlarmDate.timeIntervalSince(summary.scheduledAlarmDate))
                    registered = ring > now ? ring : summary.scheduledAlarmDate
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
        if fingerprintMatches, let summary {
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
        if let firedRing, expected != nil {
            // This morning already rang early. Final, whatever the lead or forecast say now.
            expected = firedRing
            lead = max(0, Int(request.normalAlarmDate.timeIntervalSince(firedRing) / 60))
            reason = .rain
            verified = true
        } else if expected != nil, freshWeather == nil || decisionIsFinal, let registered {
            let offset = request.normalAlarmDate.timeIntervalSince(registered)
            if offset == 0 || offset == Double(settings.rainLeadTimeMinutes * 60) {
                // Until the forecast arrives — and for good once the check point has passed —
                // show the exact registered time instead of claiming a different one. This
                // does not turn the old schedule's weather into new weather.
                expected = registered
                lead = max(0, Int(offset / 60))
                reason = lead > 0 ? .rain : (manualRing ? .manual : .normal)
                verified = decisionIsFinal || summary?.calendarPlan != nil
            }
        }

        return Self(day: day, normalAlarmDate: request.normalAlarmDate, expectedRingDate: expected,
                    reason: reason, holidayName: holidayName, leadTimeMinutes: lead, weather: weather,
                    weatherIsStale: stale, weatherRefreshFailed: weatherRefreshFailed,
                    registeredRingDate: registered, isScheduleVerified: verified, disasterNoticeIDs: noticeIDs,
                    isToday: calendar.isDate(day, inSameDayAs: now),
                    hasRung: expected.map { $0 <= now } ?? false,
                    hasCommittedClosureSkip: committedSkip, isMissingFromPlan: missingFromPlan)
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

    init(settings: CommuteAlarmSettings, now: Date, calendar: Calendar = AlarmCalendarSettings.calendar) {
        let time = calendar.dateComponents([.hour, .minute], from: settings.alarmTime)
        func normal(daysFromToday offset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: day)!
        }
        // The coming morning: today's alarm until its normal time has passed (strict >, as in
        // CalendarAlarmPlan.make and DisasterSuspensionEvaluator), then tomorrow's.
        let today = normal(daysFromToday: 0)
        normalAlarmDate = today > now ? today : normal(daysFromToday: 1)
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
