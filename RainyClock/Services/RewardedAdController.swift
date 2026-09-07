import Foundation
import OSLog
import SwiftUI
import UIKit

#if canImport(IronSource)
import IronSource
#endif

/// One rewarded video, exchanged for one voice generation.
///
/// Kept deliberately small and stateful-in-one-place: an ad is loaded ahead of
/// time so the button can say whether it will work, shown on demand, and
/// reloaded afterwards. Everything it can fail at — no fill, a capped placement,
/// an uninitialised SDK because the user declined consent — surfaces as
/// `isReady == false` rather than as a button that does nothing.
@MainActor
final class RewardedAdController: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "com.shukaihu.RainyClock", category: "RewardedAd")

    /// Alongside the banner's unit in `AppEnvironment`, since both are dashboard
    /// identifiers rather than per-build configuration. Blank turns the exchange
    /// off and the sheet stops offering it.
    static var adUnitID: String? {
        AppEnvironment.levelPlayRewardedAdUnitID.isEmpty ? nil : AppEnvironment.levelPlayRewardedAdUnitID
    }

    static var isConfigured: Bool { adUnitID != nil }

    @Published private(set) var isReady = false
    @Published private(set) var isPresenting = false

    private var onReward: (() -> Void)?

    #if canImport(IronSource)
    private var ad: LPMRewardedAd?
    #endif

    func load() {
        #if canImport(IronSource)
        guard let adUnitID = Self.adUnitID, ConsentManager.shared.canRequestAds else {
            return
        }
        if ad == nil {
            let rewarded = LPMRewardedAd(adUnitId: adUnitID)
            rewarded.setDelegate(self)
            ad = rewarded
        }
        ad?.loadAd()
        #endif
    }

    /// Shows the ad, and calls `onReward` if — and only if — the network says the
    /// reward was earned. Dismissing early gets nothing, which is the contract
    /// the user was offered.
    func show(onReward: @escaping () -> Void) {
        #if canImport(IronSource)
        guard let ad, ad.isAdReady(), let controller = Self.topViewController() else {
            Self.logger.error("Rewarded ad asked for but not ready")
            return
        }
        self.onReward = onReward
        isPresenting = true
        ad.showAd(viewController: controller, placementName: nil)
        #endif
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

#if canImport(IronSource)
extension RewardedAdController: @preconcurrency LPMRewardedAdDelegate {
    func didLoadAd(with adInfo: LPMAdInfo) {
        isReady = true
    }

    func didFailToLoadAd(withAdUnitId adUnitId: String, error: any Error) {
        // No fill is ordinary, not a fault. The caller shows a different message
        // rather than an error.
        isReady = false
        Self.logger.info("Rewarded ad unavailable: \(error.localizedDescription, privacy: .public)")
    }

    func didDisplayAd(with adInfo: LPMAdInfo) {
        isReady = false
        // What the report mail says about "the video": recorded at display,
        // not load, because a loaded-but-never-shown video is not one the user
        // can have a complaint about.
        RecentAds.shared.recordRewarded(AdSighting(adInfo))
    }

    /// Granting happens here, not in `didCloseAd`. The two callbacks are
    /// asynchronous with no guaranteed ordering, so treating a dismissal as
    /// confirmation would sometimes pay out and sometimes not.
    func didRewardAd(with adInfo: LPMAdInfo, reward: LPMReward) {
        onReward?()
        onReward = nil
    }

    func didFailToDisplayAd(with adInfo: LPMAdInfo, error: any Error) {
        isPresenting = false
        onReward = nil
        Self.logger.error("Rewarded ad failed to display: \(error.localizedDescription, privacy: .public)")
        load()
    }

    func didClickAd(with adInfo: LPMAdInfo) {}

    func didCloseAd(with adInfo: LPMAdInfo) {
        isPresenting = false
        onReward = nil
        // Have the next one ready before it is asked for.
        load()
    }

    func didChangeAdInfo(_ adInfo: LPMAdInfo) {}
}
#endif
