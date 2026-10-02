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
        /// The master switch is off: 鬧鐘已關閉 / Alarm Off, under no day (it would read as
        /// that day's alarm).
        case off
        case openApp(TomorrowWidgetTimeline.NeedsApp)
    }

    enum Line: Equatable, Sendable {
        case issue(TomorrowWidgetSnapshot.ScheduleIssue)
        case reason(TomorrowWidgetSnapshot.ReasonLine)
        /// The same reason about today (D-C): every line that names 明天 names 今天 instead.
        case todayReason(TomorrowWidgetSnapshot.ReasonLine)
        case notice(TomorrowWidgetSnapshot.WeatherNotice)
        /// The same notice about today's forecast, in the medium's weather column only
        /// (2026-10-02): the lines that name 明天 name 今天 instead. The presentation never
        /// makes it `.stale`: today's forecast past 3 hours is no warning, and the column's
        /// footer gives its time instead (`weatherColumnFooter`, owner 2026-10-02).
        case todayNotice(TomorrowWidgetSnapshot.WeatherNotice)
        /// A normal ringing day: 照常響鈴 / Rings as usual.
        case ringsAsUsual

        var isWarning: Bool {
            switch self {
            case .issue, .notice(.failed), .notice(.stale), .todayNotice(.failed), .todayNotice(.stale): true
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
                case .alarmOff: LocalizedLine(key: "ux_alarm_off_message_only")
                case .skippedOnce: LocalizedLine(key: "ux_skip_once_reason")
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
                case .rainForecast, .rainEarlier, .routeNeeded, .alarmOff, .skippedOnce: Line.reason(reason).full
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
            case .todayNotice(let notice):
                switch notice {
                // The app's own 今天天氣更新失敗, as the card says it after midnight.
                case .failed: LocalizedLine(key: "ux_today_weather_failed")
                // Not the card's 正在取得今天天氣⋯: the widget cannot fetch anything.
                case .noForecast: LocalizedLine(key: "widget_today_weather_unavailable")
                // These name no day.
                case .stale, .routeNeeded: Line.notice(notice).full
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
                case .alarmOff: LocalizedLine(key: "widget_alarm_off_short")
                case .skippedOnce: LocalizedLine(key: "widget_skip_once_short")
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
            // Every short notice already names no day.
            case .todayNotice(let notice): Line.notice(notice).short
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
    /// Small footer and rectangular line 3. On a today entry it never carries a weather
    /// notice other than "complete your route" (D-C): today's stale, failed or missing
    /// forecast is the medium's weather column's to say (`weatherColumnNotice`).
    var line: Line?
    /// The medium widget's left footer: `line`, unless it repeats the weather notice the
    /// medium's weather column already shows (the notice's own text, or "waiting for the
    /// forecast" beside "no forecast yet"); then the next priority, which is none.
    var mediumLine: Line?
    /// The medium widget draws its weather column (endpoints, footer,  Weather mark, and
    /// the link to Apple's legal page): on every tomorrow entry, and on a today entry that
    /// has something to show there, a forecast or a notice (2026-10-02). A today entry with
    /// neither (one written by build 38 without "complete your route", or past today's
    /// normal time once the app has moved on to tomorrow's forecast) lets the left side take
    /// the width, as build 38 did. A build-38 today entry with "complete your route" gets the
    /// column: 39 writes that same entry, and tomorrow's entry draws it the same way.
    /// Not for the open-the-app faces either.
    var showsWeatherColumn: Bool
    /// The weather column's footer notice, in place of 天氣更新於…: `.todayNotice` on a
    /// today entry (今天), `.notice` on a tomorrow entry. nil without the column, and for
    /// today's stale forecast, which is no notice (`weatherColumnFooter`).
    var weatherColumnNotice: Line?
    /// What the weather column prints under its endpoints, and VoiceOver reads: the notice's
    /// text; else, with a forecast, its time. That is 天氣更新於… / Weather checked…, except on a
    /// today entry whose forecast is past the widget's 3 hours (D-B): 預報時間… / Forecast as
    /// of…, neutral (owner, 2026-10-02). It is normally last evening's forecast, which decided
    /// this morning, and hours old before the ring is expected, not an error. Tomorrow's stale
    /// forecast keeps the warning, and a failed refresh warns on both. nil without the column.
    var weatherColumnFooter: LocalizedLine?
    /// A warning exists that the footer line is not already showing. Today's weather
    /// warnings are the column's own (its footer carries the triangle), not the badge's.
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
    /// The circular face's one word under a skipped day's glyph, so a holiday reads apart
    /// from other skipped days. nil unless skipped. A closure takes the plain skipped word
    /// there (see `closureSource`).
    var skipLabelKey: String?
    /// A closure entry's source credit (DAYOFF-SPEC §7): a face that reports a closure names
    /// the source (the OGDL credit is a licence condition) and the source's own update time,
    /// as the card does. Small, medium and rectangular print it under the closure line, and
    /// the VoiceOver label reads it. The circular and inline faces have no room for it, so
    /// they do not report the closure: a plain skipped day's glyph (`accessoryGlyph`) and
    /// words (`skipLabelKey`, `inlineSkippedText`). nil unless `reason == .disaster`.
    var closureSource: ClosureSource?
    /// The circular and inline faces' glyph: `glyph`, except a closure's storm cloud, which
    /// those faces cannot credit (`closureSource`).
    var accessoryGlyph: Glyph
    /// The inline face's text for a skipped day (the short form is always
    /// widget_inline_(today_)skipped). Every reason line names its day except the one-time
    /// skip's (只關閉這一次…), which gets a line that does; a closure gets the plain skipped
    /// line (`closureSource`). nil unless the hero is `.skipped`.
    var inlineSkippedText: LocalizedLine?
    var relevanceScore: Float

    struct ClosureSource: Equatable, Sendable {
        /// The feed's own update time; nil when it gave none (the credit still shows).
        var updatedAt: Date?
    }

    /// `language` is the one the strings resolve in (`LocalizedLine.resolve`'s bundle); it
    /// names a stored holiday, which the snapshot keeps as DGPA wrote it. `clockFormat` is the
    /// snapshot's (`TomorrowWidgetEntry.clockFormat`): the weather column's footer gives a time.
    init(_ state: TomorrowWidgetTimeline.State, clockFormat: ClockTimeFormat = .twelveHour,
         language: String = Bundle.main.preferredLocalizations.first ?? "en") {
        switch state {
        case .needsApp(let reason):
            glyph = .refresh
            hero = .openApp(reason)
            line = nil
            mediumLine = nil
            showsWeatherColumn = false
            weatherColumnNotice = nil
            weatherColumnFooter = nil
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
            closureSource = nil
            accessoryGlyph = .refresh
            inlineSkippedText = nil
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
                hero = switch entry.reason {
                case .routeIncomplete: .notSet
                case .alarmOff: .off
                default: .skipped
                }
            }

            // The notice the alarm's own lines and badge may carry. A today entry keeps D-C on
            // every face: only "complete your route" (what build 38 stored for today). Today's
            // stale, failed or missing forecast is said in the medium's weather column only
            // (owner, 2026-10-02), worded 今天 there (`weatherColumnNotice`).
            let alarmNotice = entry.isToday && entry.weatherNotice != .routeNeeded ? nil : entry.weatherNotice
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
                if let notice = alarmNotice { lines.append(.notice(notice)) }
                if entry.reasonLine == nil, entry.expectedRingDate != nil { lines.append(.ringsAsUsual) }
                return lines
            }
            line = lines(withWeather: false).first
            // A today entry draws the column when it has something there to attribute or say.
            // Without either (build 38's today entries, bar "complete your route") it stays as
            // build 38 drew it; "complete your route" draws it as 39 writes it and as tomorrow's
            // entries do, so a route-incomplete widget does not change when the app republishes.
            showsWeatherColumn = !entry.isToday || entry.forecast != nil || entry.weatherNotice != nil
            // The weather column prints the notice's own text (stale, failed, no forecast,
            // or route needed, which is also the route-incomplete reason's text), named for its
            // day. Today's stale forecast is no notice (owner, 2026-10-02): the footer gives its
            // time instead. Only a forecast goes stale (`widgetWeatherNotice`); a stale today
            // entry without one, which no build writes, has no time to give, and says so.
            let todaysOldForecast = entry.isToday && entry.weatherNotice == .stale ? entry.forecast : nil
            func columnNotice(_ notice: TomorrowWidgetSnapshot.WeatherNotice) -> Line? {
                guard entry.isToday else { return .notice(notice) }
                guard notice == .stale else { return .todayNotice(notice) }
                return todaysOldForecast == nil ? .todayNotice(.noForecast) : nil
            }
            weatherColumnNotice = showsWeatherColumn ? entry.weatherNotice.flatMap(columnNotice) : nil
            if let notice = weatherColumnNotice {
                weatherColumnFooter = notice.full
            } else if showsWeatherColumn, let forecast = entry.forecast {
                weatherColumnFooter = LocalizedLine(key: todaysOldForecast == nil ? "ux_weather_updated" : "widget_forecast_as_of",
                                                    arguments: [.time(forecast.checkedAt, clockFormat)])
            } else {
                weatherColumnFooter = nil
            }
            let columnText = weatherColumnNotice?.full
            let columnSaysNoForecast = weatherColumnNotice == .notice(.noForecast) || weatherColumnNotice == .todayNotice(.noForecast)
            // Without the column there is no  Weather mark either, so no percentage.
            mediumLine = lines(withWeather: showsWeatherColumn).first { line in
                // "Waiting for tomorrow's (today's) forecast" beside "tomorrow's (today's)
                // forecast is not available yet" says the same thing twice; the column keeps it.
                if line == .reason(.awaitingForecast) || line == .todayReason(.awaitingForecast), columnSaysNoForecast {
                    return false
                }
                return line.full != columnText
            }

            let weatherWarning = alarmNotice == .failed || alarmNotice == .stale
            showsWarningBadge = (weatherWarning || entry.scheduleIssue != nil) && line?.isWarning != true
            hasIssue = entry.scheduleIssue != nil
            // The medium's sky is weather data too: only beside the column that attributes it.
            home = showsWeatherColumn ? entry.forecast?.home.condition : nil
            work = showsWeatherColumn ? entry.forecast?.work?.condition : nil
            decisionSky = entry.appliesRainLead ? .rain : nil
            // Off names no day: "明天 鬧鐘已關閉" would read as only that morning being off.
            day = entry.reason == .alarmOff ? nil : entry.day
            isToday = entry.isToday
            ringIsOnAnotherDay = entry.ringIsOnAnotherDay
            if let ring = entry.expectedRingDate {
                ringDay = entry.ringIsOnAnotherDay ? .on(ring) : entry.isToday ? .today(entry.day) : .tomorrow(entry.day)
            } else {
                ringDay = nil
            }
            let isClosure = entry.reason == .disaster
            closureSource = isClosure ? ClosureSource(updatedAt: entry.closureSourceUpdatedAt) : nil
            accessoryGlyph = glyph == .closure ? .silent : glyph
            switch hero {
            case .skipped:
                skipLabelKey = switch entry.reason {
                case .holiday: "widget_skip_holiday"
                // Not widget_skip_closure (停班, the owner's 2026-09-23 word): the circular face
                // cannot carry the source a closure must name (`closureSource`).
                default: "widget_skip_other"
                }
                let dayless = LocalizedLine(key: entry.isToday ? "widget_inline_today_skipped" : "widget_inline_skipped")
                inlineSkippedText = switch entry.reason {
                case .disaster: dayless
                case .skippedOnce:
                    LocalizedLine(key: entry.isToday ? "widget_inline_today_skip_once" : "widget_inline_skip_once")
                default: line?.full ?? dayless
                }
            case .off:
                skipLabelKey = "widget_skip_off"
                inlineSkippedText = nil
            default:
                skipLabelKey = nil
                inlineSkippedText = nil
            }
            if entry.appliesRainLead || entry.scheduleIssue != nil { relevanceScore = 50 }
            else if entry.reason == .alarmOff { relevanceScore = 1 }
            else if entry.expectedRingDate != nil { relevanceScore = 10 }
            else { relevanceScore = 5 }
        }
    }

    /// 今天 / Today for today's entry, else 明天 / Tomorrow; nil when no day is shown.
    var dayWordKey: String? {
        guard day != nil else { return nil }
        return isToday ? "widget_today" : "ux_tomorrow"
    }

    /// A condition's name: 晴天 / Sunny, 多雲 / Cloudy, 下雨 / Rainy.
    static func conditionKey(_ condition: TomorrowWidgetSnapshot.Condition) -> String {
        switch condition {
        case .clear: "ux_weather_clear"
        case .cloudy: "ux_weather_cloudy"
        case .rain: "ux_weather_rain"
        }
    }

    /// The medium's weather column as VoiceOver reads it, the column being one link: each
    /// endpoint with its condition and rain chance, the footer it prints (`weatherColumnFooter`:
    /// a notice, or the forecast's time), and the Apple Weather attribution the link leads to.
    /// `forecast` is the entry's; `text` resolves a line in the widget's language
    /// (`LocalizedLine.resolve`), and `separator` lists the pieces in it.
    func weatherColumnAccessibilityLabel(forecast: TomorrowWidgetSnapshot.RouteForecast?, separator: String,
                                         text: (LocalizedLine) -> String) -> String {
        var pieces: [String] = []
        for (key, endpoint) in [("ux_weather_home", forecast?.home), ("ux_weather_work", forecast?.work)] {
            guard let endpoint else { continue }
            pieces.append([text(LocalizedLine(key: key)), text(LocalizedLine(key: Self.conditionKey(endpoint.condition))),
                           text(LocalizedLine(key: "ux_rain_chance", arguments: [.int(endpoint.percent)]))].joined(separator: " "))
        }
        if let footer = weatherColumnFooter { pieces.append(text(footer)) }
        pieces.append("Apple Weather")
        return pieces.joined(separator: separator)
    }
}

/// A string-table key plus its format arguments, resolved inside whichever bundle
/// renders it (the widget extension's own tables at runtime).
struct LocalizedLine: Equatable, Sendable {
    enum Argument: Equatable, Sendable {
        case int(Int)
        case string(String)
        /// A time (`%@`), written as `ClockTimeFormat` writes it in the language the line
        /// resolves in: the app's 12/24-hour setting and 上午-first order, as every widget time.
        case time(Date, ClockTimeFormat)
    }

    var key: String
    var arguments: [Argument] = []

    /// `bundle.localizedString(forKey:value:table:)`, then, when arguments are
    /// present, `String(format:locale:arguments:)` in the bundle's own localization.
    func resolve(in bundle: Bundle = .main) -> String {
        filled(bundle.localizedString(forKey: key, value: nil, table: nil),
               language: bundle.preferredLocalizations.first ?? "en")
    }

    /// `format`, this key's string in `language`'s table, with the arguments filled in as that
    /// language writes them; a time in `timeZone`, the device's on the widget.
    func filled(_ format: String, language: String, timeZone: TimeZone = .current) -> String {
        guard !arguments.isEmpty else { return format }
        let locale = Locale(identifier: language)
        let values: [any CVarArg] = arguments.map { argument -> any CVarArg in
            switch argument {
            case .int(let value): return value
            case .string(let value): return value
            case .time(let date, let clock): return clock.time(date, locale: locale, timeZone: timeZone)
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
        // The master switch (1.8.0).
        "ux_alarm_off", "ux_alarm_off_message_only", "ux_skip_once_reason",
        // The medium's weather column on a today entry (2026-10-02), as the card says it.
        "ux_today_weather_failed",
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
        // widget_skip_closure is unused since 2026-10-01 (see `closureSource`); kept for an
        // owner-recorded DAYOFF-SPEC §7 exception for the circular face.
        "widget_skip_holiday", "widget_skip_closure", "widget_skip_other",
        "widget_awaiting_forecast_short",
        // Today, between midnight and today's ring (D-C).
        "widget_today", "widget_today_awaiting_forecast",
        "widget_today_holiday_named", "widget_today_holiday", "widget_today_manual_skip", "widget_today_manual_ring",
        "widget_today_weekend", "widget_today_unselected", "widget_today_closure",
        "widget_inline_today_ring", "widget_inline_today_rain", "widget_inline_today_skipped",
        // The medium's weather column on a today entry without a forecast (2026-10-02), and with
        // one past the widget's 3 hours: its time, neutral (owner, 2026-10-02).
        "widget_today_weather_unavailable", "widget_forecast_as_of",
        // The medium's weather column is a link to Apple's legal attribution page (D-A).
        "widget_weather_legal_hint",
        // The master switch (1.8.0): the circular word, and the rectangular's short lines.
        "widget_skip_off", "widget_alarm_off_short", "widget_skip_once_short",
        // The inline one-time skip names its day, and a closure names its source (§7) (2026-10-01).
        "widget_inline_skip_once", "widget_inline_today_skip_once",
        "widget_closure_source", "widget_closure_source_updated",
    ]
}

/// Sample data for the widget gallery (ships in Release; plain data), the DEBUG
/// demo and the tests. Nothing here reads the user's settings.
enum TomorrowWidgetSamples {
    enum Scenario: String, CaseIterable, Sendable {
        case normalClear, cloudyNormal, rainForecast, rainMixed, rainStale, holidayNamed, holidayUnnamed, weekend,
             unselectedWeekday, manualSkip, manualRing, closure, skippedOnce, alarmOff, routeIncomplete, weatherFailed,
             forecastUnavailable,
             scheduleUpdateNeeded, schedulingFailed, alarmKitReschedule, closureUncertain, closureUpdateFailed,
             ringPreviousDay, carriedOver, todayRain, todayNormal, todaySkipped, todayCarriedOver,
             todayHolidayNamed, todayHolidayUnnamed, todayManualSkip, todayManualRing, todayUnselectedWeekday, todayClosure,
             todayStale, todayWeatherFailed, todayForecastUnavailable,
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
                           weatherNotice: notice, scheduleIssue: issue,
                           // A closure names its source's own time, as a real snapshot does (§7).
                           closureSourceUpdatedAt: reason == .disaster ? now.addingTimeInterval(-2 * 3_600) : nil)
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
        case .skippedOnce:
            // The master switch's "turn off only the next alarm".
            return make(ring: nil, reason: .skippedOnce, line: .skippedOnce, forecast: forecast(.cloudy, 30, .clear, 10))
        case .alarmOff:
            return make(ring: nil, reason: .alarmOff, line: .alarmOff, forecast: forecast(.clear, 10, .cloudy, 20))
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
        // Today's entries carry this morning's forecast (2026-10-02): after midnight the coming
        // morning the app fetches IS today. The medium shows it in its weather column with the
        //  Weather mark; every other face shows the decision only, as on tomorrow's entries.
        case .todayRain:
            // 今天 上午7:00 因雨提早 30 分鐘, decided by a forecast fetched after midnight that is
            // still fresh: the medium names the route's rain chance, as the builder writes it.
            return make(ring: todayEarly, reason: .rain, line: .rainForecast(percent: 80, minutes: 30), lead: 30,
                        normalDate: todayNormal, forecast: forecast(.rain, 80, .rain, 70), isToday: true)
        case .todayNormal:
            return make(ring: todayNormal, reason: .normal, normalDate: todayNormal, forecast: forecast(.clear, 10, .cloudy, 20),
                        isToday: true)
        case .todaySkipped:
            return make(ring: nil, reason: .weekend, line: .weekend, normalDate: todayNormal,
                        forecast: forecast(.clear, 0, .clear, 10), isToday: true)
        case .todayCarriedOver:
            // Yesterday's rain lead, repeated this morning; no forecast has decided today.
            return make(ring: todayEarly, reason: .rain, line: .awaitingForecast, lead: 30, normalDate: todayNormal,
                        forecast: nil, notice: .noForecast, isToday: true)
        case .todayHolidayNamed:
            return make(ring: nil, reason: .holiday, line: .holidayNamed(name), normalDate: todayNormal,
                        forecast: forecast(.clear, 10, .cloudy, 20), isToday: true)
        case .todayHolidayUnnamed:
            return make(ring: nil, reason: .holiday, line: .holiday, normalDate: todayNormal,
                        forecast: forecast(.cloudy, 20, .cloudy, 30), isToday: true)
        case .todayManualSkip:
            return make(ring: nil, reason: .manual, line: .manualSkip, normalDate: todayNormal,
                        forecast: forecast(.rain, 60, .cloudy, 40), isToday: true)
        case .todayManualRing:
            return make(ring: todayNormal, reason: .manual, line: .manualRing, normalDate: todayNormal,
                        forecast: forecast(.clear, 10, .clear, 10), isToday: true)
        case .todayUnselectedWeekday:
            return make(ring: nil, reason: .unselectedWeekday, line: .unselectedWeekday, normalDate: todayNormal,
                        forecast: forecast(.cloudy, 30, .clear, 10), isToday: true)
        case .todayClosure:
            return make(ring: nil, reason: .disaster, line: .closure, normalDate: todayNormal,
                        forecast: forecast(.rain, 90, .rain, 95), isToday: true)
        // Today's weather in the medium's column only: a forecast past 3 hours, and two notices (今天 there).
        case .todayStale:
            // Last evening's forecast, more than 3 hours old: 預報時間 and its time, neutral (owner, 2026-10-02).
            return make(ring: todayNormal, reason: .normal, normalDate: todayNormal,
                        forecast: forecast(.cloudy, 30, .clear, 10, checkedAt: old), notice: .stale, isToday: true)
        case .todayWeatherFailed:
            // 今天天氣更新失敗, beside the last good forecast.
            return make(ring: todayNormal, reason: .normal, normalDate: todayNormal,
                        forecast: forecast(.cloudy, 20, .clear, 10, checkedAt: old), notice: .failed, isToday: true)
        case .todayForecastUnavailable:
            // 尚未取得今天天氣.
            return make(ring: todayNormal, reason: .normal, normalDate: todayNormal, forecast: nil, notice: .noForecast,
                        isToday: true)
        case .carriedOver:
            // Tuesday's 07:00 rain ring has fired; the weekly repeat rings Wednesday at 07:00
            // too, but no forecast for Wednesday has decided that yet.
            return make(ring: early, reason: .rain, line: .awaitingForecast, lead: 30, forecast: nil, notice: .noForecast)
        case .missing:
            return nil
        }
    }
}
