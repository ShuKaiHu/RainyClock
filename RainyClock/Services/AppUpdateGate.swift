import Combine
import Foundation

/// The running build's identity, as the App Store counts it.
enum AppBuildInfo {
    /// `CFBundleShortVersionString`, e.g. "1.8.2".
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// `CFBundleVersion`, e.g. "43": the number a server-side threshold compares against.
    static let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static let build = Int(buildString) ?? 0
}

/// Two layers of "this build is old". Both are decided here and shown by the main window
/// alone: nothing in them reaches AlarmKit, the ringing UI or the widgets, so a blocked
/// build's alarms still ring.
///
/// - Soft: the App Store's current version, looked up at most once a day as the app comes
///   to the foreground. Newer than the running one → `availableUpdate`, an update row on
///   the version card in Settings › Other (owner, 2026-10-15: no prompts on the home
///   screen). A failed lookup is silent and changes nothing.
/// - Hard: `minimumSupportedBuild`, which the membership service answers on its session and
///   status responses (`MembershipClient` hands every value here). The running build below
///   it → `requiresUpdate`, a full-screen view over the main UI. 0 blocks nothing, and a
///   later lower value lifts the block on the next response.
@MainActor
final class AppUpdateGate: ObservableObject {
    static let shared: AppUpdateGate = {
        #if DEBUG
        let gate = AppUpdateGate(lookup: DebugOverrides.lookup ?? AppStoreLookup.current,
                                 bypassesInterval: DebugOverrides.lookup != nil)
        if let build = DebugOverrides.minimumBuild { gate.record(minimumSupportedBuild: build) }
        return gate
        #else
        return AppUpdateGate()
        #endif
    }()

    struct StoreListing: Codable, Equatable, Sendable {
        var version: String
        var trackViewURL: URL?
    }

    /// The App Store's listing, when it is newer than the running version.
    @Published private(set) var availableUpdate: StoreListing?
    /// The running build is below the service's minimum.
    @Published private(set) var requiresUpdate = false

    /// The App Store page: the looked-up one when there is one, else the app's own id.
    var storeURL: URL { listing?.trackViewURL ?? Self.fallbackStoreURL }
    private(set) var minimumSupportedBuild = 0

    nonisolated static let lookupInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let fallbackStoreURL = URL(string: "https://apps.apple.com/app/id6780500386")!

    private enum Keys {
        static let listing = "appUpdateStoreListing"
        static let checkedAt = "appUpdateCheckedAt"
        static let minimumSupportedBuild = "appUpdateMinimumSupportedBuild"
    }

    private let defaults: UserDefaults
    private let currentVersion: String
    private let currentBuild: Int
    private let lookup: @Sendable () async throws -> StoreListing
    private let now: () -> Date
    private let bypassesInterval: Bool
    private var listing: StoreListing?
    private var isLookingUp = false

    init(defaults: UserDefaults = .standard, currentVersion: String = AppBuildInfo.version,
         currentBuild: Int = AppBuildInfo.build,
         lookup: @escaping @Sendable () async throws -> StoreListing = AppStoreLookup.current,
         now: @escaping () -> Date = Date.init, bypassesInterval: Bool = false) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.lookup = lookup
        self.now = now
        self.bypassesInterval = bypassesInterval
        listing = defaults.data(forKey: Keys.listing).flatMap { try? JSONDecoder().decode(StoreListing.self, from: $0) }
        minimumSupportedBuild = max(0, defaults.integer(forKey: Keys.minimumSupportedBuild))
        publish()
    }

    /// The App Store lookup, at most once a day; foreground activation calls it. The day
    /// counts from the attempt, not the answer: an unreachable store is not asked again on
    /// every activation, and the card keeps showing the last answer meanwhile.
    func checkAppStoreIfDue() async {
        guard !isLookingUp else { return }
        if !bypassesInterval, let checkedAt = defaults.object(forKey: Keys.checkedAt) as? Date,
           now().timeIntervalSince(checkedAt) < Self.lookupInterval { return }
        isLookingUp = true
        defer { isLookingUp = false }
        defaults.set(now(), forKey: Keys.checkedAt)
        guard let fresh = try? await lookup() else { return }
        listing = fresh
        if let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Keys.listing) }
        publish()
    }

    /// Every answer counts, 0 included: that is how the owner lifts a block.
    func record(minimumSupportedBuild value: Int) {
        guard value >= 0, value != minimumSupportedBuild else { return }
        minimumSupportedBuild = value
        defaults.set(value, forKey: Keys.minimumSupportedBuild)
        publish()
    }

    private func publish() {
        let update: StoreListing? = {
            guard let listing, Self.isVersion(listing.version, newerThan: currentVersion) else { return nil }
            return listing
        }()
        if update != availableUpdate { availableUpdate = update }
        // An unreadable own build (0) is unknown, not old: never block on it.
        let required = minimumSupportedBuild > 0 && currentBuild > 0 && currentBuild < minimumSupportedBuild
        if required != requiresUpdate { requiresUpdate = required }
    }

    /// Dotted numeric components, missing ones 0: 1.8.2 > 1.8.1, 1.9 > 1.8.2, 1.8.0 == 1.8.
    /// A non-numeric component counts as 0 rather than failing: a surprise from the store
    /// must never nag.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }

    #if DEBUG
    /// Simulator rehearsal: `-update-check-store-version 9.9.9` stands in for the App Store's
    /// answer (and skips the daily interval); `-update-check-minimum-build 999` for the
    /// service's, and `0` clears it again. Neither touches the network.
    private enum DebugOverrides {
        static var lookup: (@Sendable () async throws -> StoreListing)? {
            guard let version = value(after: "-update-check-store-version") else { return nil }
            return { StoreListing(version: version, trackViewURL: AppUpdateGate.fallbackStoreURL) }
        }
        static var minimumBuild: Int? { value(after: "-update-check-minimum-build").flatMap { Int($0) } }
        private static func value(after flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
    }
    #endif
}

/// `itunes.apple.com/lookup` for this bundle id on the Taiwan storefront, where the app is
/// sold; the version is the same on every storefront.
enum AppStoreLookup {
    @Sendable static func current() async throws -> AppUpdateGate.StoreListing {
        guard let bundleId = Bundle.main.bundleIdentifier,
              var components = URLComponents(string: "https://itunes.apple.com/lookup") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleId), URLQueryItem(name: "country", value: "tw")]
        guard let url = components.url else { throw URLError(.badURL) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try parse(data)
    }

    /// `results[0].version` and `trackViewUrl`; an empty `results` (unknown bundle id, or
    /// the listing not yet public) is a failure like any other.
    static func parse(_ data: Data) throws -> AppUpdateGate.StoreListing {
        struct Response: Decodable {
            struct Result: Decodable {
                var version: String
                var trackViewUrl: String?
            }
            var results: [Result]
        }
        guard let first = try JSONDecoder().decode(Response.self, from: data).results.first else {
            throw URLError(.resourceUnavailable)
        }
        return .init(version: first.version, trackViewURL: first.trackViewUrl.flatMap { URL(string: $0) })
    }
}
