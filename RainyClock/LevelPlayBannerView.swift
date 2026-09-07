import IronSource
import SwiftUI
import UIKit

struct LevelPlayBannerView: View {
    let adUnitID: String
    @State private var isLoaded = false
    /// The height the loaded creative actually reported. Starts at the standard
    /// banner height so the reserved space is right before the first load.
    @State private var loadedHeight: CGFloat = 50

    var body: some View {
        GeometryReader { proxy in
            // Anchored adaptive, the same slot shape the AdMob banner used: this
            // banner is pinned above the tab bar, and the width decides the
            // height LevelPlay may fill.
            let width = max(proxy.size.width, 320)
            let adSize = LPMAdSize.createAdaptiveAdSize(withWidth: width) ?? LPMAdSize.banner()
            let height = CGFloat(adSize.height)

            HStack {
                Spacer(minLength: 0)
                LevelPlayBannerContainer(
                    adUnitID: adUnitID,
                    adSize: adSize,
                    width: width,
                    height: height,
                    isLoaded: $isLoaded,
                    loadedHeight: $loadedHeight
                )
                    .frame(width: width, height: height)
                    .opacity(isLoaded ? 1 : 0)
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: height)
        }
        .frame(height: isLoaded ? loadedHeight : 0)
        .clipped()
    }
}

private struct LevelPlayBannerContainer: UIViewRepresentable {
    let adUnitID: String
    let adSize: LPMAdSize
    let width: CGFloat
    let height: CGFloat
    @Binding var isLoaded: Bool
    @Binding var loadedHeight: CGFloat

    func makeUIView(context: Context) -> LPMBannerAdView {
        let config = LPMBannerAdViewConfigBuilder()
            .set(adSize: adSize)
            .build()

        let banner = LPMBannerAdView(adUnitId: adUnitID, config: config)
        banner.setDelegate(context.coordinator)
        banner.frame = CGRect(x: 0, y: 0, width: width, height: height)

        // The load call wants a presenting view controller (click-throughs open
        // from it). The banner only enters the hierarchy once the app is active,
        // so the key window's root exists by now.
        if let viewController = UIApplication.shared.rainyClockRootViewController {
            banner.loadAd(with: viewController)
        }

        // Auto-refresh cadence is a LevelPlay dashboard setting; resuming is a
        // no-op when it was never paused, and guards against a stray pause.
        banner.resumeAutoRefresh()
        return banner
    }

    func updateUIView(_ banner: LPMBannerAdView, context: Context) {
        banner.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }

    static func dismantleUIView(_ banner: LPMBannerAdView, coordinator: Coordinator) {
        // A destroyed banner cannot load again; that is fine, every rebuild
        // (`.id(adConfigurationRevision)`) makes a fresh one.
        banner.destroy()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoaded: $isLoaded, loadedHeight: $loadedHeight)
    }

    // `@preconcurrency`: LevelPlay documents that its ad callbacks arrive on
    // the main thread, but the delegate protocol predates Swift concurrency
    // and carries no isolation annotation for the compiler to check against.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency LPMBannerAdViewDelegate {
        @Binding private var isLoaded: Bool
        @Binding private var loadedHeight: CGFloat

        init(isLoaded: Binding<Bool>, loadedHeight: Binding<CGFloat>) {
            _isLoaded = isLoaded
            _loadedHeight = loadedHeight
        }

        func didLoadAd(with adInfo: LPMAdInfo) {
            // Reserve exactly what the creative asked for: an adaptive size
            // varies with width and orientation, so a hardcoded height would
            // clip it.
            if let height = adInfo.adSize?.height {
                loadedHeight = CGFloat(height)
            }
            isLoaded = true
            // A loaded banner is on screen at once (the opacity flips with
            // `isLoaded`), so this is the moment a report could be about. Every
            // auto-refresh lands here too, which keeps the record current.
            RecentAds.shared.recordBanner(AdSighting(adInfo))
            // The counterpart of the failure log below. Without it a silent
            // console means either "filled" or "never asked", which is the
            // same blind spot the failure log exists to close.
            #if DEBUG
            let size = adInfo.adSize.map { "\($0.width)x\($0.height)" } ?? "unknown size"
            print("[LevelPlay] banner loaded from \(adInfo.adNetwork), \(size)")
            #endif
        }

        func didDisplayAd(with adInfo: LPMAdInfo) {
            // Same record as the load, refreshed from the impression callback,
            // which is the one the dashboard's own numbers are built on.
            RecentAds.shared.recordBanner(AdSighting(adInfo))
        }

        func didFailToLoadAd(withAdUnitId adUnitId: String, error: Error) {
            isLoaded = false
            // A failed load collapses to zero height and is indistinguishable
            // from "no ad requested" on screen, which is the diagnosis blind
            // spot behind every "is the integration broken?" round-trip in
            // STATUS-IOS.md.
            #if DEBUG
            print("[LevelPlay] banner failed to load: \(error.localizedDescription)")
            #endif
        }
    }
}
