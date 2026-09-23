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
