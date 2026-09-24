import Foundation

/// No advertising SDK traffic until a verified Apple transaction identifies the
/// production store. TestFlight uses Sandbox even with production App Attest.
enum MembershipAdvertisingGate {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var environment: MembershipAppleEnvironment?
    }
    private static let state = State()

    static var environment: MembershipAppleEnvironment? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.environment
    }

    static func setVerifiedEnvironment(_ environment: MembershipAppleEnvironment?) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.environment = environment
    }
}

enum AppEnvironment {
    /// Deferred from 1.7.0 to 1.8.0 (1.7.1 is reserved for other work). Keep saved preferences and implementation,
    /// but exclude the feature from this release's UI, scheduling and networking.
    static let supportsTemporaryClosures = false

    /// Public HTTPS service base URL. NCDR and APNs credentials remain on the server.
    static var dayOffServiceURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DayOffServiceURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// The LevelPlay banner unit — created in the Unity LevelPlay dashboard,
    /// and iOS-only: LevelPlay ad units are per-platform. There is no separate
    /// always-fill test unit id; development fill comes from the Test Suite
    /// (`-showLevelPlayTestSuite`) or a test device registered in the dashboard.
    static let levelPlayBannerAdUnitID = "kay9cneaxvesx4p4"

    /// The rewarded unit, exchanged one video for one voice generation. Its
    /// dashboard reward is deliberately `Generation ×1`, matching what the app
    /// grants — the reward promised in the ad has to be the reward delivered.
    ///
    /// Blanking this string turns the exchange off without removing the code,
    /// the same way a blank app key keeps the SDK from starting: the sheet then
    /// says the free allowance is spent rather than offering a trade it cannot
    /// honour.
    static let levelPlayRewardedAdUnitID = "nhprp5kcjqwwuoar"

    static var googlePlacesAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GooglePlacesAPIKey") as? String ?? ""
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The privacy flow is the same before membership verification and in
    /// TestFlight. XCTest uses injected permission clients instead of system UI.
    static var allowsAdvertisingConsent: Bool {
        !isRunningTests
    }

    /// Simulator and Apple Sandbox builds must not initialize production ads.
    /// This gate deliberately does not control whether ATT can be requested.
    static var allowsAdvertising: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        allowsDeviceAdvertising(isRunningTests: isRunningTests, arguments: ProcessInfo.processInfo.arguments)
        #endif
    }

    static func allowsDeviceAdvertising(isRunningTests: Bool, arguments: [String],
                                        sandboxBuild: Bool = MembershipConfiguration.isSandboxBuild,
                                        verifiedAppleEnvironment: MembershipAppleEnvironment? = MembershipAdvertisingGate.environment) -> Bool {
        #if DEBUG
        // Apply this even when its service URL is absent or invalid, before the
        // membership/reward identity flow could allow normal advertising again.
        if MembershipConfiguration.sandboxTesting(arguments: arguments, sandboxBuild: sandboxBuild) { return false }
        #endif
        return !isRunningTests && verifiedAppleEnvironment == .production
    }

    static var routeWeatherService: any RouteWeatherService {
        MapKitRouteWeatherService()
    }

    static var showsWeatherAttribution: Bool {
        true
    }
}
