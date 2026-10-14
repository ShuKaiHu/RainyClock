import XCTest
@testable import RainyClock

/// The report mail is the only thing that turns a complaint into a creative
/// someone can find. These pin down what it says, independent of language.
final class AdReportTests: XCTestCase {
    private let shownAt = Date(timeIntervalSince1970: 1_757_200_000)

    func testBodyNamesBothSlotsWithTheirIdentifiers() {
        let banner = AdSighting(network: "ironsourceads", creativeId: "crt-banner", auctionId: "auc-1", shownAt: shownAt)
        let rewarded = AdSighting(network: "unityads", creativeId: "crt-video", auctionId: "auc-2", shownAt: shownAt)

        let body = AdReport.body(version: "1.6.9 (28)", banner: banner, rewarded: rewarded)

        XCTAssertTrue(body.contains("1.6.9 (28)"))
        for identifier in ["ironsourceads", "crt-banner", "auc-1", "unityads", "crt-video", "auc-2"] {
            XCTAssertTrue(body.contains(identifier), "missing \(identifier) in:\n\(body)")
        }
        // One line per slot, banner first, so the reader can delete the other.
        let bannerLine = body.range(of: "crt-banner")!.lowerBound
        let videoLine = body.range(of: "crt-video")!.lowerBound
        XCTAssertLessThan(bannerLine, videoLine)
    }

    func testBodyOmitsASlotThatNeverShowed() {
        let banner = AdSighting(network: "ironsourceads", creativeId: "crt-banner", auctionId: "auc-1", shownAt: shownAt)

        let body = AdReport.body(version: "1.6.9 (28)", banner: banner, rewarded: nil)

        XCTAssertTrue(body.contains("crt-banner"))
        XCTAssertFalse(body.contains(String(localized: "report_ad_format_rewarded")))
    }

    func testBodyWithNoAdsSaysSoInsteadOfLeavingABlank() {
        let body = AdReport.body(version: "1.6.9 (28)", banner: nil, rewarded: nil)

        XCTAssertTrue(body.contains(String(localized: "report_ad_sightings_none")))
    }

    func testBlankIdentifiersBecomeQuestionMarksNotEmptyGaps() {
        // `LPMAdInfo` returns "" for a string it does not have.
        let banner = AdSighting(network: "", creativeId: "", auctionId: "", shownAt: shownAt)

        let body = AdReport.body(version: "1.6.9 (28)", banner: banner, rewarded: nil)

        XCTAssertTrue(body.contains("?"))
    }

    func testMailURLIsAMailtoToTheSupportAddressWithAnEncodedBody() {
        let banner = AdSighting(network: "ironsourceads", creativeId: "crt+plus", auctionId: "auc-1", shownAt: shownAt)

        let url = AdReport.mailURL(banner: banner, rewarded: nil)

        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, AdReport.address)
        // A literal "+" must survive as "+", not decode to a space on the far end.
        XCTAssertTrue(url.absoluteString.contains("crt%2Bplus"))
        XCTAssertFalse(url.absoluteString.contains("crt+plus"))
    }
}
