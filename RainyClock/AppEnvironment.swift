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
    /// Temporary work/school closures ship in 1.8.0 (deferred from 1.7.0). This only opens
    /// the UI, scheduling and networking; whether a saved rule takes effect is still decided
    /// by the membership entitlement (`MembershipSchedulingAccess.effectiveSettings`).
    static let supportsTemporaryClosures = true

    /// Public HTTPS service origin. NCDR and APNs credentials remain on the server.
    ///
    /// The choice follows how APNs is signed, not the membership sandbox rule. Every DEBUG
    /// build (the everyday `Debug` configuration, `RainyClock Membership Local`, the installed
    /// Debug Sandbox build) is signed with `aps-environment = development`, so its device
    /// token is an APNs sandbox token that the production stack (`APNS_PRODUCTION=true`)
    /// rejects with `BadDeviceToken` and never prunes. DEBUG therefore always uses the
    /// sandbox stack, and Release always uses production. XCTest never gets a URL, so no test
    /// can reach either service through a default client.
    static var dayOffServiceURL: URL? {
        guard !isRunningTests else { return nil }
        return resolvedDayOffServiceURL(
            productionValue: Bundle.main.object(forInfoDictionaryKey: "DayOffServiceURL") as? String,
            sandboxValue: Bundle.main.object(forInfoDictionaryKey: "DayOffSandboxServiceURL") as? String)
    }

    /// True for builds whose push token is an APNs development (sandbox) token.
    static var usesAPNsSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The sandbox origin for APNs-sandbox builds, the production origin otherwise. Both
    /// values must be a bare HTTPS origin; a missing or malformed sandbox value resolves to
    /// nil rather than falling through to production. If a production GET from a Debug build
    /// is ever wanted, add an explicit opt-in that also turns off push registration instead
    /// of making production the default.
    static func resolvedDayOffServiceURL(productionValue: String?, sandboxValue: String?,
                                         apnsSandbox: Bool = usesAPNsSandbox) -> URL? {
        MembershipConfiguration.validatedServiceURL(apnsSandbox ? sandboxValue : productionValue)
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
