import Foundation

#if canImport(IronSource)
import IronSource
#endif

/// One ad the app showed, reduced to what a report needs to be traceable.
///
/// The mediator's `LPMAdInfo` carries far more, but only these fields tie a
/// complaint back to a creative: the network that filled the slot, the creative
/// id that Ad Quality blocks by, and the auction id ironSource support traces
/// by. Nothing here says anything about the person who saw it.
struct AdSighting: Equatable {
    let network: String
    let creativeId: String
    let auctionId: String
    let shownAt: Date

    #if canImport(IronSource)
    init(_ adInfo: LPMAdInfo, shownAt: Date = Date()) {
        self.init(
            network: adInfo.adNetwork,
            creativeId: adInfo.creativeId,
            auctionId: adInfo.auctionId,
            shownAt: shownAt
        )
    }
    #endif

    init(network: String, creativeId: String, auctionId: String, shownAt: Date) {
        self.network = network
        self.creativeId = creativeId
        self.auctionId = auctionId
        self.shownAt = shownAt
    }
}

/// The last ad shown in each slot, kept only in memory and only for the
/// report mail.
///
/// Two slots rather than a list because that is the whole question a report
/// has to answer: the app runs one banner and one rewarded video, and before
/// this existed a report could not say which of the two it was about.
@MainActor
final class RecentAds: ObservableObject {
    static let shared = RecentAds()

    @Published private(set) var banner: AdSighting?
    @Published private(set) var rewarded: AdSighting?

    func recordBanner(_ sighting: AdSighting) {
        banner = sighting
    }

    func recordRewarded(_ sighting: AdSighting) {
        rewarded = sighting
    }
}

/// The "report this ad" route required by App Review guideline 2.5.18, which
/// says an app carrying ads "must also include the ability for users to report
/// any inappropriate or age-inappropriate ads".
///
/// A mail draft rather than a form: the app has no backend that receives user
/// messages and no account to attach a report to, and adding either to satisfy
/// one guideline would mean collecting more about the user than the whole app
/// currently does.
///
/// Nothing here identifies the person. The prefilled body carries the app and
/// build version so a report can be tied to a release, and — because an ad
/// Rainy Clock cannot see is one only the mediator can trace — the network,
/// creative and auction ids of the last banner and the last rewarded video.
/// The user deletes the line that is not theirs, or leaves both; either way
/// the report says which format it is about, which a bare "Unity LevelPlay"
/// never could.
enum AdReport {
    static let address = "shukaihu@icloud.com"

    @MainActor
    static func mailURL(recentAds: RecentAds = .shared) -> URL {
        mailURL(banner: recentAds.banner, rewarded: recentAds.rewarded)
    }

    static func mailURL(banner: AdSighting?, rewarded: AdSighting?) -> URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "report_ad_subject")),
            URLQueryItem(name: "body", value: body(version: "\(version) (\(build))", banner: banner, rewarded: rewarded))
        ]
        // `mailto` bodies are percent-encoded, and a newline left raw truncates
        // the draft at the first line in some mail clients.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "mailto:\(address)")!
    }

    /// The prefilled body, separated from the URL so it can be read in a test.
    static func body(version: String, banner: AdSighting?, rewarded: AdSighting?) -> String {
        let lines = [
            banner.map { line(for: $0, format: String(localized: "report_ad_format_banner")) },
            rewarded.map { line(for: $0, format: String(localized: "report_ad_format_rewarded")) }
        ].compactMap { $0 }

        let sightings = lines.isEmpty
            ? String(localized: "report_ad_sightings_none")
            : lines.joined(separator: "\n")

        return String.localizedStringWithFormat(
            String(localized: "report_ad_body"),
            version,
            sightings
        )
    }

    private static func line(for sighting: AdSighting, format: String) -> String {
        String.localizedStringWithFormat(
            String(localized: "report_ad_sighting"),
            format,
            sighting.shownAt.formatted(date: .abbreviated, time: .shortened),
            sighting.network.isEmpty ? "?" : sighting.network,
            sighting.creativeId.isEmpty ? "?" : sighting.creativeId,
            sighting.auctionId.isEmpty ? "?" : sighting.auctionId
        )
    }
}
