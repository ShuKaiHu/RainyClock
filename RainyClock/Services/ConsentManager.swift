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
/// LevelPlay reports nothing about the user's location, so the device region
/// decides who is a GDPR user — and that is known before any SDK call, which
/// buys a stricter ordering than the MAX setup this replaced: a GDPR user who
/// has never answered sees the sheet first, and the SDK does not initialise
/// (no traffic at all) until an answer exists. Either answer allows ads; the
/// answer only decides personalisation. Everyone else initialises immediately
/// and reaches `canRequestAds` when the SDK is ready.
///
/// ATT comes after the consent decision, preserving the UMP-era ordering, and
/// applies everywhere rather than only in regulated regions.
@MainActor
final class ConsentManager: ObservableObject {
    static let shared = ConsentManager()

    /// Whether ads may be requested for this user: LevelPlay finished
    /// initialising, and a GDPR user has an answer on file. The banner stays
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
    @Published var isConsentSheetPresented = false

    /// User-defaults key for the stored GDPR answer; missing means "never
    /// answered", which keeps ads (and the SDK itself) off for GDPR users
    /// until the sheet is dealt with.
    private static let consentDefaultsKey = "gdprPersonalizedAdsConsent"

    private var hasStartedConsentFlow = false
    private var hasStartedAdSdk = false
    private var isAdSdkReady = false
    private var isGDPRUser = false
    private var hasFinishedConsentFlow = false
    private var rewardUserID: String?
    private var initializedRewardUserID: String?

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
        canRequestAds && (!MembershipManager.shared.isConfigured ||
            (rewardUserID != nil && rewardUserID == initializedRewardUserID))
    }

    private init() {}

    /// Runs the consent flow and starts the ad SDK behind it. Safe to call on
    /// every activation — the work happens at most once per launch, and a
    /// failed SDK handshake unlatches it so the next foreground can retry.
    func requestConsentThenStartAds() {
        if MembershipManager.shared.isConfigured, rewardUserID == nil { return }
        guard AppEnvironment.allowsAdvertising, !hasStartedConsentFlow else {
            return
        }
        hasStartedConsentFlow = true

        #if DEBUG
        Self.logAdvertisingIdentifier()
        #endif

        isGDPRUser = Self.isGDPRRegion()
        showsPrivacyOptions = isGDPRUser

        if isGDPRUser, storedConsent == nil {
            // The SDK is deliberately not started yet: the answer must reach
            // `LPMPrivacySettings` *before* init, and an unanswered GDPR user
            // stays entirely traffic-free. The flow continues from
            // `consentSheetDidClose()`.
            isConsentSheetPresented = true
            return
        }

        Task {
            await finishConsentFlow()
        }
    }

    /// Reopens the consent sheet so the user can change their choice — the
    /// entry point behind the Alarm tab's "Ad privacy options" row.
    func presentPrivacyOptions() {
        isConsentSheetPresented = true
    }

    /// Records the sheet's answer. Both answers allow ads; the value only
    /// decides whether LevelPlay may personalise them.
    func recordConsent(personalized: Bool) {
        UserDefaults.standard.set(personalized, forKey: Self.consentDefaultsKey)
        LPMPrivacySettings.setGDPRConsent(personalized)
        // The banner configures its `LPMBannerAdView` once, so a revised answer
        // only reaches the request stream by rebuilding it under a new identity.
        adConfigurationRevision &+= 1
        isConsentSheetPresented = false
    }

    /// Runs when the consent sheet closes, answered or dismissed. An answer
    /// releases the SDK start; a dismissal leaves this launch ad-free.
    func consentSheetDidClose() {
        Task {
            await finishConsentFlow()
        }
    }

    /// Retries a tracking prompt that was skipped because the app was not active
    /// when the consent flow finished. A no-op in every other case.
    func requestTrackingAuthorizationIfDeferred() async {
        guard hasFinishedConsentFlow else {
            return
        }

        await requestTrackingAuthorizationIfNeeded()
    }

    /// Starts Unity LevelPlay. There is no Google demand behind it: the AdMob
    /// account is terminated (appeal denied), so the Google SDK, its adapter
    /// and `GADApplicationIdentifier` are gone on purpose — do not bring them
    /// back. Unity's own demand fills through LevelPlay.
    private func startAdSdk() {
        guard AppEnvironment.allowsAdvertising, !hasStartedAdSdk else {
            return
        }
        hasStartedAdSdk = true

        // A stored answer reaches LevelPlay before `init`, per its ordering
        // guidance, so even the first request of the session carries it.
        if let storedConsent {
            LPMPrivacySettings.setGDPRConsent(storedConsent)
        }

        let appKey = Bundle.main.object(forInfoDictionaryKey: "LevelPlayAppKey") as? String ?? ""
        guard !appKey.isEmpty, appKey != "YOUR-LEVELPLAY-APP-KEY" else {
            // Skipping instead of crashing inside the SDK: with the placeholder
            // key the app just runs ad-free, and this line says why.
            print("[RainyClock] LevelPlayAppKey is still the placeholder, so LevelPlay never initialises and no ads load.")
            return
        }

        #if DEBUG
        // Launch with `-showLevelPlayTestSuite` to open LevelPlay's Test Suite
        // once init lands. The flag must be set before init to take effect.
        if ProcessInfo.processInfo.arguments.contains("-showLevelPlayTestSuite") {
            LevelPlay.setMetaDataWithKey("is_test_suite", value: "enable")
        }
        #endif

        let builder = LPMInitRequestBuilder(appKey: appKey)
        if let rewardUserID { _ = builder.withUserId(rewardUserID) }
        initializedRewardUserID = rewardUserID
        let initRequest = builder.build()
        LevelPlay.initWith(initRequest) { [weak self] _, error in
            Task { @MainActor in
                self?.adSdkDidInitialize(error: error)
            }
        }
    }

    private func adSdkDidInitialize(error: Error?) {
        if let error {
            // Unlatch so the next foreground activation retries — LevelPlay
            // recommends re-initialising after a failure, and a cold start with
            // no network must not cost ads for the whole launch.
            hasStartedAdSdk = false
            hasStartedConsentFlow = false
            #if DEBUG
            print("[RainyClock] LevelPlay failed to initialise: \(error.localizedDescription)")
            #endif
            return
        }

        isAdSdkReady = true
        updateCanRequestAds()
        presentTestSuiteIfRequested()
    }

    /// Consent, then ATT, then the SDK — the order the AdMob build used and
    /// the one Apple's guidance implies. Starting the SDK first is not fatal,
    /// but the session's opening requests then go out without the advertising
    /// identifier even when the user would have allowed tracking.
    private func finishConsentFlow() async {
        guard AppEnvironment.allowsAdvertising else { return }
        hasFinishedConsentFlow = true
        await requestTrackingAuthorizationIfNeeded()

        // A GDPR user who closed the sheet without answering stays ad-free for
        // this launch and is asked again next time.
        if !isGDPRUser || storedConsent != nil {
            startAdSdk()
        }

        updateCanRequestAds()
    }

    /// Asks for tracking authorization, which Apple requires before any data may
    /// be used to track the user across apps — the ad SDK's device identifier
    /// included.
    ///
    /// The system denies a request made while the app is not active *without
    /// showing the prompt*, and the decision is then permanent, so a launch that
    /// has not reached the foreground defers to
    /// `requestTrackingAuthorizationIfDeferred()`.
    private func requestTrackingAuthorizationIfNeeded() async {
        guard AppEnvironment.allowsAdvertising else {
            return
        }

        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            isTrackingAuthorized = ATTrackingManager.trackingAuthorizationStatus == .authorized
            return
        }

        guard UIApplication.shared.applicationState == .active else {
            return
        }

        let authorized = await ATTrackingManager.requestTrackingAuthorization() == .authorized
        guard authorized != isTrackingAuthorized else {
            return
        }

        isTrackingAuthorized = authorized
        // A grant that arrives through the deferred path lands after the banner
        // was built; rebuilding it puts the new answer on the next request right
        // away instead of whenever the auto-refresh cycle next comes around.
        adConfigurationRevision &+= 1
    }

    private func updateCanRequestAds() {
        // A GDPR user needs an answer on file — either answer — before the
        // first request; everyone else only waits for the SDK itself.
        let identityMatches = !MembershipManager.shared.isConfigured ||
            (rewardUserID != nil && rewardUserID == initializedRewardUserID)
        let allowsAdRequests = AppEnvironment.allowsAdvertising && isAdSdkReady &&
            identityMatches && (!isGDPRUser || storedConsent != nil)

        guard allowsAdRequests != canRequestAds else {
            return
        }

        canRequestAds = allowsAdRequests
    }

    private var storedConsent: Bool? {
        UserDefaults.standard.object(forKey: Self.consentDefaultsKey) as? Bool
    }

    private func presentTestSuiteIfRequested() {
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
    /// of billable ones. The value is all zeros until ATT is granted, so the
    /// first launch of a fresh install prints zeros and the next one prints
    /// the real id.
    private static func logAdvertisingIdentifier() {
        let identifier = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if identifier == "00000000-0000-0000-0000-000000000000" {
            print("[RainyClock] Advertising ID unavailable (all zeros). Allow tracking when the prompt appears, then relaunch to read it.")
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
