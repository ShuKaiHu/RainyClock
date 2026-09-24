import Foundation

/// A forecast of tomorrow's configured behavior, separate from system registration.
struct TomorrowAlarmStatus: Equatable {
    enum Reason: Equatable {
        case normal, rain, holiday, manual, weekend, unselectedWeekday, disaster, routeIncomplete
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
    /// The early ring is the weekly repeat of an earlier morning's rain decision, rolled
    /// past that morning's ring, and no fresh forecast for this day has decided it yet.
    /// The time is still what AlarmKit will ring, so it stays; what it must not claim is
    /// that rain moved it (`TomorrowWidgetSnapshot.ReasonLine.awaitingForecast`).
    var rainLeadIsCarriedOver = false

    /// The card's (and the decision's) freshness rule. The widget only *warns* after
    /// `TomorrowWidgetSnapshotBuilder.widgetWeatherLifetime`; this is unchanged by that.
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
        let key = AlarmCalendarSettings.key(for: day, calendar: calendar)
        let manualRing = settings.calendarSettings.isEnabled && settings.calendarSettings.overrides[key] == .ring
        var expected: Date? = decision.rings ? request.normalAlarmDate : nil
        var reason: Reason = .normal
        var holidayName: String?
        var lead = 0
        var noticeIDs: [String] = []

        if !decision.rings {
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
        } else {
            reason = manualRing ? .manual : .normal
            if settings.isDisasterSuspensionEnabled && !manualRing {
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

        var registered: Date?
        var verified = false
        if registeredFingerprint == settings.scheduleFingerprint(calendar: calendar), let summary {
            if let plan = summary.calendarPlan {
                if plan.timeZoneID == calendar.timeZone.identifier, plan.coveredUntil > request.normalAlarmDate {
                    registered = plan.occurrences.first { $0.normalDate == request.normalAlarmDate }?.ringDate
                    verified = registered == expected && reason != .routeIncomplete
                    if reason == .disaster {
                        let applied = summary.disasterSkips?.first { $0.normalDate == request.normalAlarmDate }
                        verified = verified && applied?.noticeIDs.sorted() == noticeIDs
                    }
                }
            } else if !settings.selectedWeekdays.contains(calendar.component(.weekday, from: day)) {
                verified = expected == nil
            } else if summary.normalAlarmDate == request.normalAlarmDate {
                // Never roll today's summary or its rain decision into tomorrow.
                registered = summary.scheduledAlarmDate
                verified = registered == expected && freshWeather != nil && reason != .routeIncomplete
            }
        }
        var carriedOver = false
        if expected != nil, freshWeather == nil, let registered {
            let offset = request.normalAlarmDate.timeIntervalSince(registered)
            if offset == 0 || offset == Double(settings.rainLeadTimeMinutes * 60) {
                // Until tomorrow's forecast arrives, preserve the exact registered
                // time instead of temporarily claiming a different normal time.
                // This does not turn the old schedule's weather into new weather.
                expected = registered
                lead = max(0, Int(offset / 60))
                reason = lead > 0 ? .rain : (manualRing ? .manual : .normal)
                verified = summary?.calendarPlan != nil
                // A weekly lead decided for an earlier morning (the pair roll carried it
                // here) is not this day's rain. One decided for this very morning keeps
                // its reason even once that forecast has gone stale.
                if lead > 0, let summary, summary.calendarPlan == nil,
                   let decided = summary.decisionNormalAlarmDate, decided != request.normalAlarmDate {
                    carriedOver = true
                }
            }
        }

        return Self(day: day, normalAlarmDate: request.normalAlarmDate, expectedRingDate: expected,
                    reason: reason, holidayName: holidayName, leadTimeMinutes: lead, weather: weather,
                    weatherIsStale: stale, weatherRefreshFailed: weatherRefreshFailed,
                    registeredRingDate: registered, isScheduleVerified: verified, disasterNoticeIDs: noticeIDs,
                    rainLeadIsCarriedOver: carriedOver)
    }
}

/// Provenance travels with the snapshot: equal text with different selected map
/// coordinates, a mode change, and a new normal alarm day all require a new fetch.
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
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let time = calendar.dateComponents([.hour, .minute], from: settings.alarmTime)
        normalAlarmDate = calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30,
                                       second: 0, of: tomorrow)!
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
