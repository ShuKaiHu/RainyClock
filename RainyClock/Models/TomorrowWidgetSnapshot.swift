import Foundation

/// What the widget may know: the tomorrow card, precomputed at upcoming boundaries.
/// Never addresses, route text, segment names/ids, membership ids or raw error text.
///
/// Shared by the app (which writes it into the App Group) and the widget extension
/// (which only reads it), so this file stays Foundation-only: no `String(localized:)`,
/// no UIKit, no app types.
struct TomorrowWidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroupIdentifier = "group.com.shukaihu.RainyClock"   // same group as DayOffSharedState
    static let storageKey = "tomorrowWidgetSnapshot.v1"              // != DayOffSharedState.storageKey
    static let kind = "RainyClockTomorrow"                           // never rename after shipping
    static let currentVersion = 1
    static let maximumBytes = 64_000

    /// Raw values equal `CommuteAlarmSettings.CommuteMode`'s.
    enum CommuteMode: String, Codable, Sendable, CaseIterable { case car, scooter, walking, publicTransit }
    enum Reason: String, Codable, Sendable, CaseIterable {
        case normal, rain, holiday, manual, weekend, unselectedWeekday, disaster, routeIncomplete
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
        case holidayNamed(String)                       // ux_tomorrow_holiday_named
        case holiday, manualSkip, manualRing, weekend, unselectedWeekday, closure, routeNeeded
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
        var day: Date                                   // TomorrowAlarmStatus.day
        var normalAlarmDate: Date
        var expectedRingDate: Date?
        var ringIsOnAnotherDay: Bool                    // expected != nil && !calendar.isDate(expected, inSameDayAs: day)
        var reason: Reason
        var reasonLine: ReasonLine?
        var leadTimeMinutes: Int
        var forecast: RouteForecast?                    // present even when stale (the card shows it)
        var weatherNotice: WeatherNotice?
        var scheduleIssue: ScheduleIssue?

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
