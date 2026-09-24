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
        case .openApp(let reason): "openApp.\(reason.rawValue)"
        }
    }

    func testGlyphHeroAndLinePerScenario() {
        let table: [Scenario: (Presentation.Glyph, String, Presentation.Line?)] = [
            .normalClear: (.alarm, "time", .routeRain(percent: 10)),
            .cloudyNormal: (.alarm, "time", .routeRain(percent: 30)),
            .rainForecast: (.rain, "time+original", .reason(.rainForecast(percent: 80, minutes: 30))),
            .rainMixed: (.rain, "time+original", .reason(.rainForecast(percent: 80, minutes: 30))),
            .rainStale: (.rain, "time+original", .reason(.rainEarlier(minutes: 30))),
            .holidayNamed: (.silent, "skipped", .reason(.holidayNamed("國慶日"))),
            .holidayUnnamed: (.silent, "skipped", .reason(.holiday)),
            .weekend: (.silent, "skipped", .reason(.weekend)),
            .unselectedWeekday: (.silent, "skipped", .reason(.unselectedWeekday)),
            .manualSkip: (.silent, "skipped", .reason(.manualSkip)),
            .manualRing: (.manualRing, "time", .reason(.manualRing)),
            .closure: (.closure, "skipped", .reason(.closure)),
            .routeIncomplete: (.route, "notSet", .reason(.routeNeeded)),
            .weatherFailed: (.alarm, "time", .notice(.failed)),
            .forecastUnavailable: (.alarm, "time", .notice(.noForecast)),
            .scheduleUpdateNeeded: (.alarm, "time", .issue(.updateNeeded)),
            .schedulingFailed: (.alarm, "time", .issue(.schedulingFailed)),
            .alarmKitReschedule: (.rain, "time+original", .issue(.alarmKitReschedule)),
            .closureUncertain: (.alarm, "time", .issue(.closureUncertain)),
            .closureUpdateFailed: (.alarm, "time", .issue(.closureUpdateFailed)),
            .ringPreviousDay: (.rain, "time+original", .reason(.rainForecast(percent: 70, minutes: 30))),
            // D-D: the registered early time, but neither the rain glyph nor 因雨提早.
            .carriedOver: (.alarm, "time+original", .reason(.awaitingForecast)),
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
        XCTAssertEqual(presentation(.rainMixed).home, .clear)
        XCTAssertEqual(presentation(.rainMixed).work, .rain)
        XCTAssertEqual(presentation(.rainForecast).standByConditionSymbol, "cloud.rain.fill")
        XCTAssertEqual(presentation(.normalClear).standByConditionSymbol, "sun.max.fill")
        XCTAssertNil(presentation(.routeIncomplete).standByConditionSymbol)

        XCTAssertEqual(presentation(.rainForecast).relevanceScore, 50)
        XCTAssertEqual(presentation(.scheduleUpdateNeeded).relevanceScore, 50)
        XCTAssertEqual(presentation(.normalClear).relevanceScore, 10)
        XCTAssertEqual(presentation(.carriedOver).relevanceScore, 10, "A carried-over lead is not a rain day")
        XCTAssertEqual(presentation(.weekend).relevanceScore, 5)
        XCTAssertEqual(presentation(.routeIncomplete).relevanceScore, 5)
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

        XCTAssertTrue(Presentation.Line.issue(.updateNeeded).isWarning)
        XCTAssertTrue(Presentation.Line.notice(.stale).isWarning)
        XCTAssertFalse(Presentation.Line.notice(.routeNeeded).isWarning)
        XCTAssertEqual(Presentation.Line.notice(.failed).leadingSymbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(Presentation.Line.routeRain(percent: 10).leadingSymbol, "drop.fill")
        XCTAssertNil(Presentation.Line.reason(.weekend).leadingSymbol)
    }

    func testMediumLineNeverRepeatsTheWeatherColumn() {
        // The weather column prints the notice; the left footer falls through to the next
        // priority, and with a notice present there is none (route rain needs fresh weather).
        for scenario in Scenario.allCases {
            let value = presentation(scenario)
            guard case .status(let entry) = state(scenario) else {
                XCTAssertNil(value.mediumLine, "\(scenario)")
                continue
            }
            if let notice = entry.weatherNotice {
                XCTAssertNotEqual(value.mediumLine?.full, Presentation.Line.notice(notice).full, "\(scenario) says it twice")
            } else {
                XCTAssertEqual(value.mediumLine, value.line, "\(scenario)")
            }
        }
        XCTAssertEqual(presentation(.rainStale).line, .reason(.rainEarlier(minutes: 30)))
        XCTAssertEqual(presentation(.rainStale).mediumLine, .reason(.rainEarlier(minutes: 30)))
        XCTAssertEqual(presentation(.weatherFailed).line, .notice(.failed))
        XCTAssertNil(presentation(.weatherFailed).mediumLine)
        XCTAssertNil(presentation(.forecastUnavailable).mediumLine)
        XCTAssertEqual(presentation(.routeIncomplete).line, .reason(.routeNeeded))
        XCTAssertNil(presentation(.routeIncomplete).mediumLine, "請完成路線 is already the column's notice")
        XCTAssertEqual(presentation(.normalClear).mediumLine, .routeRain(percent: 10))

        guard case .status(var entry) = state(.normalClear) else { return XCTFail("normalClear must be a status") }
        entry.weatherNotice = .stale
        XCTAssertNil(Presentation(.status(entry)).mediumLine, "Stale weather alone: only the column says so")
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
                } else {
                    XCTAssertEqual(value.ringDay, .tomorrow(day), "\(scenario)")
                    XCTAssertTrue(calendar.isDate(ring, inSameDayAs: day), "\(scenario)")
                }
            default:
                XCTAssertNil(value.ringDay, "\(scenario)")
            }
        }
    }

    func testCircularSkipWordNamesHolidayAndClosureApart() {
        XCTAssertEqual(presentation(.holidayNamed).skipLabelKey, "widget_skip_holiday")
        XCTAssertEqual(presentation(.holidayUnnamed).skipLabelKey, "widget_skip_holiday")
        XCTAssertEqual(presentation(.closure).skipLabelKey, "widget_skip_closure")
        XCTAssertEqual(presentation(.weekend).skipLabelKey, "widget_skip_other")
        XCTAssertEqual(presentation(.manualSkip).skipLabelKey, "widget_skip_other")
        XCTAssertNil(presentation(.rainForecast).skipLabelKey, "A ring shows its time, not a word")
        XCTAssertNil(presentation(.routeIncomplete).skipLabelKey)
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
        for scenario in Scenario.allCases where scenario != .holidayNamed {
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
