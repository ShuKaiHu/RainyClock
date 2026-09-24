import SwiftUI
import UIKit
import WeatherKit
import WidgetKit

/// Displays Apple's required WeatherKit attribution: the official Apple Weather
/// combined mark ( Weather) linked to the legal attribution page. The app is
/// locked to dark mode, so the dark combined mark is always used.
struct WeatherAttributionView: View {
    @State private var attribution: WeatherAttribution?

    var body: some View {
        // The mark itself links to the legal attribution page, satisfying the
        // WeatherKit requirement of showing the Apple Weather trademark together
        // with a link to its data-source attribution.
        Link(destination: attribution?.legalPageURL ?? WeatherAttributionLink.fallbackLegalURL) {
            if let markURL = attribution?.combinedMarkDarkURL {
                AsyncImage(url: markURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    fallbackLabel
                }
                .frame(height: 16)
            } else {
                fallbackLabel
            }
        }
        .task {
            attribution = try? await WeatherService.shared.attribution
            // The same attribution also feeds the medium widget's copy of the mark.
            if let attribution {
                await WeatherAttributionMarkCache.refreshIfNeeded(with: attribution)
            }
        }
    }

    private var fallbackLabel: some View {
        Text("weather_data_attribution")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// Keeps Apple's combined Weather mark in the App Group for the medium widget, which
/// cannot reach the network (`WeatherAttributionMarkStore`). Runs only where the app
/// already talks to WeatherKit: the weather card's attribution above, and the
/// background refresh that fetches tomorrow's forecast. At most weekly per variant.
enum WeatherAttributionMarkCache {
    static let refreshInterval: TimeInterval = 7 * 86_400
    @MainActor private static var isRefreshing = false

    @MainActor
    static func refreshIfNeeded(with attribution: WeatherAttribution? = nil,
                                store: WeatherAttributionMarkStore = .appGroup, now: Date = Date()) async {
        guard !AppEnvironment.isRunningTests, !isRefreshing,
              store.needsRefresh(now: now, maximumAge: refreshInterval) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let resolved: WeatherAttribution
        if let attribution {
            resolved = attribution
        } else {
            guard let fetched = try? await WeatherService.shared.attribution else { return }
            resolved = fetched
        }
        var wrote = false
        let marks: [(WeatherAttributionMarkStore.Variant, URL)] = [
            (.light, resolved.combinedMarkLightURL), (.dark, resolved.combinedMarkDarkURL)]
        for (variant, url) in marks {
            guard !Task.isCancelled,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if store.save(data, for: variant) { wrote = true }
        }
        if wrote, TomorrowWidgetPublisher.systemHostsWidget {
            WidgetCenter.shared.reloadTimelines(ofKind: TomorrowWidgetSnapshot.kind)
        }
    }
}

/// The medium widget's weather column links to `WeatherAttributionMarkStore.legalLinkURL`;
/// the app answers by opening Apple's legal attribution page, the data-source link
/// WeatherKit requires beside the mark.
enum WeatherAttributionLink {
    static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    static func isAttributionLink(_ url: URL) -> Bool {
        url.scheme == WeatherAttributionMarkStore.legalLinkURL.scheme
            && url.host == WeatherAttributionMarkStore.legalLinkURL.host
    }

    /// Returns whether `url` was the widget's attribution link.
    @MainActor
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard isAttributionLink(url) else { return false }
        Task { @MainActor in
            let legal = (try? await WeatherService.shared.attribution)?.legalPageURL ?? fallbackLegalURL
            await UIApplication.shared.open(legal)
        }
        return true
    }
}
