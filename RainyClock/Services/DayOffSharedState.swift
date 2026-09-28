import Foundation

/// The little the notification service extension needs in order to say whether a
/// 停班停課 push concerns this phone — with the app closed, and without the server
/// ever learning where anyone lives. The app writes it whenever settings or the
/// next alarm change; the extension only reads. No address, route, push token or
/// credential is kept here, only the confirmed 縣市/區 pairs the user already
/// picked in Settings.
struct DayOffSharedState: Codable, Equatable, Sendable {
    static let appGroupIdentifier = "group.com.shukaihu.RainyClock"
    static let storageKey = "dayOffSharedState.v1"

    var enabled: Bool
    var observesWork: Bool
    var observesSchool: Bool
    var home: DisasterRegion?
    var destination: DisasterRegion?
    /// The next alarm's normal ring date — the date an announcement has to match.
    /// A rain-advanced ring can cross midnight; the normal date cannot.
    var normalAlarmDate: Date?
    var serviceURL: URL?
    var updatedAt: Date
    /// The next few normal ring dates the app scheduled (earliest first), *including*
    /// dates it has already skipped for a closure. A repeat announcement usually arrives
    /// after the skip, when `normalAlarmDate` has already moved on to the following
    /// ringing day. Absent in state written before 1.8.0 (38); the extension then falls
    /// back to `normalAlarmDate` alone.
    var upcomingNormalAlarmDates: [Date]? = nil
    /// The normal dates among those that the app already skipped for a closure
    /// (committed `AppliedDisasterSkip`s). Absent in older state.
    var skippedNormalAlarmDates: [Date]? = nil

    /// How many upcoming dates the app mirrors. Announcements target today or tomorrow;
    /// a week covers any skip plus the next ringing day with room to spare.
    static let upcomingDateLimit = 7

    /// The dates an announcement is checked against, earliest first, still in the future.
    func candidateAlarmDates(after now: Date) -> [Date] {
        let dates = upcomingNormalAlarmDates ?? normalAlarmDate.map { [$0] } ?? []
        return Array(Set(dates.filter { $0 > now })).sorted()
    }

    func isAlreadySkipped(_ date: Date) -> Bool {
        (skippedNormalAlarmDates ?? []).contains { abs($0.timeIntervalSince(date)) < 60 }
    }

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func load(from defaults: UserDefaults? = sharedDefaults()) -> DayOffSharedState? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(DayOffSharedState.self, from: data)
    }

    func save(to defaults: UserDefaults? = sharedDefaults()) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(from defaults: UserDefaults? = sharedDefaults()) {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// When the last day-off push reached this phone. The notification service
/// extension writes it; the app reads it. It is kept apart from
/// `DayOffSharedState`, which only the app writes, so the two never race.
///
/// The alert push does not wake the app, and its text tells the user to open the
/// app to confirm. So an open that follows a push must fetch the announcements
/// even inside the app's usual five-minute refresh throttle — otherwise a user
/// who looked at the app shortly before the announcement sees the old state.
enum DayOffPushMarker {
    static let storageKey = "dayOffPushReceivedAt.v1"

    static func record(_ date: Date = Date(), to defaults: UserDefaults? = DayOffSharedState.sharedDefaults()) {
        defaults?.set(date, forKey: storageKey)
    }

    static func lastReceivedAt(from defaults: UserDefaults? = DayOffSharedState.sharedDefaults()) -> Date? {
        defaults?.object(forKey: storageKey) as? Date
    }
}
