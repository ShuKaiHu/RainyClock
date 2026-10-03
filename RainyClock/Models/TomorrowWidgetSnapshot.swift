import Foundation

/// What the widget may know: the Alarm page card's reading of calendar tomorrow,
/// precomputed at upcoming boundaries, and between local midnight and today's ring, today's
/// alarm (`Entry.isToday`; the card describes that morning too, until its normal time).
/// Never addresses, route text, segment names/ids, membership ids or raw error text.
///
/// Shared by the app (which writes it into the App Group) and the widget extension
/// (which only reads it), so this file stays Foundation-only: no `String(localized:)`,
/// no UIKit, no app types.
struct TomorrowWidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroupIdentifier = "group.com.shukaihu.RainyClock"   // same group as DayOffSharedState
    static let storageKey = "tomorrowWidgetSnapshot.v1"              // != DayOffSharedState.storageKey
    static let kind = "RainyClockTomorrow"                           // never rename after shipping
    /// The small widget's tap: the app shows its Alarm tab, where the weather card carries the
    ///  Weather mark and the legal link, whichever tab it was left on.
    static let alarmTabURL = URL(string: "rainyclock://alarm")!
    /// 2: `Entry.isToday` and `ReasonLine.awaitingForecast` (1.8.0 (38) widget decisions).
    /// 3: `Reason` / `ReasonLine` `.alarmOff` and `.skippedOnce` (the 1.8.0 master switch).
    /// 4: `Entry.closureSourceUpdatedAt`, so a closure names its source and the source's
    /// update time (DAYOFF-SPEC §7; 1.8.0 merge review).
    /// Still 4 in 1.8.0 (39), whose today entries carry their morning's forecast: the shape
    /// is unchanged. Build 38 stored a today entry with no forecast and no notice, except
    /// "complete your route" when an address was missing. Until the app next publishes, one
    /// without a notice draws no weather column, as in 38; one with "complete your route"
    /// draws the column (endpoints —, 請完成路線, the  Weather mark), exactly as 39 writes
    /// that same entry and as tomorrow's entries draw it, where 38 drew it full width.
    /// A snapshot of another version reads as "open the app" until the app republishes.
    static let currentVersion = 4
    static let maximumBytes = 64_000

    /// Raw values equal `CommuteAlarmSettings.CommuteMode`'s.
    enum CommuteMode: String, Codable, Sendable, CaseIterable { case car, scooter, walking, publicTransit }
    enum Reason: String, Codable, Sendable, CaseIterable {
        case normal, rain, holiday, manual, weekend, unselectedWeekday, disaster, routeIncomplete
        /// The master switch is off; `skippedOnce`: only this morning is off (1.8.0).
        case alarmOff, skippedOnce
    }
    /// Raw values equal `RouteWeatherSegment.Condition`'s.
    enum Condition: String, Codable, Sendable { case clear, cloudy, rain }
    /// The card's weatherNotice, in its priority order. `.noForecast` is the card's "loading".
    enum WeatherNotice: String, Codable, Sendable, CaseIterable { case failed, stale, routeNeeded, noForecast }
    /// The card's scheduleIssue, first match wins. `.schedulingFailed` never carries the
    /// message text (it can contain an address).
    enum ScheduleIssue: String, Codable, Sendable, CaseIterable {
        case schedulingFailed, alarmKitReschedule, closureUncertain, closureUpdateFailed, updateNeeded
    }
    /// The card's `reason` line, case for case.
    enum ReasonLine: Codable, Equatable, Sendable {
        case rainForecast(percent: Int, minutes: Int)   // ux_rain_applied_forecast
        case rainEarlier(minutes: Int)                  // ux_rain_applied
        /// The ring is still earlier, but only because the weekly repeat carried an earlier
        /// morning's rain lead here (`TomorrowAlarmStatus.rainLeadIsCarriedOver`).
        case awaitingForecast                           // ux_tomorrow_awaiting_forecast
        case holidayNamed(String)                       // ux_tomorrow_holiday_named
        case holiday, manualSkip, manualRing, weekend, unselectedWeekday, closure, routeNeeded
        /// The master switch is off until the user turns it back on.   // ux_alarm_off_message_only
        case alarmOff
        /// Only this morning is off; later mornings ring as usual.      // ux_skip_once_reason
        case skippedOnce
    }
    struct Endpoint: Codable, Equatable, Sendable {
        var condition: Condition
        var percent: Int
    }
    /// CommuteWeatherCard's view: home = segments.first; work = segments.last only when count >= 2.
    struct RouteForecast: Codable, Equatable, Sendable {
        var checkedAt: Date
        var home: Endpoint
        var work: Endpoint?
        var maximumPercent: Int                         // Int((maximumPrecipitationProbability * 100).rounded())
    }
    struct Entry: Codable, Equatable, Sendable {
        var validFrom: Date
        /// The alarm day has begun and its ring (or, when skipped, its normal time) is
        /// still ahead: the widget says 今天 / Today instead of 明天 / Tomorrow.
        var isToday: Bool
        var day: Date                                   // TomorrowAlarmStatus.day
        var normalAlarmDate: Date
        var expectedRingDate: Date?
        var ringIsOnAnotherDay: Bool                    // expected != nil && !calendar.isDate(expected, inSameDayAs: day)
        var reason: Reason
        var reasonLine: ReasonLine?
        var leadTimeMinutes: Int
        /// Present even when stale (the card shows it). A today entry carries its morning's
        /// forecast too since 1.8.0 (39); build 38 wrote nil there.
        var forecast: RouteForecast?
        var weatherNotice: WeatherNotice?
        var scheduleIssue: ScheduleIssue?
        /// A closure entry (`reason == .disaster`): the closure feed's own update time, which
        /// the widget prints beside the source credit (DAYOFF-SPEC §7), as the card does. nil
        /// for every other reason, and when the feed gave none (the credit still shows).
        var closureSourceUpdatedAt: Date? = nil

        /// A rain lead this day's own forecast decided, as opposed to one carried over.
        var appliesRainLead: Bool {
            reason == .rain && leadTimeMinutes > 0 && reasonLine != .awaitingForecast
        }

        func hasSameContent(as other: Entry) -> Bool {
            var copy = self
            copy.validFrom = other.validFrom
            return copy == other
        }
    }

    var version: Int
    var publishedAt: Date
    var timeZoneID: String
    var clockFormat: ClockTimeFormat
    var mode: CommuteMode
    var expiresAt: Date
    var entries: [Entry]

    /// version == currentVersion, entries non-empty, entries[0].validFrom == publishedAt,
    /// validFrom strictly ascending, expiresAt > entries.last!.validFrom.
    var isValid: Bool {
        guard version == Self.currentVersion, let first = entries.first, let last = entries.last,
              first.validFrom == publishedAt, expiresAt > last.validFrom else { return false }
        return zip(entries, entries.dropFirst()).allSatisfy { $0.validFrom < $1.validFrom }
    }

    /// Same version/timeZoneID/clockFormat/mode/expiresAt, and the same
    /// `TomorrowWidgetTimeline.plan(snapshot:now:currentTimeZoneID: timeZoneID).items` from `now`.
    /// A snapshot that merely carries more already-elapsed entries is still equivalent.
    func isEquivalent(to other: TomorrowWidgetSnapshot, at now: Date) -> Bool {
        guard version == other.version, timeZoneID == other.timeZoneID, clockFormat == other.clockFormat,
              mode == other.mode, expiresAt == other.expiresAt else { return false }
        let mine = TomorrowWidgetTimeline.plan(snapshot: self, now: now, currentTimeZoneID: timeZoneID).items
        let theirs = TomorrowWidgetTimeline.plan(snapshot: other, now: now, currentTimeZoneID: other.timeZoneID).items
        return mine == theirs
    }
}

/// The App Group slot the snapshot lives in. A value type: every call opens its own
/// `UserDefaults`, so nothing non-Sendable is held statically.
struct TomorrowWidgetStore: Sendable {
    var suiteName: String

    static let appGroup = TomorrowWidgetStore(suiteName: TomorrowWidgetSnapshot.appGroupIdentifier)

    private func defaults() -> UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// nil when missing, larger than maximumBytes, undecodable, or !isValid.
    func load() -> TomorrowWidgetSnapshot? {
        guard let data = defaults()?.data(forKey: TomorrowWidgetSnapshot.storageKey),
              data.count <= TomorrowWidgetSnapshot.maximumBytes,
              let snapshot = try? JSONDecoder().decode(TomorrowWidgetSnapshot.self, from: data),
              snapshot.isValid else { return nil }
        return snapshot
    }

    /// JSONEncoder (outputFormatting [.sortedKeys], default Date strategy). Refuses > maximumBytes.
    @discardableResult
    func save(_ snapshot: TomorrowWidgetSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let defaults = defaults(), let data = try? encoder.encode(snapshot),
              data.count <= TomorrowWidgetSnapshot.maximumBytes else { return false }
        defaults.set(data, forKey: TomorrowWidgetSnapshot.storageKey)
        return true
    }

    func clear() {
        defaults()?.removeObject(forKey: TomorrowWidgetSnapshot.storageKey)
    }
}

/// Turns a stored snapshot into timeline items. The single selection function, used
/// by the widget's TimelineProvider and by the app publisher's dedupe alike.
enum TomorrowWidgetTimeline {
    enum NeedsApp: String, Equatable, Sendable { case missing, outdated, timeZoneChanged, clockChanged, expired }
    enum State: Equatable, Sendable {
        case status(TomorrowWidgetSnapshot.Entry)
        case needsApp(NeedsApp)
    }
    struct Item: Equatable, Sendable {
        var date: Date
        var state: State
    }
    struct Plan: Equatable, Sendable {
        var items: [Item]
        var reloadAfter: Date
    }

    static let maximumReloadInterval: TimeInterval = 2 * 3_600
    static let idleReloadInterval: TimeInterval = 6 * 3_600
    static let clockSkewTolerance: TimeInterval = 5 * 60

    /// First match wins: missing, outdated, time zone changed, clock moved back,
    /// expired; otherwise the active entry re-stamped to `now`, every later entry at
    /// its own `validFrom`, and the expired face at `expiresAt`.
    static func plan(snapshot: TomorrowWidgetSnapshot?, now: Date, currentTimeZoneID: String) -> Plan {
        let idle = now.addingTimeInterval(idleReloadInterval)
        let soon = now.addingTimeInterval(maximumReloadInterval)
        guard let snapshot else {
            return Plan(items: [Item(date: now, state: .needsApp(.missing))], reloadAfter: idle)
        }
        guard snapshot.isValid else {
            return Plan(items: [Item(date: now, state: .needsApp(.outdated))], reloadAfter: idle)
        }
        guard snapshot.timeZoneID == currentTimeZoneID else {
            return Plan(items: [Item(date: now, state: .needsApp(.timeZoneChanged))], reloadAfter: soon)
        }
        guard now >= snapshot.publishedAt.addingTimeInterval(-clockSkewTolerance) else {
            return Plan(items: [Item(date: now, state: .needsApp(.clockChanged))], reloadAfter: soon)
        }
        guard now < snapshot.expiresAt else {
            return Plan(items: [Item(date: now, state: .needsApp(.expired))], reloadAfter: idle)
        }

        // Within the skew tolerance before publishedAt no entry has started yet;
        // the first one is still the best description of the moment.
        let activeIndex = snapshot.entries.lastIndex { $0.validFrom <= now } ?? 0
        var active = snapshot.entries[activeIndex]
        active.validFrom = now
        var items = [Item(date: now, state: .status(active))]
        for entry in snapshot.entries[(activeIndex + 1)...] where entry.validFrom > now && entry.validFrom < snapshot.expiresAt {
            items.append(Item(date: entry.validFrom, state: .status(entry)))
        }
        items.append(Item(date: snapshot.expiresAt, state: .needsApp(.expired)))
        return Plan(items: items, reloadAfter: min(snapshot.expiresAt, soon))
    }
}

/// Apple's combined " Weather" mark for the home-screen widgets, the faces that show
/// WeatherKit data (the medium's weather column, and the forecast's sky on both). The widget
/// cannot reach the network, so the app downloads the
/// mark from `WeatherService.shared.attribution` where it already talks to WeatherKit
/// (`WeatherAttributionMarkCache`) and leaves the PNG in the App Group container; the
/// widget draws it, or `fallbackText` until the first download lands.
///
/// Apple's requirement (developer.apple.com/weatherkit/get-started, "Apple Weather and
/// third-party attribution"): an app that displays weather data from Apple must clearly
/// display the Apple Weather trademark ( Weather) and the legal link to the other data
/// sources. The medium widget's weather column, and the small's mark where the system
/// honours a `Link` there, link (`legalLinkURL`) to the app, which opens
/// `WeatherAttribution.legalPageURL`.
struct WeatherAttributionMarkStore: Sendable {
    enum Variant: String, CaseIterable, Sendable {
        /// For light backgrounds (`combinedMarkLightURL`).
        case light
        /// For dark backgrounds (`combinedMarkDarkURL`): the full-colour widget's sky.
        case dark
    }

    /// The only variant the widget draws: white glyphs survive every rendering mode (full
    /// colour on the dark sky; accented and clear map luminance to alpha, which would erase
    /// the light variant's black glyphs). So the app fetches only this one.
    static let widgetVariant: Variant = .dark
    static let maximumBytes = 512_000
    /// The widget's link into the app, which then opens Apple's legal attribution page.
    static let legalLinkURL = URL(string: "rainyclock://weather-attribution")!
    /// U+F8FF is drawn as the Apple logo by Apple's system fonts.
    static let fallbackText = "\u{F8FF} Weather"
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// nil when the App Group container is unavailable (then every read is nil, every save false).
    var directory: URL?

    static var appGroup: WeatherAttributionMarkStore {
        WeatherAttributionMarkStore(directory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TomorrowWidgetSnapshot.appGroupIdentifier)?
            .appendingPathComponent("WeatherAttribution", isDirectory: true))
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count > pngSignature.count && data.starts(with: pngSignature)
    }

    func fileURL(for variant: Variant) -> URL? {
        directory?.appendingPathComponent("combined-mark-\(variant.rawValue).png")
    }

    /// The stored PNG, or nil when missing, oversized or not a PNG.
    func data(for variant: Variant) -> Data? {
        guard let url = fileURL(for: variant), let data = try? Data(contentsOf: url),
              data.count <= Self.maximumBytes, Self.isPNG(data) else { return nil }
        return data
    }

    /// When the mark was saved, kept in a sidecar rather than read from the file's
    /// modification date, which would be a required-reason API (file timestamps).
    private func stampURL(for variant: Variant) -> URL? {
        directory?.appendingPathComponent("combined-mark-\(variant.rawValue).saved")
    }

    /// Refuses anything that is not a PNG within `maximumBytes`; writes atomically.
    @discardableResult
    func save(_ data: Data, for variant: Variant, now: Date = Date()) -> Bool {
        guard data.count <= Self.maximumBytes, Self.isPNG(data), let directory, let url = fileURL(for: variant),
              let stamp = stampURL(for: variant) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try Data(String(now.timeIntervalSince1970).utf8).write(to: stamp, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func savedAt(_ variant: Variant) -> Date? {
        guard data(for: variant) != nil, let stamp = stampURL(for: variant),
              let text = try? String(contentsOf: stamp, encoding: .utf8),
              let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The widget's variant missing, or older than `maximumAge`.
    func needsRefresh(now: Date, maximumAge: TimeInterval) -> Bool {
        guard let savedAt = savedAt(Self.widgetVariant) else { return true }
        return now.timeIntervalSince(savedAt) > maximumAge
    }

    /// Deletes the stored marks (the DEBUG demo's text-fallback state).
    func clear() {
        for variant in Variant.allCases {
            for url in [fileURL(for: variant), stampURL(for: variant)].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
