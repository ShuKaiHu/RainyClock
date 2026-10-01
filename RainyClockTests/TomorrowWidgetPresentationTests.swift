import XCTest
@testable import RainyClock

/// The widget's display rules, which live in plain data so they can be tested here.
final class TomorrowWidgetPresentationTests: XCTestCase {
    private typealias Presentation = TomorrowWidgetPresentation
    private typealias Scenario = TomorrowWidgetSamples.Scenario

    private var calendar: Calendar { DisasterNoticeParser.taipeiCalendar }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 21))! }

    private func state(_ scenario: Scenario) -> TomorrowWidgetTimeline.State {
        let snapshot = TomorrowWidgetSamples.snapshot(scenario, now: now, calendar: calendar, holidayName: "國慶日")
        return TomorrowWidgetTimeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: calendar.timeZone.identifier)
            .items[0].state
    }

    /// zh-Hant so the stored holiday name reads back as stored, whatever the host's language.
    private func presentation(_ scenario: Scenario) -> Presentation { Presentation(state(scenario), language: "zh-Hant") }

    private func heroKind(_ hero: Presentation.Hero) -> String {
        switch hero {
        case .time(_, let original): original == nil ? "time" : "time+original"
        case .skipped: "skipped"
        case .notSet: "notSet"
        case .off: "off"
        case .openApp(let reason): "openApp.\(reason.rawValue)"
        }
    }

    func testGlyphHeroAndLinePerScenario() {
        let table: [Scenario: (Presentation.Glyph, String, Presentation.Line?)] = [
            // D-A: outside the medium, the decision only: no route rain %, no percentage in the rain line.
            .normalClear: (.alarm, "time", .ringsAsUsual),
            .cloudyNormal: (.alarm, "time", .ringsAsUsual),
            .rainForecast: (.rain, "time+original", .reason(.rainEarlier(minutes: 30))),
            .rainMixed: (.rain, "time+original", .reason(.rainEarlier(minutes: 30))),
            .rainStale: (.rain, "time+original", .reason(.rainEarlier(minutes: 30))),
            .holidayNamed: (.silent, "skipped", .reason(.holidayNamed("國慶日"))),
            .holidayUnnamed: (.silent, "skipped", .reason(.holiday)),
            .weekend: (.silent, "skipped", .reason(.weekend)),
            .unselectedWeekday: (.silent, "skipped", .reason(.unselectedWeekday)),
            .manualSkip: (.silent, "skipped", .reason(.manualSkip)),
            .manualRing: (.manualRing, "time", .reason(.manualRing)),
            .closure: (.closure, "skipped", .reason(.closure)),
            // The master switch (1.8.0): only this morning off, or off until turned back on.
            .skippedOnce: (.silent, "skipped", .reason(.skippedOnce)),
            .alarmOff: (.silent, "off", .reason(.alarmOff)),
            .routeIncomplete: (.route, "notSet", .reason(.routeNeeded)),
            .weatherFailed: (.alarm, "time", .notice(.failed)),
            .forecastUnavailable: (.alarm, "time", .notice(.noForecast)),
            .scheduleUpdateNeeded: (.alarm, "time", .issue(.updateNeeded)),
            .schedulingFailed: (.alarm, "time", .issue(.schedulingFailed)),
            .alarmKitReschedule: (.rain, "time+original", .issue(.alarmKitReschedule)),
            .closureUncertain: (.alarm, "time", .issue(.closureUncertain)),
            .closureUpdateFailed: (.alarm, "time", .issue(.closureUpdateFailed)),
            .ringPreviousDay: (.rain, "time+original", .reason(.rainEarlier(minutes: 30))),
            // D-D: the registered early time, but neither the rain glyph nor 因雨提早.
            .carriedOver: (.alarm, "time+original", .reason(.awaitingForecast)),
            // D-C: today's alarm between midnight and its ring.
            .todayRain: (.rain, "time+original", .todayReason(.rainEarlier(minutes: 30))),
            .todayNormal: (.alarm, "time", .ringsAsUsual),
            .todaySkipped: (.silent, "skipped", .todayReason(.weekend)),
            .todayCarriedOver: (.alarm, "time+original", .todayReason(.awaitingForecast)),
            .todayHolidayNamed: (.silent, "skipped", .todayReason(.holidayNamed("國慶日"))),
            .todayHolidayUnnamed: (.silent, "skipped", .todayReason(.holiday)),
            .todayManualSkip: (.silent, "skipped", .todayReason(.manualSkip)),
            .todayManualRing: (.manualRing, "time", .todayReason(.manualRing)),
            .todayUnselectedWeekday: (.silent, "skipped", .todayReason(.unselectedWeekday)),
            .todayClosure: (.closure, "skipped", .todayReason(.closure)),
            // Today's weather notices are the medium column's only (2026-10-02): every other
            // face shows the decision, as build 38 did (D-C).
            .todayStale: (.alarm, "time", .ringsAsUsual),
            .todayWeatherFailed: (.alarm, "time", .ringsAsUsual),
            .todayForecastUnavailable: (.alarm, "time", .ringsAsUsual),
            .expired: (.refresh, "openApp.expired", nil),
            .missing: (.refresh, "openApp.missing", nil),
        ]
        XCTAssertEqual(Set(table.keys), Set(Scenario.allCases), "Every scenario needs an expectation")
        for scenario in Scenario.allCases {
            guard let (glyph, hero, line) = table[scenario] else { continue }
            let value = presentation(scenario)
            XCTAssertEqual(value.glyph, glyph, "\(scenario)")
            XCTAssertEqual(heroKind(value.hero), hero, "\(scenario)")
            XCTAssertEqual(value.line, line, "\(scenario)")
            XCTAssertEqual(value.hasIssue, { if case .issue = line { true } else { false } }(), "\(scenario)")
        }
        XCTAssertTrue(presentation(.ringPreviousDay).ringIsOnAnotherDay)
        XCTAssertFalse(presentation(.rainForecast).ringIsOnAnotherDay)
        XCTAssertNil(presentation(.expired).home)
        XCTAssertNil(presentation(.expired).day)
        // Off names no day: 明天 above 鬧鐘已關閉 would read as only that morning being off.
        XCTAssertNil(presentation(.alarmOff).day)
        XCTAssertNil(presentation(.alarmOff).dayWordKey)
        XCTAssertNotNil(presentation(.skippedOnce).day, "Skipped once is about one morning, which it names")
        // The medium's sky is the forecast's (weather, attributed there)...
        XCTAssertEqual(presentation(.rainMixed).home, .clear)
        XCTAssertEqual(presentation(.rainMixed).work, .rain)
        // ...the small's is the decision's: rain for a rain-moved alarm, else the neutral navy
        // (nil), never a sunny sky nothing decided.
        XCTAssertEqual(presentation(.rainMixed).decisionSky, .rain)
        XCTAssertEqual(presentation(.todayRain).decisionSky, .rain)
        for scenario in [Scenario.normalClear, .cloudyNormal, .manualSkip, .carriedOver, .weatherFailed, .forecastUnavailable,
                         .closure, .routeIncomplete, .todayNormal, .todayCarriedOver, .todayStale, .todayWeatherFailed,
                         .todayForecastUnavailable, .expired, .missing] {
            XCTAssertNil(presentation(scenario).decisionSky, "\(scenario)")
        }

        XCTAssertEqual(presentation(.rainForecast).relevanceScore, 50)
        XCTAssertEqual(presentation(.scheduleUpdateNeeded).relevanceScore, 50)
        XCTAssertEqual(presentation(.normalClear).relevanceScore, 10)
        XCTAssertEqual(presentation(.carriedOver).relevanceScore, 10, "A carried-over lead is not a rain day")
        XCTAssertEqual(presentation(.weekend).relevanceScore, 5)
        XCTAssertEqual(presentation(.routeIncomplete).relevanceScore, 5)
        XCTAssertEqual(presentation(.skippedOnce).relevanceScore, 5)
        XCTAssertEqual(presentation(.alarmOff).relevanceScore, 1, "Nothing will ring: the least relevant face")
        XCTAssertEqual(presentation(.missing).relevanceScore, 1)

        // Route incomplete wins the glyph even over a closure or silence.
        if case .status(var entry) = state(.closure) {
            entry.reason = .routeIncomplete
            XCTAssertEqual(Presentation(.status(entry)).glyph, .route)
        } else { XCTFail("closure sample must be a status") }
    }

    func testWarningBadgeOnlyWhenLineIsNotTheWarning() {
        XCTAssertTrue(presentation(.rainStale).showsWarningBadge, "Stale weather behind a rain reason line")
        XCTAssertFalse(presentation(.weatherFailed).showsWarningBadge, "The footer already shows the failure")
        XCTAssertFalse(presentation(.scheduleUpdateNeeded).showsWarningBadge, "The footer already shows the issue")
        XCTAssertFalse(presentation(.normalClear).showsWarningBadge)
        XCTAssertFalse(presentation(.forecastUnavailable).showsWarningBadge, "No forecast yet is not a warning")
        XCTAssertFalse(presentation(.expired).showsWarningBadge)

        guard case .status(var entry) = state(.holidayNamed) else { return XCTFail("holiday sample must be a status") }
        entry.weatherNotice = .failed
        XCTAssertTrue(Presentation(.status(entry)).showsWarningBadge)
        entry.scheduleIssue = .updateNeeded
        XCTAssertFalse(Presentation(.status(entry)).showsWarningBadge)

        // Today's stale or failed forecast is said in the medium's weather column, whose footer
        // carries its own triangle; the badge, like every other face, keeps D-C (2026-10-02).
        XCTAssertFalse(presentation(.todayStale).showsWarningBadge)
        XCTAssertFalse(presentation(.todayWeatherFailed).showsWarningBadge)
        XCTAssertFalse(presentation(.todayForecastUnavailable).showsWarningBadge)
        guard case .status(var today) = state(.todayStale) else { return XCTFail("todayStale sample must be a status") }
        today.scheduleIssue = .updateNeeded
        XCTAssertEqual(Presentation(.status(today)).line, .issue(.updateNeeded))
        XCTAssertFalse(Presentation(.status(today)).showsWarningBadge, "The line is the warning; the stale forecast is the column's")
        XCTAssertTrue(Presentation.Line.todayNotice(.stale).isWarning)
        XCTAssertTrue(Presentation.Line.todayNotice(.failed).isWarning)
        XCTAssertFalse(Presentation.Line.todayNotice(.noForecast).isWarning)
        XCTAssertFalse(Presentation.Line.todayNotice(.routeNeeded).isWarning)

        XCTAssertTrue(Presentation.Line.issue(.updateNeeded).isWarning)
        XCTAssertTrue(Presentation.Line.notice(.stale).isWarning)
        XCTAssertFalse(Presentation.Line.notice(.routeNeeded).isWarning)
        XCTAssertEqual(Presentation.Line.notice(.failed).leadingSymbol, "exclamationmark.triangle.fill")
        XCTAssertNil(Presentation.Line.ringsAsUsual.leadingSymbol)
        XCTAssertNil(Presentation.Line.reason(.weekend).leadingSymbol)
    }

    func testMediumLineNeverRepeatsTheWeatherColumn() {
        // The weather column prints the notice; the left footer falls through to the next
        // priority, and with a notice present there is none (route rain needs fresh weather).
        for scenario in Scenario.allCases {
            let value = presentation(scenario)
            guard case .status(let entry) = state(scenario) else {
                XCTAssertNil(value.mediumLine, "\(scenario)")
                XCTAssertNil(value.weatherColumnNotice, "\(scenario)")
                continue
            }
            // The column's notice is the entry's, named for its day (今天 on a today entry).
            XCTAssertEqual(value.weatherColumnNotice,
                           entry.weatherNotice.map { entry.isToday ? .todayNotice($0) : .notice($0) }, "\(scenario)")
            if let column = value.weatherColumnNotice {
                XCTAssertNotEqual(value.mediumLine?.full, column.full, "\(scenario) says it twice")
            } else if case .reason(.rainForecast(_, let minutes))? = value.mediumLine {
                // The medium may name the route's rain chance; the others say the decision.
                XCTAssertEqual(value.line, .reason(.rainEarlier(minutes: minutes)), "\(scenario)")
            } else if case .todayReason(.rainForecast(_, let minutes))? = value.mediumLine {
                XCTAssertEqual(value.line, .todayReason(.rainEarlier(minutes: minutes)), "\(scenario)")
            } else {
                XCTAssertEqual(value.mediumLine, value.line, "\(scenario)")
            }
        }
        XCTAssertEqual(presentation(.rainForecast).mediumLine, .reason(.rainForecast(percent: 80, minutes: 30)))
        XCTAssertEqual(presentation(.rainStale).line, .reason(.rainEarlier(minutes: 30)))
        XCTAssertEqual(presentation(.rainStale).mediumLine, .reason(.rainEarlier(minutes: 30)))
        XCTAssertEqual(presentation(.weatherFailed).line, .notice(.failed))
        XCTAssertEqual(presentation(.weatherFailed).mediumLine, .ringsAsUsual, "The column says it failed; the footer, the decision")
        XCTAssertEqual(presentation(.forecastUnavailable).mediumLine, .ringsAsUsual)
        XCTAssertEqual(presentation(.routeIncomplete).line, .reason(.routeNeeded))
        XCTAssertNil(presentation(.routeIncomplete).mediumLine, "請完成路線 is already the column's notice")
        XCTAssertEqual(presentation(.normalClear).mediumLine, .ringsAsUsual)
        // A carried-over lead: 等待明天預報 beside the column's 尚未取得明天天氣 would say it twice.
        XCTAssertEqual(presentation(.carriedOver).line, .reason(.awaitingForecast), "Outside the medium the reason stays")
        XCTAssertNil(presentation(.carriedOver).mediumLine, "The column already says there is no forecast yet")
        // The same for today (2026-10-02): 等待今天預報 beside 尚未取得今天天氣.
        XCTAssertEqual(presentation(.todayCarriedOver).line, .todayReason(.awaitingForecast))
        XCTAssertNil(presentation(.todayCarriedOver).mediumLine, "The column already says there is no forecast for today yet")
        XCTAssertEqual(presentation(.todayRain).line, .todayReason(.rainEarlier(minutes: 30)))
        XCTAssertEqual(presentation(.todayRain).mediumLine, .todayReason(.rainForecast(percent: 80, minutes: 30)),
                       "Beside the column and its mark, today's route rain chance too")
        for scenario in [Scenario.todayStale, .todayWeatherFailed, .todayForecastUnavailable] {
            XCTAssertEqual(presentation(scenario).mediumLine, .ringsAsUsual, "\(scenario): the column says it; the footer, the decision")
        }

        guard case .status(var entry) = state(.normalClear) else { return XCTFail("normalClear must be a status") }
        entry.weatherNotice = .stale
        XCTAssertEqual(Presentation(.status(entry)).line, .notice(.stale), "Data age is not weather data: it may stay")
        XCTAssertEqual(Presentation(.status(entry)).mediumLine, .ringsAsUsual, "Only the column says it is stale")
        entry.scheduleIssue = .updateNeeded
        XCTAssertEqual(Presentation(.status(entry)).mediumLine, .issue(.updateNeeded))
    }

    func testRingDayIsNeverTomorrowWhenRainCrossesMidnight() throws {
        for scenario in Scenario.allCases {
            let value = presentation(scenario)
            switch value.hero {
            case .time(let ring, _):
                let day = try XCTUnwrap(value.day, "\(scenario)")
                if scenario == .ringPreviousDay {
                    XCTAssertEqual(value.ringDay, .on(ring))
                    XCTAssertFalse(calendar.isDate(ring, inSameDayAs: day), "The sample rings the evening before")
                } else if value.isToday {
                    XCTAssertEqual(value.ringDay, .today(day), "\(scenario)")
                    XCTAssertTrue(calendar.isDate(ring, inSameDayAs: day), "\(scenario)")
                } else {
                    XCTAssertEqual(value.ringDay, .tomorrow(day), "\(scenario)")
                    XCTAssertTrue(calendar.isDate(ring, inSameDayAs: day), "\(scenario)")
                }
            default:
                XCTAssertNil(value.ringDay, "\(scenario)")
            }
        }
    }

    /// D-A: every family but the medium shows the alarm decision and nothing WeatherKit
    /// produced: no rain percentage, no condition name, no condition-drawn sky or symbol.
    func testNoWeatherDataOutsideTheMedium() {
        let weatherKeys: Set<String> = ["ux_rain_applied_forecast", "ux_rain_chance", "ux_weather_clear",
                                        "ux_weather_cloudy", "ux_weather_rain", "ux_weather_updated"]
        let conditions: [TomorrowWidgetSnapshot.Condition] = [.clear, .cloudy, .rain]
        for scenario in Scenario.allCases {
            guard case .status(let base) = state(scenario) else { continue }
            var faces: [Presentation] = []
            // The same decision under every forecast the snapshot could carry.
            for home in conditions {
                for percent in [0, 55, 100] {
                    var entry = base
                    entry.forecast = .init(checkedAt: now, home: .init(condition: home, percent: percent),
                                           work: .init(condition: home, percent: percent), maximumPercent: percent)
                    faces.append(Presentation(.status(entry), language: "zh-Hant"))
                }
            }
            var bare = base
            bare.forecast = nil
            faces.append(Presentation(.status(bare), language: "zh-Hant"))
            for face in faces {
                XCTAssertEqual(face.line, faces[0].line, "\(scenario): the line must not follow the forecast")
                XCTAssertEqual(face.decisionSky, faces[0].decisionSky, "\(scenario): the small sky must not follow the forecast")
                XCTAssertEqual(face.glyph, faces[0].glyph, "\(scenario)")
                XCTAssertNotEqual(face.decisionSky, .cloudy, "\(scenario)")
                if let line = face.line {
                    XCTAssertFalse(weatherKeys.contains(line.full.key), "\(scenario): \(line.full.key)")
                    XCTAssertFalse(weatherKeys.contains(line.short.key), "\(scenario): \(line.short.key)")
                }
            }
            let face = faces[0]
            XCTAssertEqual(face.decisionSky == .rain, base.appliesRainLead, "\(scenario): rain sky only for a rain-moved alarm")
            // A normal ringing day says so, unless an issue or a freshness notice comes first.
            if base.reasonLine == nil, base.expectedRingDate != nil, base.scheduleIssue == nil, base.weatherNotice == nil {
                XCTAssertEqual(face.line, .ringsAsUsual, "\(scenario)")
            }
        }
        XCTAssertEqual(Presentation.Line.ringsAsUsual.full.key, "widget_rings_as_usual")
    }

    private var todayScenarios: [Scenario] { Scenario.allCases.filter { $0.rawValue.hasPrefix("today") } }

    /// D-C: today's entry names today everywhere a day is named.
    func testTodayEntriesSayToday() {
        XCTAssertEqual(todayScenarios.count, 13)
        for scenario in todayScenarios {
            let value = presentation(scenario)
            XCTAssertTrue(value.isToday, "\(scenario)")
            XCTAssertEqual(value.dayWordKey, "widget_today", "\(scenario)")
            XCTAssertEqual(value.day, calendar.startOfDay(for: now), "\(scenario)")
            if case .todayReason(let reason)? = value.line {
                XCTAssertTrue(reason == .rainEarlier(minutes: 30) || Presentation.Line.todayReason(reason).full.key.hasPrefix("widget_today"),
                              "\(scenario): every line that names a day says today")
            }
        }
        for scenario in Scenario.allCases where !todayScenarios.contains(scenario) {
            let value = presentation(scenario)
            XCTAssertFalse(value.isToday, "\(scenario)")
            XCTAssertEqual(value.dayWordKey, value.day == nil ? nil : "ux_tomorrow", "\(scenario)")
        }
        // Every reason that names 明天 has its own today line; those that name no day are shared.
        typealias Line = Presentation.Line
        let named: [(TomorrowWidgetSnapshot.ReasonLine, String)] = [
            (.awaitingForecast, "widget_today_awaiting_forecast"), (.holidayNamed("國慶日"), "widget_today_holiday_named"),
            (.holiday, "widget_today_holiday"), (.manualSkip, "widget_today_manual_skip"),
            (.manualRing, "widget_today_manual_ring"), (.weekend, "widget_today_weekend"),
            (.unselectedWeekday, "widget_today_unselected"), (.closure, "widget_today_closure")]
        for (reason, key) in named {
            XCTAssertEqual(Line.todayReason(reason).full.key, key)
            XCTAssertNotEqual(Line.reason(reason).full.key, key)
        }
        for reason in [TomorrowWidgetSnapshot.ReasonLine.rainForecast(percent: 80, minutes: 30), .rainEarlier(minutes: 30), .routeNeeded] {
            XCTAssertEqual(Line.todayReason(reason).full, Line.reason(reason).full)
            XCTAssertEqual(Line.todayReason(reason).short, Line.reason(reason).short)
        }
        XCTAssertEqual(Line.todayReason(.weekend).short.key, "widget_today_weekend", "Never falls back to 明天是週末")
        XCTAssertEqual(Line.todayReason(.holiday).short.key, "widget_today_holiday")
        XCTAssertEqual(presentation(.todayRain).relevanceScore, 50)
    }

    /// Owner 2026-10-02: today's entries show the medium's weather column too (this morning's
    /// forecast, the  Weather mark and the link to Apple's legal page) whenever they have a
    /// forecast or a notice to show. A today entry with neither, as build 38 wrote every one,
    /// keeps build 38's column-less face, with no weather data at all.
    func testTodayEntriesShowTheMediumWeatherColumn() {
        for scenario in todayScenarios {
            guard case .status(let entry) = state(scenario) else { return XCTFail("\(scenario) must be a status") }
            XCTAssertTrue(entry.forecast != nil || entry.weatherNotice != nil, "\(scenario): something for the column")
            let value = presentation(scenario)
            XCTAssertTrue(value.showsWeatherColumn, "\(scenario)")
            XCTAssertEqual(value.home, entry.forecast?.home.condition, "\(scenario)")
            XCTAssertEqual(value.work, entry.forecast?.work?.condition, "\(scenario)")
            if let column = value.weatherColumnNotice, case .notice = column {
                XCTFail("\(scenario): \(column) would name 明天 on today's column")
            }
        }
        XCTAssertEqual(presentation(.todayRain).home, .rain)
        XCTAssertEqual(presentation(.todayNormal).home, .clear)
        XCTAssertEqual(presentation(.todayNormal).work, .cloudy)
        XCTAssertNil(presentation(.todayNormal).weatherColumnNotice, "A fresh forecast: 天氣更新於…")
        XCTAssertEqual(presentation(.todayStale).weatherColumnNotice, .todayNotice(.stale))
        XCTAssertEqual(presentation(.todayWeatherFailed).weatherColumnNotice, .todayNotice(.failed))
        XCTAssertEqual(presentation(.todayForecastUnavailable).weatherColumnNotice, .todayNotice(.noForecast))
        XCTAssertEqual(presentation(.todayCarriedOver).weatherColumnNotice, .todayNotice(.noForecast))
        XCTAssertNil(presentation(.todayForecastUnavailable).home, "No forecast: the endpoints read —, the sky is the brand's")

        // A build-38 today entry (no forecast, no notice): no column, so no mark, no sky, and
        // no route rain percentage in the left line.
        for scenario in todayScenarios {
            guard case .status(var entry) = state(scenario) else { continue }
            entry.forecast = nil
            entry.weatherNotice = nil
            let old = Presentation(.status(entry), language: "zh-Hant")
            XCTAssertFalse(old.showsWeatherColumn, "\(scenario)")
            XCTAssertNil(old.weatherColumnNotice, "\(scenario)")
            XCTAssertNil(old.home, "\(scenario)")
            XCTAssertNil(old.work, "\(scenario)")
            XCTAssertEqual(old.mediumLine, old.line, "\(scenario): nothing beside it to repeat")
        }
        guard case .status(var bare) = state(.todayRain) else { return XCTFail("todayRain must be a status") }
        bare.forecast = nil
        bare.weatherNotice = nil
        XCTAssertEqual(Presentation(.status(bare), language: "zh-Hant").mediumLine, .todayReason(.rainEarlier(minutes: 30)),
                       "No percentage without the mark")
        // Only "complete your route": the column says it, as on tomorrow's entries; the footer does not repeat it.
        guard case .status(var route) = state(.todayNormal) else { return XCTFail("todayNormal must be a status") }
        route.reason = .routeIncomplete
        route.reasonLine = .routeNeeded
        route.expectedRingDate = nil
        route.forecast = nil
        route.weatherNotice = .routeNeeded
        let routeFace = Presentation(.status(route), language: "zh-Hant")
        XCTAssertTrue(routeFace.showsWeatherColumn)
        XCTAssertEqual(routeFace.weatherColumnNotice?.full.key, "ux_route_needed")
        XCTAssertEqual(routeFace.line, .todayReason(.routeNeeded))
        XCTAssertNil(routeFace.mediumLine)
        // Every tomorrow face keeps the column; the open-the-app faces have none.
        for scenario in Scenario.allCases where !todayScenarios.contains(scenario) {
            XCTAssertEqual(presentation(scenario).showsWeatherColumn, scenario != .expired && scenario != .missing, "\(scenario)")
        }
    }

    /// The column's today notices name 今天; the ones that name no day are shared, short forms
    /// included, and so is what counts as a warning.
    func testTodayWeatherNoticesNameToday() {
        typealias Line = Presentation.Line
        XCTAssertEqual(Line.todayNotice(.failed).full.key, "ux_today_weather_failed")
        XCTAssertEqual(Line.todayNotice(.noForecast).full.key, "widget_today_weather_unavailable")
        XCTAssertEqual(Line.notice(.failed).full.key, "ux_tomorrow_weather_failed")
        XCTAssertEqual(Line.notice(.noForecast).full.key, "ux_tomorrow_weather_unavailable")
        for notice in [TomorrowWidgetSnapshot.WeatherNotice.stale, .routeNeeded] {
            XCTAssertEqual(Line.todayNotice(notice).full, Line.notice(notice).full, "\(notice)")
        }
        for notice in TomorrowWidgetSnapshot.WeatherNotice.allCases {
            XCTAssertEqual(Line.todayNotice(notice).short, Line.notice(notice).short, "\(notice)")
            XCTAssertEqual(Line.todayNotice(notice).isWarning, Line.notice(notice).isWarning, "\(notice)")
            XCTAssertEqual(Line.todayNotice(notice).leadingSymbol, Line.notice(notice).leadingSymbol, "\(notice)")
        }
    }

    /// D-A: weather data on the medium (its sky, the route's rain chance) only ever appears
    /// beside the column that draws the  Weather mark and the legal link, and so does a
    /// column notice; whatever forecast, notice or rain line the entry carries.
    func testWeatherDataOnlyBesideTheMark() {
        let forecasts: [TomorrowWidgetSnapshot.RouteForecast?] = [
            nil, .init(checkedAt: now, home: .init(condition: .rain, percent: 80), work: .init(condition: .clear, percent: 10),
                       maximumPercent: 80)]
        let notices: [TomorrowWidgetSnapshot.WeatherNotice?] = [nil] + TomorrowWidgetSnapshot.WeatherNotice.allCases
        func carriesPercentage(_ line: Presentation.Line?) -> Bool {
            switch line {
            case .reason(.rainForecast)?, .todayReason(.rainForecast)?: true
            default: false
            }
        }
        for scenario in Scenario.allCases {
            guard case .status(let base) = state(scenario) else { continue }
            for forecast in forecasts {
                for notice in notices {
                    for reasonLine in [base.reasonLine, .rainForecast(percent: 80, minutes: 30)] {
                        var entry = base
                        entry.forecast = forecast
                        entry.weatherNotice = notice
                        entry.reasonLine = reasonLine
                        let face = Presentation(.status(entry), language: "zh-Hant")
                        let label = "\(scenario) forecast \(forecast != nil) notice \(String(describing: notice))"
                        if face.home != nil || face.work != nil || carriesPercentage(face.mediumLine) {
                            XCTAssertTrue(face.showsWeatherColumn, label)
                        }
                        if face.weatherColumnNotice != nil { XCTAssertTrue(face.showsWeatherColumn, label) }
                        XCTAssertFalse(carriesPercentage(face.line), "\(label): never outside the medium")
                    }
                }
            }
        }
    }

    /// D-C kept outside the medium (2026-10-02): a today entry's forecast and weather notices
    /// change nothing that small, StandBy, rectangular, circular or inline read. Every such
    /// field is what the same entry gives as build 38 stored it: no forecast, and no notice
    /// but "complete your route".
    func testTodayChangesNothingOutsideTheMedium() {
        let forecast = TomorrowWidgetSnapshot.RouteForecast(
            checkedAt: now, home: .init(condition: .rain, percent: 90), work: .init(condition: .rain, percent: 80), maximumPercent: 90)
        for scenario in todayScenarios {
            guard case .status(let sample) = state(scenario) else { return XCTFail("\(scenario) must be a status") }
            var variants = [sample]
            for notice in TomorrowWidgetSnapshot.WeatherNotice.allCases where notice != .routeNeeded {
                for withForecast in [false, true] {
                    var entry = sample
                    entry.weatherNotice = notice
                    entry.forecast = withForecast ? forecast : nil
                    variants.append(entry)
                }
            }
            for entry in variants {
                var stored = entry
                stored.forecast = nil
                stored.weatherNotice = entry.weatherNotice == .routeNeeded ? .routeNeeded : nil
                let shown = Presentation(.status(entry), language: "zh-Hant")
                let was = Presentation(.status(stored), language: "zh-Hant")
                let label = "\(scenario) notice \(String(describing: entry.weatherNotice)) forecast \(entry.forecast != nil)"
                XCTAssertEqual(shown.line, was.line, label)
                XCTAssertEqual(shown.showsWarningBadge, was.showsWarningBadge, label)
                XCTAssertEqual(shown.glyph, was.glyph, label)
                XCTAssertEqual(shown.accessoryGlyph, was.accessoryGlyph, label)
                XCTAssertEqual(shown.hero, was.hero, label)
                XCTAssertEqual(shown.decisionSky, was.decisionSky, label)
                XCTAssertEqual(shown.ringDay, was.ringDay, label)
                XCTAssertEqual(shown.skipLabelKey, was.skipLabelKey, label)
                XCTAssertEqual(shown.inlineSkippedText, was.inlineSkippedText, label)
                XCTAssertEqual(shown.hasIssue, was.hasIssue, label)
                XCTAssertEqual(shown.relevanceScore, was.relevanceScore, label)
                XCTAssertEqual(shown.day, was.day, label)
                XCTAssertEqual(shown.dayWordKey, was.dayWordKey, label)
                XCTAssertEqual(shown.closureSource, was.closureSource, label)
            }
        }
    }

    func testCircularSkipWordNamesAHolidayAndNeverAnUncreditedClosure() {
        XCTAssertEqual(presentation(.holidayNamed).skipLabelKey, "widget_skip_holiday")
        XCTAssertEqual(presentation(.holidayUnnamed).skipLabelKey, "widget_skip_holiday")
        // DAYOFF-SPEC §7: the circular face has no room for the closure's source.
        XCTAssertEqual(presentation(.closure).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.todayClosure).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.weekend).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.manualSkip).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.skippedOnce).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.alarmOff).skipLabelKey, "widget_skip_off")
        XCTAssertNil(presentation(.rainForecast).skipLabelKey, "A ring shows its time, not a word")
        XCTAssertNil(presentation(.routeIncomplete).skipLabelKey)
    }

    /// DAYOFF-SPEC §7 (merge review 2026-10-01): a face that reports a closure names its source
    /// and the source's own update time. Small, medium and rectangular print `closureSource`;
    /// the circular and inline faces cannot, so they show a plain skipped day: no storm cloud,
    /// no closure word.
    func testAClosureCarriesItsSourceAndTheAccessoryFacesDoNotNameIt() throws {
        for scenario in [Scenario.closure, .todayClosure] {
            guard case .status(let entry) = state(scenario) else { return XCTFail("\(scenario) must be a status") }
            let value = presentation(scenario)
            XCTAssertNotNil(entry.closureSourceUpdatedAt, "\(scenario): the sample names the source's time")
            XCTAssertEqual(value.closureSource, .init(updatedAt: entry.closureSourceUpdatedAt), "\(scenario)")
            XCTAssertEqual(value.glyph, .closure, "\(scenario): the faces that credit it keep the storm cloud")
            XCTAssertEqual(value.accessoryGlyph, .silent, "\(scenario)")
            XCTAssertEqual(value.inlineSkippedText?.key,
                           scenario == .closure ? "widget_inline_skipped" : "widget_inline_today_skipped", "\(scenario)")
        }
        for scenario in Scenario.allCases where scenario != .closure && scenario != .todayClosure {
            XCTAssertNil(presentation(scenario).closureSource, "\(scenario)")
            XCTAssertNotEqual(presentation(scenario).accessoryGlyph, .closure, "\(scenario)")
        }
        guard case .status(var untimed) = state(.closure) else { return XCTFail("closure sample must be a status") }
        untimed.closureSourceUpdatedAt = nil
        XCTAssertEqual(Presentation(.status(untimed), language: "zh-Hant").closureSource, .init(updatedAt: nil),
                       "Without a time from the feed the source is still named")
    }

    /// The inline face names the morning a skip is about, as the card does. The one-time
    /// skip's reason line (只關閉這一次，之後的鬧鐘照常響) names none (merge review 2026-10-01).
    func testInlineSkippedLinesNameTheirMorning() throws {
        XCTAssertEqual(presentation(.skippedOnce).inlineSkippedText, LocalizedLine(key: "widget_inline_skip_once"))
        guard case .status(var today) = state(.skippedOnce) else { return XCTFail("skippedOnce sample must be a status") }
        today.isToday = true
        XCTAssertEqual(Presentation(.status(today), language: "zh-Hant").inlineSkippedText,
                       LocalizedLine(key: "widget_inline_today_skip_once"))
        // Every other skipped reason already names its day in its own line.
        XCTAssertEqual(presentation(.weekend).inlineSkippedText, LocalizedLine(key: "ux_tomorrow_weekend"))
        XCTAssertEqual(presentation(.todaySkipped).inlineSkippedText, LocalizedLine(key: "widget_today_weekend"))
        XCTAssertEqual(presentation(.holidayNamed).inlineSkippedText,
                       LocalizedLine(key: "ux_tomorrow_holiday_named", arguments: [.string("國慶日")]))
        XCTAssertNil(presentation(.alarmOff).inlineSkippedText, "Off names no day")
        XCTAssertNil(presentation(.rainForecast).inlineSkippedText, "A ring shows its time")
    }

    /// The snapshot keeps DGPA's name; the widget names it in the language it renders in,
    /// so switching the device's language never shows the other language's name.
    func testStoredHolidayNameIsNamedInTheWidgetsLanguage() {
        func line(_ name: String, _ language: String) -> Presentation.Line? {
            guard case .status(var entry) = state(.holidayNamed) else { XCTFail("holiday sample must be a status"); return nil }
            entry.reasonLine = .holidayNamed(name)
            let value = Presentation(.status(entry), language: language)
            XCTAssertEqual(value.mediumLine, value.line, "\(name) \(language)")
            return value.line
        }
        for language in ["zh-Hant", "zh-Hant-TW"] {
            XCTAssertEqual(line("國慶日", language), .reason(.holidayNamed("國慶日")))
            XCTAssertEqual(line("補假", language), .reason(.holidayNamed("補假")))
        }
        XCTAssertEqual(line("國慶日", "en"), .reason(.holidayNamed("National Day")))
        XCTAssertEqual(line("小年夜", "en"), .reason(.holidayNamed("Lunar New Year break")))
        XCTAssertEqual(line("補假", "en"), .reason(.holiday), "A day off in lieu takes the unnamed line")
        XCTAssertEqual(line("原住民族日", "en"), .reason(.holiday), "Never a Chinese name in an English widget")
        XCTAssertEqual(line("Independence Day", "en"), .reason(.holidayNamed("Independence Day")))
        // A snapshot published before the stored name stayed raw still reads.
        XCTAssertEqual(line("National Day", "en"), .reason(.holidayNamed("National Day")))
        // Every other line is untouched by the language.
        for scenario in Scenario.allCases where scenario != .holidayNamed && scenario != .todayHolidayNamed {
            XCTAssertEqual(Presentation(state(scenario), language: "en"), presentation(scenario), "\(scenario)")
        }
    }

    func testClockPartsRejoinToClockTimeFormat() {
        let zone = calendar.timeZone
        let moments = [(0, 5), (7, 30), (12, 0), (23, 59)].map {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: $0.0, minute: $0.1))!
        }
        for identifier in ["zh-Hant", "zh-Hant-TW", "en", "en-US"] {
            let locale = Locale(identifier: identifier)
            let chinese = identifier.hasPrefix("zh")
            for format in ClockTimeFormat.allCases {
                for moment in moments {
                    let parts = format.parts(moment, locale: locale, timeZone: zone)
                    XCTAssertEqual(parts.joined, format.time(moment, locale: locale, timeZone: zone), "\(identifier) \(format) \(moment)")
                    if format == .twentyFourHour {
                        XCTAssertNil(parts.period)
                    } else {
                        XCTAssertEqual(parts.periodLeads, chinese)
                        XCTAssertTrue(chinese ? ["上午", "下午"].contains(parts.period) : ["AM", "PM"].contains(parts.period))
                    }
                }
            }
        }
        let morning = moments[1]
        XCTAssertEqual(ClockTimeFormat.twelveHour.parts(morning, locale: Locale(identifier: "zh-Hant"), timeZone: zone).joined, "上午 7:30")
        XCTAssertEqual(ClockTimeFormat.twelveHour.parts(morning, locale: Locale(identifier: "en"), timeZone: zone).joined, "7:30 AM")
        XCTAssertEqual(ClockTimeFormat.twentyFourHour.parts(moments[0], locale: Locale(identifier: "en"), timeZone: zone).clock, "00:05")
    }

    func testSamplesCoverEveryReasonAndState() throws {
        var reasons = Set<TomorrowWidgetSnapshot.Reason>()
        var notices = Set<TomorrowWidgetSnapshot.WeatherNotice>()
        var issues = Set<TomorrowWidgetSnapshot.ScheduleIssue>()
        var ringOnAnotherDay = false
        for scenario in Scenario.allCases {
            let snapshot = TomorrowWidgetSamples.snapshot(scenario, now: now, calendar: calendar)
            if scenario == .missing {
                XCTAssertNil(snapshot)
                continue
            }
            let value = try XCTUnwrap(snapshot, "\(scenario)")
            XCTAssertTrue(value.isValid, "\(scenario) must be a valid snapshot")
            for entry in value.entries {
                reasons.insert(entry.reason)
                if let notice = entry.weatherNotice { notices.insert(notice) }
                if let issue = entry.scheduleIssue { issues.insert(issue) }
                ringOnAnotherDay = ringOnAnotherDay || entry.ringIsOnAnotherDay
            }
        }
        XCTAssertEqual(reasons, Set(TomorrowWidgetSnapshot.Reason.allCases))
        XCTAssertTrue(notices.isSuperset(of: [.stale, .failed, .noForecast]))
        XCTAssertEqual(issues, Set(TomorrowWidgetSnapshot.ScheduleIssue.allCases))
        XCTAssertTrue(ringOnAnotherDay)
        XCTAssertEqual(state(.expired), .needsApp(.expired))
        XCTAssertEqual(state(.missing), .needsApp(.missing))
    }
}
