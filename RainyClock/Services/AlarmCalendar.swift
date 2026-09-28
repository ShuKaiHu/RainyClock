import Foundation
import CoreFoundation

/// Keys describe the user's normal alarm day, even when rain moves the sound
/// into the previous evening. Never key an override by the adjusted ring date.
struct AlarmCalendarSettings: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case weekly, taiwan, unitedStates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weekly: String(localized: "calendar_source_weekly")
            case .taiwan: String(localized: "calendar_source_taiwan")
            case .unitedStates: String(localized: "calendar_source_us")
            }
        }
    }
    enum Override: String, Codable, Sendable { case ring, silent }
    var isEnabled: Bool
    var source: Source
    var overrides: [String: Override]
    var isActive: Bool { isEnabled && (source != .weekly || !overrides.isEmpty) }

    init(isEnabled: Bool = false, source: Source = .taiwan, overrides: [String: Override] = [:]) {
        self.isEnabled = isEnabled
        self.source = source
        self.overrides = overrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .weekly
        overrides = try values.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:]
        // Preserve the behavior of the initial 1.7 development build on upgrade.
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? (source != .weekly || !overrides.isEmpty)
    }

    /// Official CSV dates and persisted overrides always use Gregorian years,
    /// even when the phone's preferred calendar is Buddhist or Republic of China.
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = .current
        value.timeZone = .current
        value.firstWeekday = Calendar.current.firstWeekday
        return value
    }

    static func key(for date: Date, calendar: Calendar = AlarmCalendarSettings.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A manual "ring" for this day. It outranks a temporary closure: the alarm rings anyway.
    func forcesRing(on date: Date, calendar: Calendar = AlarmCalendarSettings.calendar) -> Bool {
        isEnabled && overrides[Self.key(for: date, calendar: calendar)] == .ring
    }

    func decision(on date: Date, weekdays: Set<Int>, holidays: HolidayCalendar, calendar: Calendar = AlarmCalendarSettings.calendar) -> DayDecision {
        let key = Self.key(for: date, calendar: calendar)
        if isEnabled, let override = overrides[key] {
            return DayDecision(rings: override == .ring, reason: .manual)
        }
        return baseDecision(on: date, weekdays: weekdays, holidays: holidays, calendar: calendar)
    }

    /// The edit marker describes a different outcome, not a history of taps.
    /// Re-evaluate against current holidays and weekdays without erasing stored intent.
    func hasEffectiveOverride(on date: Date, weekdays: Set<Int>, holidays: HolidayCalendar,
                              calendar: Calendar = AlarmCalendarSettings.calendar) -> Bool {
        guard isEnabled, let override = overrides[Self.key(for: date, calendar: calendar)] else { return false }
        return (override == .ring) != baseDecision(on: date, weekdays: weekdays, holidays: holidays, calendar: calendar).rings
    }

    mutating func toggleDay(on date: Date, weekdays: Set<Int>, holidays: HolidayCalendar,
                            calendar: Calendar = AlarmCalendarSettings.calendar) {
        guard isEnabled else { return }
        let nextRings = !decision(on: date, weekdays: weekdays, holidays: holidays, calendar: calendar).rings
        let baseRings = baseDecision(on: date, weekdays: weekdays, holidays: holidays, calendar: calendar).rings
        let key = Self.key(for: date, calendar: calendar)
        if nextRings == baseRings {
            // Returning to the base must also remove manual-ring priority over
            // disaster notices; leaving a redundant entry would change that behavior.
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = nextRings ? .ring : .silent
        }
    }

    private func baseDecision(on date: Date, weekdays: Set<Int>, holidays: HolidayCalendar, calendar: Calendar) -> DayDecision {
        guard isEnabled else {
            return DayDecision(rings: weekdays.contains(calendar.component(.weekday, from: date)), reason: .weekday)
        }
        guard weekdays.contains(calendar.component(.weekday, from: date)) else {
            return DayDecision(rings: false, reason: .weekday)
        }
        let holiday = holidays.day(on: date, source: source, calendar: calendar)
        if holiday?.isOff == true {
            return DayDecision(rings: false, reason: .holiday)
        }
        return DayDecision(rings: true, reason: source != .weekly && holiday == nil ? .unavailable : .weekday)
    }
}

struct DayDecision: Equatable {
    enum Reason { case manual, weekday, holiday, unavailable }
    var rings: Bool
    var reason: Reason
    var title: String { String(localized: rings ? "calendar_ring" : "calendar_silent") }
    var detail: String {
        switch reason {
        case .manual: String(localized: "calendar_reason_manual")
        case .weekday: String(localized: "calendar_reason_weekly")
        case .holiday: String(localized: "calendar_reason_holiday")
        case .unavailable: String(localized: "calendar_reason_unavailable")
        }
    }
}

struct HolidayCalendar: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable { var isOff: Bool; var name: String }
    var days: [String: Day] = [:]
    var fetchedAt: Date?
    static let cacheKey = "holidayCalendar.v1"

    /// The persisted/downloaded dictionary remains Taiwan-only. US rules are
    /// deterministic and available offline, so selecting one source cannot
    /// accidentally apply the other country's cached holidays.
    func day(on date: Date, source: AlarmCalendarSettings.Source,
             calendar: Calendar = AlarmCalendarSettings.calendar) -> Day? {
        switch source {
        case .weekly: nil
        case .taiwan: days[AlarmCalendarSettings.key(for: date, calendar: calendar)]
        case .unitedStates: UnitedStatesFederalHolidays.day(on: date, calendar: calendar)
        }
    }

    static func load(storage: UserDefaults = .standard) -> HolidayCalendar {
        var value = HolidayCalendar()
        for year in [2026, 2027] {
            if let url = Bundle.main.url(forResource: "holidays-\(year)", withExtension: "csv"),
               let bytes = try? Data(contentsOf: url),
               let parsed = try? parseCSV(bytes, year: year, encoding: "UTF-8") {
                value.days.merge(parsed) { _, bundled in bundled }
            }
        }
        if let bytes = storage.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(Self.self, from: bytes) {
            value.days.merge(cached.days) { _, cached in cached }
            value.fetchedAt = cached.fetchedAt
        }
        return value
    }

    enum InvalidData: Error { case format, year, encoding, response }

    /// CSV may be UTF-8+BOM or Big5. Reject incomplete years and duplicate dates;
    /// a 200 response containing HTML must never replace a working bundled year.
    static func parseCSV(_ data: Data, year: Int, encoding: String) throws -> [String: Day] {
        let textEncoding: String.Encoding
        switch encoding.uppercased().replacingOccurrences(of: "-", with: "") {
        case "UTF8": textEncoding = .utf8
        case "BIG5": textEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default: throw InvalidData.encoding
        }
        guard let decoded = String(data: data, encoding: textEncoding) else { throw InvalidData.encoding }
        let text = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
        let rows = try csvRows(text)
        guard rows.first == ["西元日期", "星期", "是否放假", "備註"] else { throw InvalidData.format }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        var result: [String: Day] = [:]
        for row in rows.dropFirst() where row != [""] {
            guard row.count == 4, row[0].count == 8, row[0].allSatisfy(\.isNumber),
                  Int(row[0].prefix(4)) == year, let month = Int(row[0].dropFirst(4).prefix(2)),
                  let day = Int(row[0].suffix(2)), ["0", "2"].contains(row[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { throw InvalidData.format }
            let key = AlarmCalendarSettings.key(for: date, calendar: calendar)
            guard result[key] == nil else { throw InvalidData.format }
            result[key] = Day(isOff: row[2] == "2", name: row[3])
        }
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let last = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        guard result.count == calendar.dateComponents([.day], from: first, to: last).day else { throw InvalidData.year }
        return result
    }

    private static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == ",", !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r\n" || c == "\r"), !quoted {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw InvalidData.format }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func fetch(years: [Int], session: URLSession = .shared) async throws -> HolidayCalendar {
        struct Dataset: Decodable { var result: Result
            struct Result: Decodable { var distribution: [Resource] }
            struct Resource: Decodable { var resourceDescription: String; var resourceDownloadUrl: String; var resourceCharacterEncoding: String }
        }
        func read(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            request.setValue("RainyClock/1.7 (holiday calendar; shukaihu.github.io/RainyClock)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 2_000_000 else { throw InvalidData.response }
            return bytes
        }
        let meta = try JSONDecoder().decode(Dataset.self, from: await read(URL(string: "https://data.gov.tw/api/v2/rest/dataset/14718")!))
        var result = HolidayCalendar()
        for year in years {
            let resources = meta.result.distribution.filter {
                $0.resourceDescription.hasPrefix("\(year - 1911)年") && !$0.resourceDescription.contains("Google")
            }.sorted { $0.resourceDescription > $1.resourceDescription }
            guard let resource = resources.first, let url = URL(string: resource.resourceDownloadUrl),
                  url.scheme == "https", url.host == "www.dgpa.gov.tw" else { continue }
            let parsed = try parseCSV(await read(url), year: year, encoding: resource.resourceCharacterEncoding)
            result.days.merge(parsed) { _, new in new }
        }
        guard !result.days.isEmpty else { throw InvalidData.response }
        result.fetchedAt = Date()
        return result
    }
}

/// Recurring federal holidays and standard Monday–Friday observance, following
/// OPM: https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/
/// The actual holiday is included too for users who select weekend alarm days.
/// This is not a state, school, employer or alternate-shift calendar; one-off
/// executive closures and DC-area Inauguration Day are intentionally excluded.
enum UnitedStatesFederalHolidays {
    /// Bound the rule calendar instead of implying historical/future completeness.
    static let supportedYears = 2000...2100

    static func day(on date: Date, calendar: Calendar) -> HolidayCalendar.Day? {
        guard supportedYears.contains(calendar.component(.year, from: date)) else { return nil }
        let key = AlarmCalendarSettings.key(for: date, calendar: calendar)
        return holidays[key] ?? .init(isOff: false, name: "")
    }

    /// Precompute once using civil dates; the caller's time zone selects the
    /// date key, not the instant when midnight occurs in Washington, DC.
    private static let holidays: [String: HolidayCalendar.Day] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var result: [String: HolidayCalendar.Day] = [:]

        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        func add(_ date: Date, _ name: String) {
            result[AlarmCalendarSettings.key(for: date, calendar: calendar)] = .init(isOff: true, name: name)
        }
        func fixed(_ year: Int, _ month: Int, _ day: Int, _ name: String) {
            let actual = date(year, month, day)
            add(actual, name)
            let weekday = calendar.component(.weekday, from: actual)
            let offset = weekday == 7 ? -1 : weekday == 1 ? 1 : 0
            if offset != 0, let observed = calendar.date(byAdding: .day, value: offset, to: actual) {
                add(observed, "\(name) (observed)")
            }
        }
        func nth(_ year: Int, _ month: Int, weekday: Int, occurrence: Int, _ name: String) {
            let first = date(year, month, 1)
            let day = 1 + (weekday - calendar.component(.weekday, from: first) + 7) % 7 + (occurrence - 1) * 7
            add(date(year, month, day), name)
        }

        // Include neighboring years: January 1 on Saturday is observed on
        // December 31 of the prior year (for example, 2027-12-31 for 2028).
        for year in (supportedYears.lowerBound - 1)...(supportedYears.upperBound + 1) {
            fixed(year, 1, 1, "New Year's Day")
            nth(year, 1, weekday: 2, occurrence: 3, "Birthday of Martin Luther King, Jr.")
            nth(year, 2, weekday: 2, occurrence: 3, "Washington's Birthday")
            let lastMayDay = date(year, 5, 31)
            let daysAfterMonday = (calendar.component(.weekday, from: lastMayDay) - 2 + 7) % 7
            add(date(year, 5, 31 - daysAfterMonday), "Memorial Day")
            // Enacted June 17, 2021; do not backfill the new holiday into older years.
            if year >= 2021 { fixed(year, 6, 19, "Juneteenth National Independence Day") }
            fixed(year, 7, 4, "Independence Day")
            nth(year, 9, weekday: 2, occurrence: 1, "Labor Day")
            nth(year, 10, weekday: 2, occurrence: 2, "Columbus Day")
            fixed(year, 11, 11, "Veterans Day")
            nth(year, 11, weekday: 5, occurrence: 4, "Thanksgiving Day")
            fixed(year, 12, 25, "Christmas Day")
        }
        return result
    }()
}

struct CalendarAlarmPlan: Codable, Equatable, Sendable {
    struct Occurrence: Codable, Equatable, Sendable {
        var normalDate: Date
        var ringDate: Date
        /// A fixed-date plan may mix an early next alarm with normal later days.
        /// Persist its resolved sound so snooze/re-registration keep the same clip.
        var soundSelection: AlarmSoundSelection? = nil

        func resolvedSound(fallback: AlarmSoundSelection) -> AlarmSoundSelection {
            soundSelection ?? fallback
        }
    }
    var occurrences: [Occurrence]
    /// A coverage boundary, including silent days, not the last ringing day.
    var coveredUntil: Date
    var timeZoneID: String = TimeZone.current.identifier

    mutating func applySounds(from settings: CommuteAlarmSettings) {
        for index in occurrences.indices {
            occurrences[index].soundSelection = settings.soundSelection(
                ringDate: occurrences[index].ringDate, normalDate: occurrences[index].normalDate)
        }
    }

    static func make(settings: CommuteAlarmSettings, holidays: HolidayCalendar, rain: Bool, now: Date = Date(), days: Int, calendar: Calendar = AlarmCalendarSettings.calendar) -> Self {
        let start = calendar.startOfDay(for: now)
        let time = calendar.dateComponents([.hour, .minute], from: settings.alarmTime)
        var occurrences: [Occurrence] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  settings.calendarSettings.decision(on: day, weekdays: settings.selectedWeekdays, holidays: holidays, calendar: calendar).rings,
                  let normal = calendar.date(bySettingHour: time.hour ?? 7, minute: time.minute ?? 30, second: 0, of: day) else { continue }
            let ring = calendar.date(byAdding: .minute, value: rain ? -settings.rainLeadTimeMinutes : 0, to: normal) ?? normal
            guard ring > now else { continue }
            occurrences.append(.init(normalDate: normal, ringDate: ring))
        }
        return Self(occurrences: occurrences, coveredUntil: calendar.date(byAdding: .day, value: days, to: start)!, timeZoneID: calendar.timeZone.identifier)
    }
}
