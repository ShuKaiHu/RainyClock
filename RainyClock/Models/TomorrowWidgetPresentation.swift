import Foundation

/// The widget's display rules as plain data: which glyph, which hero, which one
/// footer line. The views only render what this says, so every rule here is
/// unit-testable from the app's test target.
///
/// WeatherKit (D-A): only the medium family shows weather data (its weather column,
/// `home`/`work` and the sky drawn from them), and it carries Apple's  Weather mark and
/// the legal link. Every other family (small, StandBy, rectangular, circular, inline)
/// shows the alarm decision only: `line` never carries a rain percentage or a condition,
/// and the small widget's `decisionSky` follows the decision, never the forecast.
struct TomorrowWidgetPresentation: Equatable, Sendable {
    enum Glyph: String, Sendable {
        case alarm = "alarm.fill", rain = "cloud.rain.fill", silent = "bell.slash.fill", manualRing = "calendar"
        case closure = "cloud.bolt.rain.fill", route = "arrow.triangle.turn.up.right.diamond.fill"
        case warning = "exclamationmark.triangle.fill", refresh = "arrow.clockwise"
    }

    enum Hero: Equatable, Sendable {
        /// `originalTime` is the normal alarm time when rain moved the ring off it.
        case time(ring: Date, originalTime: Date?)
        case skipped, notSet
        case openApp(TomorrowWidgetTimeline.NeedsApp)
    }

    enum Line: Equatable, Sendable {
        case issue(TomorrowWidgetSnapshot.ScheduleIssue)
        case reason(TomorrowWidgetSnapshot.ReasonLine)
        /// The same reason about today (D-C): every line that names 明天 names 今天 instead.
        case todayReason(TomorrowWidgetSnapshot.ReasonLine)
        case notice(TomorrowWidgetSnapshot.WeatherNotice)
        /// A normal ringing day: 照常響鈴 / Rings as usual.
        case ringsAsUsual

        var isWarning: Bool {
            switch self {
            case .issue, .notice(.failed), .notice(.stale): true
            default: false
            }
        }

        var leadingSymbol: String? {
            isWarning ? Glyph.warning.rawValue : nil
        }

        /// Small, medium, and the rectangular widget's first choice.
        var full: LocalizedLine {
            switch self {
            case .reason(let reason):
                switch reason {
                case .rainForecast(let percent, let minutes):
                    LocalizedLine(key: "ux_rain_applied_forecast", arguments: [.int(percent), .int(minutes)])
                case .rainEarlier(let minutes): LocalizedLine(key: "ux_rain_applied", arguments: [.int(minutes)])
                case .awaitingForecast: LocalizedLine(key: "ux_tomorrow_awaiting_forecast")
                case .holidayNamed(let name): LocalizedLine(key: "ux_tomorrow_holiday_named", arguments: [.string(name)])
                case .holiday: LocalizedLine(key: "ux_tomorrow_holiday")
                case .manualSkip: LocalizedLine(key: "ux_tomorrow_manual_skip")
                case .manualRing: LocalizedLine(key: "ux_tomorrow_manual_ring")
                case .weekend: LocalizedLine(key: "ux_tomorrow_weekend")
                case .unselectedWeekday: LocalizedLine(key: "ux_tomorrow_unselected")
                case .closure: LocalizedLine(key: "ux_tomorrow_closure")
                case .routeNeeded: LocalizedLine(key: "ux_route_needed")
                }
            case .todayReason(let reason):
                switch reason {
                case .awaitingForecast: LocalizedLine(key: "widget_today_awaiting_forecast")
                case .holidayNamed(let name): LocalizedLine(key: "widget_today_holiday_named", arguments: [.string(name)])
                case .holiday: LocalizedLine(key: "widget_today_holiday")
                case .manualSkip: LocalizedLine(key: "widget_today_manual_skip")
                case .manualRing: LocalizedLine(key: "widget_today_manual_ring")
                case .weekend: LocalizedLine(key: "widget_today_weekend")
                case .unselectedWeekday: LocalizedLine(key: "widget_today_unselected")
                case .closure: LocalizedLine(key: "widget_today_closure")
                // These name no day.
                case .rainForecast, .rainEarlier, .routeNeeded: Line.reason(reason).full
                }
            case .issue(let issue):
                switch issue {
                case .updateNeeded: LocalizedLine(key: "ux_schedule_update_needed")
                case .schedulingFailed: LocalizedLine(key: "widget_issue_schedule_failed")
                case .alarmKitReschedule: LocalizedLine(key: "widget_issue_alarmkit")
                case .closureUncertain: LocalizedLine(key: "widget_issue_closure_uncertain")
                case .closureUpdateFailed: LocalizedLine(key: "ux_closure_update_failed")
                }
            case .notice(let notice):
                switch notice {
                case .failed: LocalizedLine(key: "ux_tomorrow_weather_failed")
                case .stale: LocalizedLine(key: "ux_tomorrow_weather_stale")
                case .routeNeeded: LocalizedLine(key: "ux_route_needed")
                case .noForecast: LocalizedLine(key: "ux_tomorrow_weather_unavailable")
                }
            case .ringsAsUsual: LocalizedLine(key: "widget_rings_as_usual")
            }
        }

        /// The rectangular widget's fallback when `full` does not fit.
        var short: LocalizedLine {
            switch self {
            case .reason(let reason):
                switch reason {
                case .rainForecast(_, let minutes): LocalizedLine(key: "ux_rain_applied", arguments: [.int(minutes)])
                case .rainEarlier: LocalizedLine(key: "widget_rain_short")
                case .awaitingForecast: LocalizedLine(key: "widget_awaiting_forecast_short")
                case .manualSkip: LocalizedLine(key: "widget_manual_skip_short")
                case .manualRing: LocalizedLine(key: "widget_manual_ring_short")
                case .unselectedWeekday: LocalizedLine(key: "widget_unselected_short")
                case .closure: LocalizedLine(key: "widget_closure_short")
                case .holidayNamed(let name): LocalizedLine(key: "widget_holiday_named_short", arguments: [.string(name)])
                case .holiday, .weekend, .routeNeeded: full
                }
            case .todayReason(let reason):
                switch reason {
                // The long form is already the shortest thing that says "today".
                case .holiday, .weekend: full
                default: Line.reason(reason).short
                }
            case .issue: LocalizedLine(key: "widget_issue_short")
            case .notice(let notice):
                switch notice {
                case .failed: LocalizedLine(key: "widget_weather_failed_short")
                case .noForecast: LocalizedLine(key: "widget_forecast_pending")
                case .stale: LocalizedLine(key: "widget_weather_stale_short")
                case .routeNeeded: full
                }
            case .ringsAsUsual: full
            }
        }
    }

    /// What a family that names a day beside the ring time calls that day.
    enum RingDay: Equatable, Sendable {
        /// The ring is on `day`: 明天 and its weekday.
        case tomorrow(Date)
        /// Today's ring, before it has fired (D-C): 今天 and its weekday.
        case today(Date)
        /// Rain moved the ring across midnight onto the day before `day` (the
        /// `ringPreviousDay` sample): that day by its own weekday or date, never 明天.
        case on(Date)
    }

    var glyph: Glyph
    var hero: Hero
    /// Small footer and rectangular line 3.
    var line: Line?
    /// The medium widget's left footer: `line`, unless it repeats the weather notice the
    /// medium's weather column already shows (the notice's own text, or "waiting for the
    /// forecast" beside "no forecast yet"); then the next priority, which is none.
    var mediumLine: Line?
    /// The medium widget draws its weather column (endpoints, footer,  Weather mark, and
    /// the link to Apple's legal page). Not for a today entry: it carries no forecast
    /// (`TomorrowWidgetSnapshotBuilder.todayWeatherNotice`), and the left side takes the
    /// width. Not for the open-the-app faces either.
    var showsWeatherColumn: Bool
    /// A warning exists that the footer line is not already showing.
    var showsWarningBadge: Bool
    var hasIssue: Bool
    /// The medium widget's sky, from the forecast (weather data: medium only); nil when
    /// needsApp, without a forecast, or without the weather column.
    var home: TomorrowWidgetSnapshot.Condition?
    var work: TomorrowWidgetSnapshot.Condition?
    /// The small widget's sky (D-A): rain only when this day's rain moved the alarm;
    /// otherwise nil, the neutral brand navy. Never the forecast's condition, and never a
    /// sunny sky that nothing decided (a failed or missing forecast, a closure, 60% under a
    /// 70% threshold all look the same).
    var decisionSky: TomorrowWidgetSnapshot.Condition?
    var day: Date?
    /// The entry is today's (D-C): headers and lines say 今天 / Today.
    var isToday: Bool
    var ringIsOnAnotherDay: Bool
    /// nil unless the hero is a time. Inline, rectangular and the VoiceOver label name it.
    var ringDay: RingDay?
    /// The circular face's one word under a skipped day's glyph, so a holiday and a
    /// 停班停課 read apart without telling a bell from a storm cloud. nil unless skipped.
    var skipLabelKey: String?
    var relevanceScore: Float

    /// `language` is the one the strings resolve in (`LocalizedLine.resolve`'s bundle); it
    /// names a stored holiday, which the snapshot keeps as DGPA wrote it.
    init(_ state: TomorrowWidgetTimeline.State, language: String = Bundle.main.preferredLocalizations.first ?? "en") {
        switch state {
        case .needsApp(let reason):
            glyph = .refresh
            hero = .openApp(reason)
            line = nil
            mediumLine = nil
            showsWeatherColumn = false
            showsWarningBadge = false
            hasIssue = false
            home = nil
            work = nil
            decisionSky = nil
            day = nil
            isToday = false
            ringIsOnAnotherDay = false
            ringDay = nil
            skipLabelKey = nil
            relevanceScore = 1

        case .status(let entry):
            if entry.reason == .routeIncomplete { glyph = .route }
            else if entry.reason == .disaster { glyph = .closure }
            else if entry.expectedRingDate == nil { glyph = .silent }
            // A carried-over lead is not this day's rain: the plain alarm glyph.
            else if entry.appliesRainLead { glyph = .rain }
            else if entry.reason == .manual { glyph = .manualRing }
            else { glyph = .alarm }

            if let ring = entry.expectedRingDate {
                hero = .time(ring: ring, originalTime: entry.reason == .rain && ring != entry.normalAlarmDate
                    ? entry.normalAlarmDate : nil)
            } else {
                hero = entry.reason == .routeIncomplete ? .notSet : .skipped
            }

            // First match wins: an issue, the reason, the freshness notice (data age, not
            // weather), then 照常響鈴 for a day that simply rings.
            func lines(withWeather: Bool) -> [Line] {
                var lines: [Line] = []
                if let issue = entry.scheduleIssue { lines.append(.issue(issue)) }
                if var reason = entry.reasonLine?.displayed(in: language) {
                    // Outside the medium the rain line is the decision alone, no percentage.
                    if !withWeather, case .rainForecast(_, let minutes) = reason { reason = .rainEarlier(minutes: minutes) }
                    lines.append(entry.isToday ? .todayReason(reason) : .reason(reason))
                }
                if let notice = entry.weatherNotice { lines.append(.notice(notice)) }
                if entry.reasonLine == nil, entry.expectedRingDate != nil { lines.append(.ringsAsUsual) }
                return lines
            }
            line = lines(withWeather: false).first
            showsWeatherColumn = !entry.isToday
            // The weather column prints the notice's own text (stale, failed, no forecast,
            // or route needed, which is also the route-incomplete reason's text).
            let columnNotice = showsWeatherColumn ? entry.weatherNotice : nil
            let columnText = columnNotice.map { Line.notice($0).full }
            // Without the column there is no  Weather mark either, so no percentage.
            mediumLine = lines(withWeather: showsWeatherColumn).first { line in
                // "Waiting for tomorrow's forecast" beside "tomorrow's forecast is not available
                // yet" says the same thing twice; the column keeps it.
                if case .reason(.awaitingForecast) = line, columnNotice == .noForecast { return false }
                return line.full != columnText
            }

            let weatherWarning = entry.weatherNotice == .failed || entry.weatherNotice == .stale
            showsWarningBadge = (weatherWarning || entry.scheduleIssue != nil) && line?.isWarning != true
            hasIssue = entry.scheduleIssue != nil
            // The medium's sky is weather data too: only beside the column that attributes it.
            home = showsWeatherColumn ? entry.forecast?.home.condition : nil
            work = showsWeatherColumn ? entry.forecast?.work?.condition : nil
            decisionSky = entry.appliesRainLead ? .rain : nil
            day = entry.day
            isToday = entry.isToday
            ringIsOnAnotherDay = entry.ringIsOnAnotherDay
            if let ring = entry.expectedRingDate {
                ringDay = entry.ringIsOnAnotherDay ? .on(ring) : entry.isToday ? .today(entry.day) : .tomorrow(entry.day)
            } else {
                ringDay = nil
            }
            if case .skipped = hero {
                skipLabelKey = switch entry.reason {
                case .holiday: "widget_skip_holiday"
                case .disaster: "widget_skip_closure"
                default: "widget_skip_other"
                }
            } else {
                skipLabelKey = nil
            }
            if entry.appliesRainLead || entry.scheduleIssue != nil { relevanceScore = 50 }
            else if entry.expectedRingDate != nil { relevanceScore = 10 }
            else { relevanceScore = 5 }
        }
    }

    /// 今天 / Today for today's entry, else 明天 / Tomorrow; nil when no day is shown.
    var dayWordKey: String? {
        guard day != nil else { return nil }
        return isToday ? "widget_today" : "ux_tomorrow"
    }
}

/// A string-table key plus its format arguments, resolved inside whichever bundle
/// renders it (the widget extension's own tables at runtime).
struct LocalizedLine: Equatable, Sendable {
    enum Argument: Equatable, Sendable {
        case int(Int)
        case string(String)
    }

    var key: String
    var arguments: [Argument] = []

    /// `bundle.localizedString(forKey:value:table:)`, then, when arguments are
    /// present, `String(format:locale:arguments:)` in the bundle's own localization.
    func resolve(in bundle: Bundle = .main) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        let locale = Locale(identifier: bundle.preferredLocalizations.first ?? "en")
        let values: [any CVarArg] = arguments.map { argument -> any CVarArg in
            switch argument {
            case .int(let value): return value
            case .string(let value): return value
            }
        }
        return String(format: format, locale: locale, arguments: values)
    }
}

extension TomorrowWidgetSnapshot.ReasonLine {
    /// The line as a UI in `language` shows it: a holiday name that UI cannot show
    /// becomes the unnamed holiday line. Every other line is unchanged.
    func displayed(in language: String) -> Self {
        guard case .holidayNamed(let name) = self else { return self }
        return HolidayDisplayName.name(for: name, language: language).map { .holidayNamed($0) } ?? .holiday
    }
}

/// Taiwan's holiday names come from DGPA's 備註 column, in Chinese. A Chinese UI shows
/// them as they are; any other UI gets a known holiday's English name, or nil (the
/// unnamed holiday line) rather than a name it may not read. Names without ideographs,
/// the US federal holidays, pass through. Both the app's card and the widget call this
/// where they render, each in its own language; the snapshot stores the name untouched.
enum HolidayDisplayName {
    /// Every 備註 value in the bundled 2026–2027 CSVs, plus DGPA's other names for the
    /// same days. Each is also matched inside compound names (中秋節補假, 兒童節及民族掃墓節).
    /// 補假 (a day off in lieu of a holiday that fell on a weekend) is deliberately absent:
    /// it takes the unnamed line rather than a name that repeats "holiday" or claims a
    /// bridge day, which is 調整放假.
    static let english: [String: String] = [
        "開國紀念日": "New Year's Day",
        // 小年夜 is the day before the Eve, not the Eve.
        "小年夜": "Lunar New Year break",
        "農曆除夕": "Lunar New Year's Eve", "除夕": "Lunar New Year's Eve",
        "春節": "Lunar New Year",
        // 調整放假: a day off between a holiday and a weekend, made up on a Saturday.
        "調整放假": "Bridge day",
        "和平紀念日": "Peace Memorial Day",
        "兒童節": "Children's Day",
        "民族掃墓節": "Tomb-Sweeping Day", "清明節": "Tomb-Sweeping Day",
        "勞動節": "Labor Day",
        "端午節": "Dragon Boat Festival",
        "中秋節": "Mid-Autumn Festival",
        "孔子誕辰紀念日/教師節": "Teachers' Day", "孔子誕辰紀念日": "Teachers' Day", "教師節": "Teachers' Day",
        "國慶日": "National Day",
        "臺灣光復暨金門古寧頭大捷紀念日": "Retrocession Day", "光復": "Retrocession Day",
        "行憲紀念日": "Constitution Day",
    ]

    static func name(for name: String, language: String) -> String? {
        if language.hasPrefix("zh") { return name }
        guard name.unicodeScalars.contains(where: \.properties.isIdeographic) else { return name }
        if let exact = english[name] { return exact }
        // A compound name reads as the holiday it names first; the longer fragment wins a tie.
        let matches = english.compactMap { fragment, translation in
            name.range(of: fragment).map { (start: $0.lowerBound, length: fragment.count, english: translation) }
        }
        return matches.min { ($0.start, -$0.length) < ($1.start, -$1.length) }?.english
    }
}

/// Every key the extension's string tables must carry. `sharedAppKeys` are copied
/// verbatim from the app's tables, and a unit test keeps them identical.
enum TomorrowWidgetStrings {
    static let sharedAppKeys: [String] = [
        "app_title",
        "ux_tomorrow", "ux_expected_ring", "ux_tomorrow_skipped", "ux_not_set",
        "ux_rain_applied_forecast", "ux_rain_applied", "ux_tomorrow_awaiting_forecast",
        "ux_tomorrow_holiday_named", "ux_tomorrow_holiday",
        "ux_tomorrow_manual_skip", "ux_tomorrow_manual_ring",
        "ux_tomorrow_weekend", "ux_tomorrow_unselected", "ux_tomorrow_closure",
        "ux_route_needed",
        "ux_tomorrow_weather_failed", "ux_tomorrow_weather_stale", "ux_tomorrow_weather_unavailable",
        "ux_schedule_update_needed", "ux_closure_update_failed",
        "ux_rain_chance",
        "ux_weather_home", "ux_weather_work", "ux_weather_clear", "ux_weather_cloudy", "ux_weather_rain", "ux_weather_updated",
        "calendar_silent",
        "commute_mode_car", "commute_mode_scooter", "commute_mode_walking", "commute_mode_public_transit",
    ]

    static let widgetOnlyKeys: [String] = [
        "widget_display_name", "widget_description",
        "widget_open_to_refresh", "widget_open_to_start",
        "widget_rings_as_usual", "widget_rain_short",
        "widget_manual_skip_short", "widget_manual_ring_short", "widget_holiday_named_short", "widget_unselected_short",
        "widget_closure_short",
        "widget_issue_schedule_failed", "widget_issue_alarmkit", "widget_issue_closure_uncertain", "widget_issue_short",
        "widget_weather_failed_short", "widget_weather_stale_short", "widget_forecast_pending",
        "widget_inline_ring", "widget_inline_rain", "widget_inline_skipped", "widget_inline_refresh",
        "widget_inline_refresh_short", "widget_inline_start", "widget_inline_start_short",
        "widget_inline_ring_on", "widget_inline_rain_on",
        "widget_skip_holiday", "widget_skip_closure", "widget_skip_other",
        "widget_awaiting_forecast_short",
        // Today, between midnight and today's ring (D-C).
        "widget_today", "widget_today_awaiting_forecast",
        "widget_today_holiday_named", "widget_today_holiday", "widget_today_manual_skip", "widget_today_manual_ring",
        "widget_today_weekend", "widget_today_unselected", "widget_today_closure",
        "widget_inline_today_ring", "widget_inline_today_rain", "widget_inline_today_skipped",
        // The medium's weather column is a link to Apple's legal attribution page (D-A).
        "widget_weather_legal_hint",
    ]
}

/// Sample data for the widget gallery (ships in Release; plain data), the DEBUG
/// demo and the tests. Nothing here reads the user's settings.
enum TomorrowWidgetSamples {
    enum Scenario: String, CaseIterable, Sendable {
        case normalClear, cloudyNormal, rainForecast, rainMixed, rainStale, holidayNamed, holidayUnnamed, weekend,
             unselectedWeekday, manualSkip, manualRing, closure, routeIncomplete, weatherFailed, forecastUnavailable,
             scheduleUpdateNeeded, schedulingFailed, alarmKitReschedule, closureUncertain, closureUpdateFailed,
             ringPreviousDay, carriedOver, todayRain, todayNormal, todaySkipped, todayCarriedOver,
             todayHolidayNamed, todayHolidayUnnamed, todayManualSkip, todayManualRing, todayUnselectedWeekday, todayClosure,
             expired, missing
    }

    /// nil for `.missing`. One entry (validFrom = publishedAt = now); expiresAt = now + 24h.
    /// `.expired` is a valid snapshot published a day ago whose expiry passed a minute ago.
    static func snapshot(_ scenario: Scenario, clockFormat: ClockTimeFormat = .twelveHour, now: Date = Date(),
                         calendar: Calendar = .current, holidayName: String? = nil) -> TomorrowWidgetSnapshot? {
        guard var entry = entry(scenario, now: now, calendar: calendar, holidayName: holidayName) else { return nil }
        let publishedAt = scenario == .expired ? now.addingTimeInterval(-86_400) : now
        entry.validFrom = publishedAt
        return TomorrowWidgetSnapshot(
            version: TomorrowWidgetSnapshot.currentVersion, publishedAt: publishedAt,
            timeZoneID: calendar.timeZone.identifier, clockFormat: clockFormat, mode: .car,
            expiresAt: scenario == .expired ? now.addingTimeInterval(-60) : now.addingTimeInterval(86_400),
            entries: [entry])
    }

    /// The single entry a scenario shows, valid from `now`; nil for `.missing`.
    static func entry(_ scenario: Scenario, now: Date = Date(), calendar: Calendar = .current,
                      holidayName: String? = nil) -> TomorrowWidgetSnapshot.Entry? {
        typealias S = TomorrowWidgetSnapshot
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        let normal = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: day) ?? day
        let early = normal.addingTimeInterval(-30 * 60)
        let fresh = now.addingTimeInterval(-5 * 60)
        // Past the widget's 3-hour stale threshold (TomorrowWidgetSnapshotBuilder.widgetWeatherLifetime).
        let old = now.addingTimeInterval(-4 * 3_600)
        func forecast(_ home: S.Condition, _ homePercent: Int, _ work: S.Condition?, _ workPercent: Int = 0,
                      checkedAt: Date? = nil) -> S.RouteForecast {
            S.RouteForecast(checkedAt: checkedAt ?? fresh, home: .init(condition: home, percent: homePercent),
                            work: work.map { .init(condition: $0, percent: workPercent) },
                            maximumPercent: max(homePercent, work == nil ? 0 : workPercent))
        }
        func make(ring: Date?, reason: S.Reason, line: S.ReasonLine? = nil, lead: Int = 0, normalDate: Date = normal,
                  forecast: S.RouteForecast?, notice: S.WeatherNotice? = nil, issue: S.ScheduleIssue? = nil,
                  isToday: Bool = false) -> S.Entry {
            let alarmDay = calendar.startOfDay(for: normalDate)
            return S.Entry(validFrom: now, isToday: isToday, day: alarmDay, normalAlarmDate: normalDate, expectedRingDate: ring,
                           ringIsOnAnotherDay: ring.map { !calendar.isDate($0, inSameDayAs: alarmDay) } ?? false,
                           reason: reason, reasonLine: line, leadTimeMinutes: lead, forecast: forecast,
                           weatherNotice: notice, scheduleIssue: issue)
        }
        // DGPA's own name, as a real snapshot stores it; the presentation names it per language.
        let name = holidayName ?? "國慶日"
        // Today's alarm, shown between midnight and its ring (D-C). The samples are static:
        // the widget draws them whatever the time, as it does every sample.
        let todayNormal = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: today) ?? today
        let todayEarly = todayNormal.addingTimeInterval(-30 * 60)

        switch scenario {
        case .normalClear, .expired:
            return make(ring: normal, reason: .normal, forecast: forecast(.clear, 10, .clear, 0))
        case .cloudyNormal:
            return make(ring: normal, reason: .normal, forecast: forecast(.cloudy, 30, .cloudy, 20))
        case .rainForecast:
            return make(ring: early, reason: .rain, line: .rainForecast(percent: 80, minutes: 30), lead: 30,
                        forecast: forecast(.rain, 80, .rain, 70))
        case .rainMixed:
            return make(ring: early, reason: .rain, line: .rainForecast(percent: 80, minutes: 30), lead: 30,
                        forecast: forecast(.clear, 20, .rain, 80))
        case .rainStale:
            return make(ring: early, reason: .rain, line: .rainEarlier(minutes: 30), lead: 30,
                        forecast: forecast(.rain, 80, .rain, 70, checkedAt: old), notice: .stale)
        case .holidayNamed:
            return make(ring: nil, reason: .holiday, line: .holidayNamed(name), forecast: forecast(.clear, 10, .cloudy, 20))
        case .holidayUnnamed:
            return make(ring: nil, reason: .holiday, line: .holiday, forecast: forecast(.cloudy, 20, .cloudy, 30))
        case .weekend:
            return make(ring: nil, reason: .weekend, line: .weekend, forecast: forecast(.clear, 0, .clear, 10))
        case .unselectedWeekday:
            return make(ring: nil, reason: .unselectedWeekday, line: .unselectedWeekday,
                        forecast: forecast(.cloudy, 30, .clear, 10))
        case .manualSkip:
            return make(ring: nil, reason: .manual, line: .manualSkip, forecast: forecast(.rain, 60, .cloudy, 40))
        case .manualRing:
            return make(ring: normal, reason: .manual, line: .manualRing, forecast: forecast(.clear, 10, .clear, 10))
        case .closure:
            return make(ring: nil, reason: .disaster, line: .closure, forecast: forecast(.rain, 90, .rain, 95))
        case .routeIncomplete:
            return make(ring: nil, reason: .routeIncomplete, line: .routeNeeded, forecast: nil, notice: .routeNeeded)
        case .weatherFailed:
            return make(ring: normal, reason: .normal, forecast: forecast(.cloudy, 20, .clear, 10, checkedAt: old),
                        notice: .failed)
        case .forecastUnavailable:
            return make(ring: normal, reason: .normal, forecast: nil, notice: .noForecast)
        case .scheduleUpdateNeeded:
            return make(ring: normal, reason: .normal, forecast: forecast(.clear, 10, .cloudy, 20), issue: .updateNeeded)
        case .schedulingFailed:
            return make(ring: normal, reason: .normal, forecast: forecast(.cloudy, 30, .cloudy, 20), issue: .schedulingFailed)
        case .alarmKitReschedule:
            return make(ring: early, reason: .rain, line: .rainForecast(percent: 80, minutes: 30), lead: 30,
                        forecast: forecast(.rain, 80, .rain, 70), issue: .alarmKitReschedule)
        case .closureUncertain:
            return make(ring: normal, reason: .normal, forecast: forecast(.rain, 40, .cloudy, 30), issue: .closureUncertain)
        case .closureUpdateFailed:
            return make(ring: normal, reason: .normal, forecast: forecast(.cloudy, 30, .rain, 40), issue: .closureUpdateFailed)
        case .ringPreviousDay:
            let lateNormal = calendar.date(bySettingHour: 0, minute: 15, second: 0, of: day) ?? day
            return make(ring: lateNormal.addingTimeInterval(-30 * 60), reason: .rain,
                        line: .rainForecast(percent: 70, minutes: 30), lead: 30, normalDate: lateNormal,
                        forecast: forecast(.rain, 70, .rain, 60))
        // Today's entries never carry a forecast (the builder's rule): the one that decided
        // today is last evening's, and the medium drops its weather column for them.
        case .todayRain:
            // 今天 上午7:00 因雨提早 30 分鐘: decided last evening, registered, still ahead.
            return make(ring: todayEarly, reason: .rain, line: .rainEarlier(minutes: 30), lead: 30, normalDate: todayNormal,
                        forecast: nil, isToday: true)
        case .todayNormal:
            return make(ring: todayNormal, reason: .normal, normalDate: todayNormal, forecast: nil, isToday: true)
        case .todaySkipped:
            return make(ring: nil, reason: .weekend, line: .weekend, normalDate: todayNormal, forecast: nil, isToday: true)
        case .todayCarriedOver:
            // Yesterday's rain lead, repeated this morning; no forecast has decided today.
            return make(ring: todayEarly, reason: .rain, line: .awaitingForecast, lead: 30, normalDate: todayNormal,
                        forecast: nil, isToday: true)
        case .todayHolidayNamed:
            return make(ring: nil, reason: .holiday, line: .holidayNamed(name), normalDate: todayNormal, forecast: nil,
                        isToday: true)
        case .todayHolidayUnnamed:
            return make(ring: nil, reason: .holiday, line: .holiday, normalDate: todayNormal, forecast: nil, isToday: true)
        case .todayManualSkip:
            return make(ring: nil, reason: .manual, line: .manualSkip, normalDate: todayNormal, forecast: nil, isToday: true)
        case .todayManualRing:
            return make(ring: todayNormal, reason: .manual, line: .manualRing, normalDate: todayNormal, forecast: nil,
                        isToday: true)
        case .todayUnselectedWeekday:
            return make(ring: nil, reason: .unselectedWeekday, line: .unselectedWeekday, normalDate: todayNormal,
                        forecast: nil, isToday: true)
        case .todayClosure:
            return make(ring: nil, reason: .disaster, line: .closure, normalDate: todayNormal, forecast: nil, isToday: true)
        case .carriedOver:
            // Tuesday's 07:00 rain ring has fired; the weekly repeat rings Wednesday at 07:00
            // too, but no forecast for Wednesday has decided that yet.
            return make(ring: early, reason: .rain, line: .awaitingForecast, lead: 30, forecast: nil, notice: .noForecast)
        case .missing:
            return nil
        }
    }
}
