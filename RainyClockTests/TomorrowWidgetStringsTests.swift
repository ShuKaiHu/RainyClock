import XCTest
@testable import RainyClock

/// The widget extension carries its own string tables. Keys shared with the app must
/// say exactly what the app says; every key the widget resolves must exist.
final class TomorrowWidgetStringsTests: XCTestCase {
    private typealias Line = TomorrowWidgetPresentation.Line
    private let languages = ["en", "zh-Hant"]

    private func widgetTable(_ language: String) throws -> [String: String] {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("RainyClockAlarmWidget.appex")
        let url = appex.appendingPathComponent("\(language).lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "missing \(url.path)")
        return table
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
        lines += [.routeRain(percent: 40)]
        let reasons: [TomorrowWidgetSnapshot.ReasonLine] = [
            .rainForecast(percent: 80, minutes: 30), .rainEarlier(minutes: 30), .holidayNamed("國慶日"), .holiday,
            .manualSkip, .manualRing, .weekend, .unselectedWeekday, .closure, .routeNeeded]
        lines += reasons.map { .reason($0) }
        return lines
    }

    private func specifiers(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[@d]"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            .sorted()
    }

    func testSharedKeysMatchAppTablesExactly() throws {
        XCTAssertEqual(TomorrowWidgetStrings.sharedAppKeys.count, 32)
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
        XCTAssertEqual(TomorrowWidgetStrings.widgetOnlyKeys.count, 30)
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
        // Before the app has published anything there is nothing to refresh.
        for key in ["widget_inline_start", "widget_inline_start_short"] {
            XCTAssertFalse(english[key]?.localizedCaseInsensitiveContains("refresh") ?? true, key)
            XCTAssertFalse(chinese[key]?.contains("更新") ?? true, key)
        }
    }
}
