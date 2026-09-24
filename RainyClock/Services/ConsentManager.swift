#if DEBUG
import AdSupport
#endif
import AppTrackingTransparency
import IronSource
import UIKit

/// Drives the app's ad consent and, behind it, Apple's App Tracking
/// Transparency prompt.
///
/// GDPR consent is collected by the app's own sheet (`AdConsentSheet`) and
/// handed to Unity LevelPlay through `LPMPrivacySettings.setGDPRConsent`.
/// Google's UMP used to own this job, but its forms live in the terminated
/// AdMob account's console, and LevelPlay bundles no consent UI of its own —
/// so the sheet is ours.
///
/// GDPR choice (where needed), completed sheet dismissal, then ATT. Production
/// advertising and its membership reward identity gate only SDK startup; they
/// must not hide the permission flow in TestFlight or during a membership outage.
@MainActor
final class ConsentManager: ObservableObject {
    static let shared = ConsentManager()

    /// Injectable boundaries let tests exercise permission/SDK ordering without
    /// displaying system alerts, reading IDFA, or making advertising requests.
    struct Dependencies {
        var allowsConsent: @MainActor () -> Bool
        var allowsAdvertising: @MainActor () -> Bool
        var requiresRewardIdentity: @MainActor () -> Bool
        var isGDPRRegion: @MainActor () -> Bool
        var canPresentConsentUI: @MainActor () -> Bool
        var trackingStatus: @MainActor () -> ATTrackingManager.AuthorizationStatus
        var requestTracking: @MainActor () async -> ATTrackingManager.AuthorizationStatus
        var setGDPRConsent: @MainActor (Bool) -> Void
        var initializeAds: @MainActor (String?, @escaping @MainActor (Error?) -> Void) -> Void
        var didInitializeAds: @MainActor () -> Void
    }

    /// Whether ads may be requested for this user: ATT is resolved, LevelPlay
    /// finished initialising, and a GDPR user has an answer on file. The banner stays
    /// out of the view hierarchy until this turns true, so no ad request can
    /// precede consent or race SDK startup.
    @Published private(set) var canRequestAds = false

    /// Whether the user must be offered a way back into the consent sheet.
    /// Only GDPR regions require the entry point, so it stays hidden elsewhere.
    @Published private(set) var showsPrivacyOptions = false

    /// Whether the user allowed tracking through the ATT prompt.
    @Published private(set) var isTrackingAuthorized = false

    /// Bumped whenever an answer that shapes the ad request changes. The banner
    /// view is configured once when it is built, so it has to be rebuilt to pick
    /// up a new answer — a late ATT grant, or a consent choice the user revised.
    @Published private(set) var adConfigurationRevision = 0

    /// Drives the consent sheet. Dismissing without choosing is allowed: the
    /// user simply stays ad-free for the session and is asked again next launch.
    @Published var isConsentSheetPresented = false {
        didSet {
            if isConsentSheetPresented {
                isAwaitingConsentSheetDismissal = true
                canRequestAds = false
            }
        }
    }

    /// User-defaults key for the stored GDPR answer; missing means "never
    /// answered", which keeps ads (and the SDK itself) off for GDPR users
    /// until the sheet is dealt with.
    private static let consentDefaultsKey = "gdprPersonalizedAdsConsent"

    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var hasStartedConsentFlow = false
    private var hasOfferedInitialConsentSheet = false
    private var isAwaitingConsentSheetDismissal = false
    private var isRequestingTracking = false
    private var trackingStatus: ATTrackingManager.AuthorizationStatus = .notDetermined
    private var hasStartedAdSdk = false
    private var isAdSdkReady = false
    private var isGDPRUser = false
    private var rewardUserID: String?
    private var initializedRewardUserID: String?

    private var hasResolvedTrackingDecision: Bool {
        switch trackingStatus {
        case .authorized, .denied, .restricted: true
        case .notDetermined: false
        @unknown default: false
        }
    }

    func invalidateMembershipRewardIdentity() {
        rewardUserID = nil
        canRequestAds = false
    }

    /// LevelPlay's signed callback covers the immutable initialization user ID.
    /// It does not authenticate arbitrary dynamic/custom callback parameters.
    func configureRewardIdentity(_ userID: String) -> Bool {
        if hasStartedAdSdk, initializedRewardUserID != userID {
            canRequestAds = false
            return false
        }
        rewardUserID = userID
        updateCanRequestAds()
        return true
    }

    var canRequestMembershipRewards: Bool {
        canRequestAds && (!dependencies.requiresRewardIdentity() ||
            (rewardUserID != nil && rewardUserID == initializedRewardUserID))
    }

    private convenience init() {
        self.init(defaults: .standard, dependencies: Self.liveDependencies)
    }

    init(defaults: UserDefaults, dependencies: Dependencies) {
        self.defaults = defaults
        self.dependencies = dependencies
    }

    /// Runs the consent flow and starts the ad SDK behind it. Safe to call on
    /// every activation and after membership identity becomes available. An
    /// unresolved ATT decision keeps the SDK off and retries on a later activation.
    func requestConsentThenStartAds() async {
        guard !Task.isCancelled, dependencies.allowsConsent(), !isRequestingTracking else { return }
        if !hasStartedConsentFlow {
            hasStartedConsentFlow = true
            isGDPRUser = dependencies.isGDPRRegion()
            showsPrivacyOptions = isGDPRUser
        }

        guard !isConsentSheetPresented, !isAwaitingConsentSheetDismissal else { return }

        if isGDPRUser, storedConsent == nil {
            // Swiping away without an answer leaves this launch ad-free; it
            // must not immediately reopen the sheet or proceed to ATT/SDK init.
            if !hasOfferedInitialConsentSheet, dependencies.canPresentConsentUI() {
                hasOfferedInitialConsentSheet = true
                isConsentSheetPresented = true
            }
            return
        }

        updateTrackingStatus(dependencies.trackingStatus())
        if trackingStatus == .notDetermined {
            guard dependencies.canPresentConsentUI() else { return }
            isRequestingTracking = true
            let status = await dependencies.requestTracking()
            isRequestingTracking = false
            updateTrackingStatus(status)
        }

        // Inactive apps, another pending permission, or a dismissed ATT sheet
        // can leave the status notDetermined. That is not a completed decision.
        guard !Task.isCancelled, hasResolvedTrackingDecision else { return }
        startAdSdk()
        updateCanRequestAds()
    }

    /// Reopens the consent sheet so the user can change their choice — the
    /// entry point behind the Alarm tab's "Ad privacy options" row.
    func presentPrivacyOptions() {
        guard dependencies.allowsConsent() else { return }
        isConsentSheetPresented = true
    }

    /// Records the sheet's answer. Both answers allow ads; the value only
    /// decides whether LevelPlay may personalise them.
    func recordConsent(personalized: Bool) {
        defaults.set(personalized, forKey: Self.consentDefaultsKey)
        // The banner configures its `LPMBannerAdView` once, so a revised answer
        // only reaches the request stream by rebuilding it under a new identity.
        adConfigurationRevision &+= 1
        isConsentSheetPresented = false
    }

    /// Called by SwiftUI's onDismiss, after the sheet animation has finished.
    /// Flipping the presentation binding alone is too early for the ATT alert.
    func consentSheetDidClose() async {
        guard !isConsentSheetPresented else { return }
        isAwaitingConsentSheetDismissal = false
        await requestConsentThenStartAds()
    }

    /// Starts Unity LevelPlay. There is no Google demand behind it: the AdMob
    /// account is terminated (appeal denied), so the Google SDK, its adapter
    /// and `GADApplicationIdentifier` are gone on purpose — do not bring them
    /// back. Unity's own demand fills through LevelPlay.
    private func startAdSdk() {
        guard dependencies.allowsAdvertising(), hasResolvedTrackingDecision,
              !isConsentSheetPresented, !isAwaitingConsentSheetDismissal,
              !isGDPRUser || storedConsent != nil,
              !dependencies.requiresRewardIdentity() || rewardUserID != nil else { return }

        // A stored answer reaches LevelPlay before `init`, per its ordering
        // guidance, so even the first request of the session carries it.
        if let storedConsent {
            dependencies.setGDPRConsent(storedConsent)
        }

        guard !hasStartedAdSdk else { return }
        hasStartedAdSdk = true
        initializedRewardUserID = rewardUserID
        dependencies.initializeAds(rewardUserID) { [weak self] error in
            self?.adSdkDidInitialize(error: error)
        }
    }

    private static func initializeLevelPlay(userID: String?, completion: @escaping @MainActor (Error?) -> Void) {

        let appKey = Bundle.main.object(forInfoDictionaryKey: "LevelPlayAppKey") as? String ?? ""
        guard !appKey.isEmpty, appKey != "YOUR-LEVELPLAY-APP-KEY" else {
            // Skipping instead of crashing inside the SDK: with the placeholder
            // key the app just runs ad-free, and this line says why.
            print("[RainyClock] LevelPlayAppKey is still the placeholder, so LevelPlay never initialises and no ads load.")
            completion(NSError(domain: "RainyClock.AdConfiguration", code: 1))
            return
        }

        #if DEBUG
        // IDFA is only inspected after a real authorization decision allows it.
        if ATTrackingManager.trackingAuthorizationStatus == .authorized {
            Self.logAdvertisingIdentifier()
        }
        // Launch with `-showLevelPlayTestSuite` to open LevelPlay's Test Suite
        // once init lands. The flag must be set before init to take effect.
        if ProcessInfo.processInfo.arguments.contains("-showLevelPlayTestSuite") {
            LevelPlay.setMetaDataWithKey("is_test_suite", value: "enable")
        }
        #endif

        let builder = LPMInitRequestBuilder(appKey: appKey)
        if let userID { _ = builder.withUserId(userID) }
        let initRequest = builder.build()
        LevelPlay.initWith(initRequest) { _, error in
            Task { @MainActor in
                completion(error)
            }
        }
    }

    private func adSdkDidInitialize(error: Error?) {
        if let error {
            // Unlatch so the next foreground activation retries — LevelPlay
            // recommends re-initialising after a failure, and a cold start with
            // no network must not cost ads for the whole launch.
            hasStartedAdSdk = false
            isAdSdkReady = false
            updateCanRequestAds()
            #if DEBUG
            print("[RainyClock] LevelPlay failed to initialise: \(error.localizedDescription)")
            #endif
            return
        }

        isAdSdkReady = true
        updateCanRequestAds()
        dependencies.didInitializeAds()
    }

    private func updateTrackingStatus(_ status: ATTrackingManager.AuthorizationStatus) {
        trackingStatus = status
        let authorized = status == .authorized
        if authorized != isTrackingAuthorized {
            isTrackingAuthorized = authorized
            adConfigurationRevision &+= 1
        }
        if !hasResolvedTrackingDecision { canRequestAds = false }
    }

    private func updateCanRequestAds() {
        // A GDPR user needs an answer on file — either answer — before the
        // first request; all users also need a resolved ATT status and ready SDK.
        let identityMatches = !dependencies.requiresRewardIdentity() ||
            (rewardUserID != nil && rewardUserID == initializedRewardUserID)
        let allowsAdRequests = dependencies.allowsAdvertising() && isAdSdkReady &&
            hasResolvedTrackingDecision && !isRequestingTracking &&
            !isConsentSheetPresented && !isAwaitingConsentSheetDismissal &&
            identityMatches && (!isGDPRUser || storedConsent != nil)

        guard allowsAdRequests != canRequestAds else {
            return
        }

        canRequestAds = allowsAdRequests
    }

    private var storedConsent: Bool? {
        defaults.object(forKey: Self.consentDefaultsKey) as? Bool
    }

    private static var liveDependencies: Dependencies {
        Dependencies(
            allowsConsent: { AppEnvironment.allowsAdvertisingConsent },
            allowsAdvertising: { AppEnvironment.allowsAdvertising },
            requiresRewardIdentity: { MembershipManager.shared.isConfigured },
            isGDPRRegion: { Self.isGDPRRegion() },
            canPresentConsentUI: {
                guard UIApplication.shared.applicationState == .active,
                      let root = UIApplication.shared.rainyClockRootViewController,
                      root.viewIfLoaded?.window != nil else { return false }
                return root.presentedViewController == nil
            },
            trackingStatus: { ATTrackingManager.trackingAuthorizationStatus },
            requestTracking: { await ATTrackingManager.requestTrackingAuthorization() },
            setGDPRConsent: { LPMPrivacySettings.setGDPRConsent($0) },
            initializeAds: { userID, completion in
                Self.initializeLevelPlay(userID: userID, completion: completion)
            },
            didInitializeAds: { Self.presentTestSuiteIfRequested() }
        )
    }

    private static func presentTestSuiteIfRequested() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-showLevelPlayTestSuite"),
           let viewController = UIApplication.shared.rainyClockRootViewController {
            LevelPlay.launchTestSuite(viewController)
        }
        #endif
    }

    /// LevelPlay's init reports nothing about the user's location (unlike the
    /// MAX handshake this replaced), so the device region decides. Erring
    /// toward asking: a false positive costs one extra sheet, a false negative
    /// serves ads without a legal basis.
    private static func isGDPRRegion() -> Bool {
        #if DEBUG
        // Launch with `-forceGDPRConsentGeography` to rehearse the regulated-
        // region flow from anywhere, stored answer permitting.
        if ProcessInfo.processInfo.arguments.contains("-forceGDPRConsentGeography") {
            return true
        }
        #endif

        return Self.gdprRegions.contains(Locale.current.region?.identifier ?? "")
    }

    #if DEBUG
    /// Prints the advertising identifier so it can be pasted into LevelPlay's
    /// Setup → Test devices, which is how a real device gets test ads instead
    /// of billable ones. Called only after ATT is authorized; SDK initialization
    /// remains subject to the production advertising and reward identity gates.
    private static func logAdvertisingIdentifier() {
        let identifier = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if identifier == "00000000-0000-0000-0000-000000000000" {
            print("[RainyClock] Advertising ID unavailable (all zeros) despite ATT authorization.")
        } else {
            print("[RainyClock] Advertising ID for LevelPlay → Setup → Test devices: \(identifier)")
        }
    }
    #endif

    /// EEA members plus the UK.
    private static let gdprRegions: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR",
        "GB", "GR", "HU", "IE", "IS", "IT", "LI", "LT", "LU", "LV", "MT", "NL",
        "NO", "PL", "PT", "RO", "SE", "SI", "SK",
    ]
}

extension UIApplication {
    var rainyClockRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}
