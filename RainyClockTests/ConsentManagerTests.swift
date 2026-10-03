import AppTrackingTransparency
import XCTest
@testable import RainyClock

@MainActor
final class ConsentManagerTests: XCTestCase {
    func testTestFlightAndUnverifiedMembershipStillRequestATTWithoutProductionAds() async {
        for environment in [MembershipAppleEnvironment.sandbox, nil] {
            let f = fixture()
            f.allowsAds = AppEnvironment.allowsDeviceAdvertising(isRunningTests: false, arguments: [],
                sandboxBuild: false, verifiedAppleEnvironment: environment)
            f.requiresIdentity = true
            await f.manager.requestConsentThenStartAds()
            XCTAssertEqual(f.events, ["ATT"])
            XCTAssertTrue(f.manager.isTrackingAuthorized)
            XCTAssertFalse(f.manager.canRequestAds)
        }
    }

    func testMembershipIdentityOnlyDelaysSDKAndDoesNotRepeatATT() async {
        let f = fixture()
        f.requiresIdentity = true
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertTrue(f.manager.configureRewardIdentity("member-a"))
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init", "ready"])
        XCTAssertEqual(f.initializedIDs, ["member-a"])
        XCTAssertTrue(f.manager.canRequestMembershipRewards)
    }

    func testInactiveLaunchDefersBothPromptAndSDKUntilReady() async {
        let f = fixture()
        f.canPresent = false
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertFalse(f.manager.canRequestAds)
        f.canPresent = true
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init", "ready"])
    }

    func testNotDeterminedResponseKeepsSDKOffUntilNextAttemptHasADecision() async {
        let f = fixture()
        f.answer = .notDetermined
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertFalse(f.manager.canRequestAds)
        f.answer = .denied
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "ATT", "init", "ready"])
        XCTAssertFalse(f.manager.isTrackingAuthorized)
        XCTAssertTrue(f.manager.canRequestAds)
        XCTAssertEqual(f.statusAtInitialization, [.denied])
    }

    func testExistingDecisionsDoNotPromptAgainIncludingDeniedAndRestricted() async {
        for status in [ATTrackingManager.AuthorizationStatus.authorized, .denied, .restricted] {
            let f = fixture()
            f.status = status
            await f.manager.requestConsentThenStartAds()
            await f.manager.requestConsentThenStartAds()
            XCTAssertEqual(f.events, ["init", "ready"])
            XCTAssertEqual(f.manager.isTrackingAuthorized, status == .authorized)
            XCTAssertTrue(f.manager.canRequestAds)
            XCTAssertEqual(f.statusAtInitialization, [status])
        }
    }

    func testConcurrentActivationAndIdentityCallbacksCannotRaceThePrompt() async {
        let f = fixture()
        f.holdsATT = true
        let first = Task { await f.manager.requestConsentThenStartAds() }
        await f.waitForATT()
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertFalse(f.manager.canRequestAds)
        // Even a changed status property cannot start the SDK before the
        // original request completes and the flow checks its result.
        f.status = .authorized
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.manager.configureRewardIdentity("member-a"))
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT"])
        f.completeATT(.authorized)
        await first.value
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init", "ready"])
    }

    func testGDPRAnswerWaitsForActualSheetDismissalBeforeATTAndSDK() async {
        let f = fixture()
        f.isGDPR = true
        f.answer = .denied
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.manager.isConsentSheetPresented)
        XCTAssertTrue(f.events.isEmpty)
        f.manager.recordConsent(personalized: false)
        XCTAssertFalse(f.manager.isConsentSheetPresented)
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.events.isEmpty, "A false binding is not a completed sheet dismissal")
        await f.manager.consentSheetDidClose()
        XCTAssertEqual(f.events, ["ATT", "GDPR:false", "init", "ready"])
        XCTAssertTrue(f.manager.canRequestAds)
    }

    func testGDPRSwipeDismissalDoesNotStartATTOrSDKOrReopenOnActivation() async {
        let f = fixture()
        f.isGDPR = true
        await f.manager.requestConsentThenStartAds()
        f.manager.isConsentSheetPresented = false
        await f.manager.consentSheetDidClose()
        await f.manager.requestConsentThenStartAds()
        XCTAssertFalse(f.manager.isConsentSheetPresented)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertFalse(f.manager.canRequestAds)

        f.manager.presentPrivacyOptions()
        f.manager.recordConsent(personalized: true)
        await f.manager.consentSheetDidClose()
        XCTAssertEqual(f.events, ["ATT", "GDPR:true", "init", "ready"])
    }

    func testGDPRSheetWaitsForAnActivePresentingView() async {
        let f = fixture()
        f.isGDPR = true
        f.canPresent = false
        await f.manager.requestConsentThenStartAds()
        XCTAssertFalse(f.manager.isConsentSheetPresented)
        f.canPresent = true
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.manager.isConsentSheetPresented)
        XCTAssertTrue(f.events.isEmpty)
    }

    func testStoredGDPRChoiceIsAppliedAfterATTAndBeforeSDK() async {
        let f = fixture()
        f.isGDPR = true
        f.defaults.set(false, forKey: "gdprPersonalizedAdsConsent")
        await f.manager.requestConsentThenStartAds()
        XCTAssertFalse(f.manager.isConsentSheetPresented)
        XCTAssertEqual(f.events, ["ATT", "GDPR:false", "init", "ready"])
    }

    func testTestFlightDoesNotCallSDKPrivacyConfigurationEvenAfterGDPRAndATT() async {
        let f = fixture()
        f.allowsAds = false
        f.isGDPR = true
        await f.manager.requestConsentThenStartAds()
        f.manager.recordConsent(personalized: true)
        await f.manager.consentSheetDidClose()
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertFalse(f.manager.canRequestAds)
    }

    func testSDKFailureRetriesOnNextActivationWithoutAnotherPrompt() async {
        let f = fixture()
        f.sdkError = NSError(domain: "test", code: 1)
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init"])
        XCTAssertFalse(f.manager.canRequestAds)
        f.sdkError = nil
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init", "init", "ready"])
        XCTAssertTrue(f.manager.canRequestAds)
    }

    func testSDKCallbackAfterMembershipInvalidationCannotEnableAds() async {
        let f = fixture()
        f.requiresIdentity = true
        f.holdsSDK = true
        XCTAssertTrue(f.manager.configureRewardIdentity("member-a"))
        await f.manager.requestConsentThenStartAds()
        f.manager.invalidateMembershipRewardIdentity()
        f.completeSDK()
        XCTAssertFalse(f.manager.canRequestAds)
        XCTAssertFalse(f.manager.canRequestMembershipRewards)
        XCTAssertFalse(f.manager.configureRewardIdentity("member-b"))
        XCTAssertFalse(f.manager.canRequestAds)
    }

    func testChangingGDPRChoicePausesAdsUntilSheetDismissalWithoutReinitializingSDK() async {
        let f = fixture()
        f.isGDPR = true
        f.defaults.set(true, forKey: "gdprPersonalizedAdsConsent")
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.manager.canRequestAds)
        f.events = []
        f.manager.presentPrivacyOptions()
        XCTAssertFalse(f.manager.canRequestAds)
        f.manager.recordConsent(personalized: false)
        await f.manager.requestConsentThenStartAds()
        XCTAssertTrue(f.events.isEmpty)
        await f.manager.consentSheetDidClose()
        XCTAssertEqual(f.events, ["GDPR:false"])
        XCTAssertTrue(f.manager.canRequestAds)
    }

    func testRevokingTrackingInSettingsUpdatesStateWithoutReasking() async {
        let f = fixture()
        await f.manager.requestConsentThenStartAds()
        let revision = f.manager.adConfigurationRevision
        f.status = .denied
        await f.manager.requestConsentThenStartAds()
        XCTAssertFalse(f.manager.isTrackingAuthorized)
        XCTAssertGreaterThan(f.manager.adConfigurationRevision, revision)
        XCTAssertEqual(f.events, ["ATT", "init", "ready"])
    }

    func testResetTrackingToUndeterminedDisablesExistingAds() async {
        let f = fixture()
        await f.manager.requestConsentThenStartAds()
        f.status = .notDetermined
        f.answer = .notDetermined
        await f.manager.requestConsentThenStartAds()
        XCTAssertFalse(f.manager.canRequestAds)
        XCTAssertFalse(f.manager.isTrackingAuthorized)
        XCTAssertEqual(f.events, ["ATT", "init", "ready", "ATT"])
    }

    func testProductionGateIsCheckedAgainAfterAwaitingATT() async {
        let f = fixture()
        f.holdsATT = true
        let request = Task { await f.manager.requestConsentThenStartAds() }
        await f.waitForATT()
        f.allowsAds = false
        f.completeATT(.authorized)
        await request.value
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertFalse(f.manager.canRequestAds)
    }

    func testCancelledAttemptCannotInitializeSDKAfterPermissionReturns() async {
        let f = fixture()
        f.holdsATT = true
        let request = Task { await f.manager.requestConsentThenStartAds() }
        await f.waitForATT()
        request.cancel()
        f.completeATT(.authorized)
        await request.value
        XCTAssertEqual(f.events, ["ATT"])
        XCTAssertFalse(f.manager.canRequestAds)
        await f.manager.requestConsentThenStartAds()
        XCTAssertEqual(f.events, ["ATT", "init", "ready"])
    }

    /// The privacy policy (en and zh) promises the consent sheet in the EEA, the UK and
    /// Switzerland. Switzerland is in neither the EU nor the EEA, so nothing implies it.
    func testConsentRegionsAreTheEEAPlusTheUKAndSwitzerland() {
        let eu: Set<String> = [
            "AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "HU",
            "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PL", "PT", "RO", "SE", "SI", "SK",
        ]
        XCTAssertEqual(eu.count, 27)
        // EU territory with its own region code (adversarial review, 2026-10-01): the
        // outermost regions, Åland, and CLDR's Canary Islands and Ceuta & Melilla. A phone
        // set to Réunion reports "RE", not "FR"; the GDPR applies there all the same.
        let euTerritories: Set<String> = ["RE", "GP", "MQ", "GF", "YT", "MF", "AX", "IC", "EA"]
        XCTAssertEqual(ConsentManager.gdprRegions, eu.union(euTerritories).union(["IS", "LI", "NO", "GB", "CH"]))
        XCTAssertTrue(ConsentManager.gdprRegions.isDisjoint(with: ["TW", "US", "JP"]))
    }

    func testDisabledConsentEnvironmentNeverCallsPermissionOrSDK() async {
        let f = fixture()
        f.allowsConsent = false
        await f.manager.requestConsentThenStartAds()
        f.manager.presentPrivacyOptions()
        XCTAssertFalse(f.manager.isConsentSheetPresented)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertFalse(f.manager.canRequestAds)
    }

    private func fixture() -> ConsentFixture {
        let suiteName = "ConsentManagerTests.\(UUID().uuidString)"
        let f = ConsentFixture(defaults: UserDefaults(suiteName: suiteName)!)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return f
    }
}

@MainActor
private final class ConsentFixture {
    let defaults: UserDefaults
    var allowsConsent = true
    var allowsAds = true
    var requiresIdentity = false
    var isGDPR = false
    var canPresent = true
    var status: ATTrackingManager.AuthorizationStatus = .notDetermined
    var answer: ATTrackingManager.AuthorizationStatus = .authorized
    var events: [String] = []
    var initializedIDs: [String?] = []
    var statusAtInitialization: [ATTrackingManager.AuthorizationStatus] = []
    var sdkError: Error?
    var holdsATT = false
    var holdsSDK = false
    private var attContinuation: CheckedContinuation<ATTrackingManager.AuthorizationStatus, Never>?
    private var attStarted: CheckedContinuation<Void, Never>?
    private var sdkCompletion: (@MainActor (Error?) -> Void)?

    init(defaults: UserDefaults) { self.defaults = defaults }

    lazy var manager = ConsentManager(defaults: defaults, dependencies: .init(
        allowsConsent: { [unowned self] in allowsConsent },
        allowsAdvertising: { [unowned self] in allowsAds },
        requiresRewardIdentity: { [unowned self] in requiresIdentity },
        isGDPRRegion: { [unowned self] in isGDPR },
        canPresentConsentUI: { [unowned self] in canPresent },
        trackingStatus: { [unowned self] in status },
        requestTracking: { [unowned self] in
            events.append("ATT")
            if holdsATT {
                return await withCheckedContinuation { continuation in
                    attContinuation = continuation
                    attStarted?.resume()
                    attStarted = nil
                }
            }
            status = answer
            return answer
        },
        setGDPRConsent: { [unowned self] consent in events.append("GDPR:\(consent)") },
        initializeAds: { [unowned self] userID, completion in
            events.append("init")
            initializedIDs.append(userID)
            statusAtInitialization.append(status)
            if holdsSDK { sdkCompletion = completion }
            else { completion(sdkError) }
        },
        didInitializeAds: { [unowned self] in events.append("ready") }
    ))

    func waitForATT() async {
        if attContinuation != nil { return }
        await withCheckedContinuation { attStarted = $0 }
    }

    func completeATT(_ result: ATTrackingManager.AuthorizationStatus) {
        status = result
        attContinuation?.resume(returning: result)
        attContinuation = nil
    }

    func completeSDK() {
        sdkCompletion?(sdkError)
        sdkCompletion = nil
    }
}
