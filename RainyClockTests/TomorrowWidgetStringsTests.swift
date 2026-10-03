import XCTest
@testable import RainyClock

/// The widget extension's own string table in one language, and a line resolved in it the
/// way the widget resolves it (`LocalizedLine.resolve`): arguments filled in that language,
/// a time as the app's 12/24-hour setting writes it, in `timeZone`.
struct WidgetStringTable {
    let language: String
    let strings: [String: String]

    init(_ language: String) throws {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("RainyClockAlarmWidget.appex")
        let url = appex.appendingPathComponent("\(language).lproj/Localizable.strings")
        strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "missing \(url.path)")
        self.language = language
    }

    /// A missing key reads as the key itself, as `Bundle.localizedString` returns it.
    func text(_ line: LocalizedLine, timeZone: TimeZone) -> String {
        line.filled(strings[line.key] ?? line.key, language: language, timeZone: timeZone)
    }
}

/// The widget extension carries its own string tables. Keys shared with the app must
/// say exactly what the app says; every key the widget resolves must exist.
final class TomorrowWidgetStringsTests: XCTestCase {
    private typealias Line = TomorrowWidgetPresentation.Line
    private let languages = ["en", "zh-Hant"]

    private func widgetTable(_ language: String) throws -> [String: String] {
        try WidgetStringTable(language).strings
    }

    private func appTable(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                subdirectory: nil, localization: language))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// Every line the widget can show, both lengths.
    private var everyLine: [Line] {
        var lines: [Line] = TomorrowWidgetSnapshot.ScheduleIssue.allCases.map { .issue($0) }
        lines += TomorrowWidgetSnapshot.WeatherNotice.allCases.map { .notice($0) }
        lines += TomorrowWidgetSnapshot.WeatherNotice.allCases.map { .todayNotice($0) }
        lines += [.ringsAsUsual]
        let reasons: [TomorrowWidgetSnapshot.ReasonLine] = [
            .rainForecast(percent: 80, minutes: 30), .rainEarlier(minutes: 30), .awaitingForecast, .holidayNamed("國慶日"), .holiday,
            .manualSkip, .manualRing, .weekend, .unselectedWeekday, .closure, .routeNeeded, .alarmOff, .skippedOnce]
        lines += reasons.map { .reason($0) }
        lines += reasons.map { .todayReason($0) }
        return lines
    }

    private func specifiers(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[@d]"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            .sorted()
    }

    func testSharedKeysMatchAppTablesExactly() throws {
        // 33 for the widget, plus the master switch's three (1.8.0), plus today's failed weather
        // in the medium's column (2026-10-02).
        XCTAssertEqual(TomorrowWidgetStrings.sharedAppKeys.count, 37)
        XCTAssertEqual(Set(TomorrowWidgetStrings.sharedAppKeys).count, TomorrowWidgetStrings.sharedAppKeys.count)
        for language in languages {
            let widget = try widgetTable(language)
            let app = try appTable(language)
            for key in TomorrowWidgetStrings.sharedAppKeys {
                let appValue = try XCTUnwrap(app[key], "\(language): the app has no \(key)")
                XCTAssertEqual(widget[key], appValue, "\(language): \(key) drifted from the app")
            }
        }
    }

    func testEveryKeyTheWidgetUsesExists() throws {
        var keys = Set(TomorrowWidgetStrings.widgetOnlyKeys + TomorrowWidgetStrings.sharedAppKeys)
        for line in everyLine {
            keys.insert(line.full.key)
            keys.insert(line.short.key)
        }
        // 44 for the widget, plus the master switch's circular word and two short lines (1.8.0),
        // plus the inline one-time skip (today, tomorrow) and the closure source credit and time,
        // plus today's "no forecast yet" and today's forecast time in the medium's column (2026-10-02).
        XCTAssertEqual(TomorrowWidgetStrings.widgetOnlyKeys.count, 53)
        XCTAssertTrue(TomorrowWidgetStrings.widgetOnlyKeys.contains("widget_forecast_as_of"))
        XCTAssertEqual(Set(TomorrowWidgetStrings.widgetOnlyKeys).count, TomorrowWidgetStrings.widgetOnlyKeys.count)
        for language in languages {
            let widget = try widgetTable(language)
            for key in keys.sorted() {
                let value = try XCTUnwrap(widget[key], "\(language): widget table lacks \(key)")
                XCTAssertNotEqual(value, key, "\(language): \(key) is untranslated")
                XCTAssertFalse(value.isEmpty, "\(language): \(key) is empty")
            }
        }
        XCTAssertEqual(Set(try widgetTable("en").keys), Set(try widgetTable("zh-Hant").keys), "Both tables carry the same keys")
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let english = try widgetTable("en")
        let chinese = try widgetTable("zh-Hant")
        for (key, value) in english {
            XCTAssertEqual(specifiers(value), specifiers(chinese[key] ?? ""), "\(key) arguments differ between en and zh-Hant")
        }
        // Resolving with the app's own argument types works in both tables.
        for line in everyLine {
            for localized in [line.full, line.short] {
                let count = localized.arguments.count
                for table in [english, chinese] {
                    XCTAssertEqual(specifiers(table[localized.key] ?? "").count, count, "\(localized.key) takes \(count) arguments")
                }
            }
        }
        XCTAssertEqual(specifiers(english["widget_inline_rain"] ?? ""), ["%1$@", "%2$d"])
        XCTAssertEqual(specifiers(english["widget_inline_ring_on"] ?? ""), ["%1$@", "%2$@"])
        XCTAssertEqual(specifiers(english["widget_inline_rain_on"] ?? ""), ["%1$@", "%2$@", "%3$d"])
        // A ring on another day is never called tomorrow.
        for key in ["widget_inline_ring_on", "widget_inline_rain_on"] {
            XCTAssertFalse(english[key]?.contains("Tomorrow") ?? true, key)
            XCTAssertFalse(chinese[key]?.contains("明天") ?? true, key)
        }
        // Today's lines (D-C) say today, never tomorrow, in both languages.
        for key in TomorrowWidgetStrings.widgetOnlyKeys where key.hasPrefix("widget_today") || key.hasPrefix("widget_inline_today") {
            XCTAssertTrue(english[key]?.contains("Today") ?? false || english[key]?.contains("today") ?? false, key)
            XCTAssertTrue(chinese[key]?.contains("今天") ?? false, key)
            XCTAssertFalse(english[key]?.localizedCaseInsensitiveContains("tomorrow") ?? true, key)
            XCTAssertFalse(chinese[key]?.contains("明天") ?? true, key)
        }
        XCTAssertEqual(specifiers(english["widget_inline_today_rain"] ?? ""), ["%1$@", "%2$d"])
        // The medium's weather column on a today entry (2026-10-02): every notice it can show,
        // both lengths, never says tomorrow; the two that name a day say today.
        for notice in TomorrowWidgetSnapshot.WeatherNotice.allCases {
            for localized in [Line.todayNotice(notice).full, Line.todayNotice(notice).short] {
                for (language, table) in [("en", english), ("zh-Hant", chinese)] {
                    let value = try XCTUnwrap(table[localized.key], "\(language): \(localized.key)")
                    XCTAssertFalse(value.localizedCaseInsensitiveContains("tomorrow"), "\(language): \(localized.key)")
                    XCTAssertFalse(value.contains("明天"), "\(language): \(localized.key)")
                }
            }
        }
        for key in ["ux_today_weather_failed", "widget_today_weather_unavailable"] {
            XCTAssertTrue(english[key]?.contains("Today") ?? false, key)
            XCTAssertTrue(chinese[key]?.contains("今天") ?? false, key)
        }
        XCTAssertEqual(chinese["widget_today_weather_unavailable"], "尚未取得今天天氣")
        XCTAssertEqual(english["widget_today_weather_unavailable"], "Today's forecast is not available yet")
        // Today's forecast past the widget's 3 hours (owner, 2026-10-02, approved wording): its time,
        // one argument, neutral. It names no day and says nothing needs updating.
        XCTAssertEqual(chinese["widget_forecast_as_of"], "預報時間 %@")
        XCTAssertEqual(english["widget_forecast_as_of"], "Forecast as of %@")
        for (table, words) in [(english, ["tomorrow", "update", "out of date", "needs"]), (chinese, ["明天", "更新", "需要"])] {
            let value = try XCTUnwrap(table["widget_forecast_as_of"])
            XCTAssertEqual(specifiers(value), ["%@"])
            for word in words { XCTAssertFalse(value.localizedCaseInsensitiveContains(word), "\(value): \(word)") }
        }
        // The inline one-time skip names its morning.
        XCTAssertTrue(english["widget_inline_skip_once"]?.contains("Tomorrow") ?? false)
        XCTAssertTrue(chinese["widget_inline_skip_once"]?.contains("明天") ?? false)
        // DAYOFF-SPEC §7: the closure credit names both roles (DGPA wrote it, NCDR published
        // it), and the time line is the SOURCE's update time, taking one date-and-time argument.
        XCTAssertTrue(chinese["widget_closure_source"]?.contains("人事") ?? false)
        XCTAssertTrue(english["widget_closure_source"]?.contains("DGPA") ?? false)
        for table in [english, chinese] {
            XCTAssertTrue(table["widget_closure_source"]?.contains("NCDR") ?? false)
            XCTAssertEqual(specifiers(table["widget_closure_source_updated"] ?? ""), ["%@"])
        }
        XCTAssertTrue(chinese["widget_closure_source_updated"]?.contains("來源") ?? false)
        XCTAssertTrue(english["widget_closure_source_updated"]?.contains("Source") ?? false)
        // D-A: the neutral line for a normal day names no weather.
        XCTAssertEqual(english["widget_rings_as_usual"], "Rings as usual")
        XCTAssertEqual(chinese["widget_rings_as_usual"], "照常響鈴")
        XCTAssertNil(english["widget_route_rain_chance"], "Route rain % left every family but the medium")
        // From midnight to the ring the widget shows today's alarm: its name and its first-run
        // face never promise tomorrow's.
        for key in ["widget_display_name", "widget_open_to_start"] {
            XCTAssertFalse(english[key]?.localizedCaseInsensitiveContains("tomorrow") ?? true, key)
            XCTAssertFalse(chinese[key]?.contains("明天") ?? true, key)
        }
        XCTAssertEqual(english["widget_display_name"], "Next Alarm")
        XCTAssertEqual(chinese["widget_display_name"], "下次鬧鐘")
        // Before the app has published anything there is nothing to refresh.
        for key in ["widget_inline_start", "widget_inline_start_short"] {
            XCTAssertFalse(english[key]?.localizedCaseInsensitiveContains("refresh") ?? true, key)
            XCTAssertFalse(chinese[key]?.contains("更新") ?? true, key)
        }
    }
}
