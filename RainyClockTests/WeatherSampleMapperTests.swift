import CoreLocation
import XCTest
@testable import RainyClock

@MainActor
final class MapItemSearchResultTests: XCTestCase {
    func testLocalizedFirstResultDoesNotHideLaterMatchingStationWhenReverseLookupFails() async throws {
        let chineseStation = candidate("台北車站", address: "100台灣臺北市中正區", latitude: 25.0485774)
        let englishStation = candidate("Taipei Main Station", address: "100台灣臺北市中正區北平西路3號", latitude: 25.0473199)

        let result = try await MapItemResolver.resolveSearchCandidates(
            [chineseStation, englishStation], query: "Taipei Main Station"
        ) { _, _ in nil }

        XCTAssertEqual(result, englishStation.location)
    }

    func testKeepsAppleRankingWhenFirstCandidateCanBeLocalized() async throws {
        let first = candidate("台北車站", address: "100台灣臺北市中正區", latitude: 25.0485774)
        let second = candidate("Taipei Main Station", latitude: 25.0473199)
        let result = try await MapItemResolver.resolveSearchCandidates(
            [first, second], query: "Taipei Main Station"
        ) { _, _ in "Taipei Main Station, Zhengzhou Rd, Zhongzheng District, Taipei City" }

        XCTAssertEqual(result?.latitude, first.location.latitude)
        XCTAssertEqual(result?.displayAddress, "Taipei Main Station, Zhengzhou Rd, Zhongzheng District, Taipei City")
    }

    func testMatchingPOINameSurvivesReverseLookupReturningOnlyAnUnrelatedStreetLabel() async throws {
        let station = candidate("Taipei Main Station 台北車站", latitude: 25.0485774)
        let result = try await MapItemResolver.resolveSearchCandidates(
            [station], query: "Taipei Main Station"
        ) { _, _ in "Zhengzhou Rd" }

        XCTAssertEqual(result, station.location)
    }

    func testMatchingPOIKeepsCoordinatesWhenOptionalLocalizationFails() async throws {
        let landmark = candidate("Taipei 101 台北101", latitude: 25.033649)
        let result = try await MapItemResolver.resolveSearchCandidates(
            [landmark], query: "Taipei 101"
        ) { _, _ in nil }

        XCTAssertEqual(result, landmark.location)
    }

    func testUsesAddressMetadataAsWellAsPOIName() async throws {
        let station = candidate("台北車站", address: "3 Beiping W Rd, Zhongzheng District, Taipei City", latitude: 25.0473199)
        let result = try await MapItemResolver.resolveSearchCandidates(
            [station], query: "Taipei Main Station"
        ) { _, _ in nil }

        XCTAssertEqual(result, station.location)
    }

    func testDoesNotReturnWrongCityOrUnrelatedCandidatesWhenEveryMatchFails() async throws {
        let result = try await MapItemResolver.resolveSearchCandidates([
            candidate("Maan", address: "Fushan Village, Wulai District, New Taipei City", latitude: 24.7789256),
            candidate("Heping Rd", address: "Kaohsiung City", latitude: 22.63)
        ], query: "Taipei Main Station") { _, _ in nil }

        XCTAssertNil(result)
    }

    func testSpecificStreetStillRejectsWrongHouseNumberAndChecksLaterResult() async throws {
        let wrong = candidate("台南市新市區南科北路231號", latitude: 23.1)
        let correct = candidate("台南市新市區南科北路1號", latitude: 23.11)
        let result = try await MapItemResolver.resolveSearchCandidates(
            [wrong, correct], query: "南科北路1號, 台南市新市區"
        ) { _, _ in nil }

        XCTAssertEqual(result, correct.location)
    }

    func testCancellationDuringLocalizationDoesNotPublishCoordinatesOrTryAnotherCandidate() async {
        let lookup = SuspendedMapLocalization()
        let first = candidate("台北車站", latitude: 25.0485774)
        let second = candidate("Taipei Main Station", latitude: 25.0473199)
        let task = Task {
            try await MapItemResolver.resolveSearchCandidates([first, second], query: "Taipei Main Station") { _, _ in
                await lookup.run()
            }
        }
        await lookup.waitUntilStarted()
        task.cancel()
        await lookup.finish()

        do {
            _ = try await task.value
            XCTFail("A cancelled lookup must not return a stale address")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func candidate(_ name: String, address: String = "", latitude: Double) -> MapSearchCandidate {
        MapSearchCandidate(
            location: ResolvedMapLocation(latitude: latitude, longitude: 121.5, displayAddress: name, resolution: .exact),
            matchingAddress: [name, address].filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }
}

private actor SuspendedMapLocalization {
    private var continuation: CheckedContinuation<String?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func run() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume(returning: "Taipei Main Station")
        continuation = nil
    }
}

final class RoutePolylineSamplerTests: XCTestCase {
    func testDegenerateRoutesProduceNoInteriorSamples() {
        // The sampler deleted in the 1.6.5 cleanup trapped on these.
        XCTAssertEqual(RoutePolylineSampler.interiorSamplePoints(along: []).count, 0)
        XCTAssertEqual(
            RoutePolylineSampler.interiorSamplePoints(along: [
                CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
            ]).count,
            0
        )
        XCTAssertEqual(
            RoutePolylineSampler.interiorSamplePoints(along: [
                CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5),
                CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
            ]).count,
            0
        )
    }

    func testShortCommutesRelyOnTheEndpointsAlone() {
        // ~2.2 km straight line: below the 4 km floor.
        let samples = RoutePolylineSampler.interiorSamplePoints(along: [
            CLLocationCoordinate2D(latitude: 25.03, longitude: 121.50),
            CLLocationCoordinate2D(latitude: 25.05, longitude: 121.50)
        ])
        XCTAssertEqual(samples.count, 0)
    }

    func testMediumCommutesSampleTheMidpoint() {
        // ~11 km straight line north: one interior sample at the midpoint.
        let samples = RoutePolylineSampler.interiorSamplePoints(along: [
            CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5),
            CLLocationCoordinate2D(latitude: 25.1, longitude: 121.5)
        ])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].latitude, 25.05, accuracy: 1e-6)
        XCTAssertEqual(samples[0].longitude, 121.5, accuracy: 1e-6)
    }

    func testLongCommutesSampleQuarterPoints() {
        // ~33 km: quarter, mid, three-quarter.
        let samples = RoutePolylineSampler.interiorSamplePoints(along: [
            CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5),
            CLLocationCoordinate2D(latitude: 25.3, longitude: 121.5)
        ])
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].latitude, 25.075, accuracy: 1e-6)
        XCTAssertEqual(samples[1].latitude, 25.15, accuracy: 1e-6)
        XCTAssertEqual(samples[2].latitude, 25.225, accuracy: 1e-6)
    }

    func testMidpointInterpolatesWithinTheContainingSegment() {
        // Uneven vertices: 0 → 8 km → 10 km. The midpoint (5 km) sits inside
        // the first segment, not on a vertex.
        let samples = RoutePolylineSampler.interiorSamplePoints(along: [
            CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5),
            CLLocationCoordinate2D(latitude: 25.072, longitude: 121.5),
            CLLocationCoordinate2D(latitude: 25.09, longitude: 121.5)
        ])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].latitude, 25.045, accuracy: 1e-3)
    }

    func testInteriorSegmentNamesDescribeThePositionAlongTheRoute() {
        XCTAssertEqual(
            MapKitRouteWeatherService.interiorSegmentName(index: 0, total: 1),
            String(localized: "segment_route_half")
        )

        let names = (0..<3).map { MapKitRouteWeatherService.interiorSegmentName(index: $0, total: 3) }
        XCTAssertEqual(names, [
            String(localized: "segment_route_quarter"),
            String(localized: "segment_route_half"),
            String(localized: "segment_route_three_quarter")
        ])
    }

    /// The labels above are derived from the position, so they only stay true
    /// while the sampler keeps spacing its points evenly.
    func testSampleFractionsAreEvenlySpacedSoTheNamesStayTrue() {
        for length in [10_000.0, 40_000.0] {
            let fractions = RoutePolylineSampler.interiorSampleFractions(forRouteLength: length)
            let expected = (0..<fractions.count).map { Double($0 + 1) / Double(fractions.count + 1) }
            XCTAssertEqual(fractions, expected, "route length \(length)")
        }

        XCTAssertTrue(RoutePolylineSampler.interiorSampleFractions(forRouteLength: 3_000).isEmpty)
    }
}

final class WeatherSampleMapperTests: XCTestCase {
    func testConditionMappingUsesRainThreshold() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.5), .rain)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.8), .rain)
    }

    func testConditionMappingUsesCloudyBand() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.2), .cloudy)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.49), .cloudy)
    }

    func testConditionMappingUsesClearBand() {
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.0), .clear)
        XCTAssertEqual(WeatherSampleMapper.condition(for: 0.19), .clear)
    }

    func testMapItemResolverTreatsCaseWidthAndPunctuationVariantsAsSameAddress() {
        for (typed, resolved) in [("Taipei main station", "Taipei Main Station"),
                                  ("  Taipei  Main Station ", "Taipei Main Station"),
                                  ("ＴＡＩＰＥＩ　１０１", "Taipei 101"),
                                  ("臺北車站", "台北車站"),
                                  ("Taipei-101", "Taipei 101"),
                                  ("Dà’ān Park", "Daan Park")] {
            XCTAssertTrue(MapItemResolver.isSameAddressText(typed, resolved), "\(typed) vs \(resolved)")
        }
    }

    func testMapItemResolverKeepsMaterialNameDifferencesApart() {
        for (typed, resolved) in [("Taipei Main Station", "Taipei Station"),
                                  ("Taipei Main Station", "台北車站"),
                                  ("Taipei Main Station", "Taipei Main Station, Zhongzheng District"),
                                  ("Taipei 101", "Taipei 101 Mall"),
                                  ("中正路100號", "中正路100號, 永康區, 台南市"),
                                  ("", "")] {
            XCTAssertFalse(MapItemResolver.isSameAddressText(typed, resolved), "\(typed) vs \(resolved)")
        }
    }

    func testMapItemResolverFlagsSameNamedPlacesInOtherTownsOnly() {
        let chosen = ResolvedMapLocation(latitude: 25.0478, longitude: 121.5170,
                                         displayAddress: "Taipei Main Station", resolution: .exact)
        // TRA, MRT and HSR halls of one station sit within a few hundred metres.
        let station = [(name: "Taipei Main Station", coordinate: CLLocationCoordinate2D(latitude: 25.0461, longitude: 121.5174)),
                       (name: "Taipei Main Station Lobby", coordinate: CLLocationCoordinate2D(latitude: 22.6, longitude: 120.3))]
        XCTAssertFalse(MapItemResolver.hasDistantNamesake(of: chosen, among: station, query: "taipei main station"))
        let chain = [(name: "McDonald's", coordinate: CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5170)),
                     (name: "McDonalds", coordinate: CLLocationCoordinate2D(latitude: 22.6273, longitude: 120.3014))]
        XCTAssertTrue(MapItemResolver.hasDistantNamesake(of: chosen, among: chain, query: "McDonald's"))
    }

    func testMapItemResolverRecognisesHouseNumbers() {
        for text in ["中正路100號", "中正路 100 號", "No. 7, Section 5, Xinyi Rd", "#12 Main St", "1 Infinite Loop"] {
            XCTAssertTrue(MapItemResolver.containsHouseNumber(text), text)
        }
        for text in ["Taipei 101", "Taipei Main Station", "台北101", "7-ELEVEN"] {
            XCTAssertFalse(MapItemResolver.containsHouseNumber(text), text)
        }
    }

    func testMapItemResolverBuildsFallbackQueriesForPastedTSMCAddress() {
        let queries = MapItemResolver.candidateQueries(
            for: "台灣積體電路製造股份有限公司, 74144台灣台南市科學園區南科北路1號"
        )

        XCTAssertTrue(queries.contains("台灣台南市科學園區南科北路1號"))
        XCTAssertTrue(queries.contains("台積電 南科北路1號"))
        XCTAssertTrue(queries.contains("台南市新市區南科北路1號"))
    }

    func testMapItemResolverRejectsLooseRoadMatchForTSMCFabKeyword() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "台積電 F18A",
            displayAddress: "Heping Rd"
        ))
    }

    func testMapItemResolverAcceptsRelevantTaiwanRoadMatch() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "台南市新市區南科北路1號",
            displayAddress: "南科北路1號, 新市區, 台南市"
        ))
    }

    func testMapItemResolverAcceptsSpecificAddressWhenAppleReturnsTransliteration() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "生態街59號, 台灣臺南市安南區海南里",
            displayAddress: "No. 59 Shengtai St, Shengtai St, Hainan Village, Annan District, Tainan City"
        ))
    }

    func testMapItemResolverRejectsPostalCodeOnlySuggestion() {
        let queries = MapItemResolver.candidateQueries(
            for: "台灣積體電路製造股份有限公司, 74144台灣台南市科學園區南科北路1號"
        )

        XCTAssertFalse(queries.contains("74144"))
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "74144",
            displayAddress: "74144"
        ))
    }

    func testMapItemResolverRejectsUnrelatedSpecificStreetMatch() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "自由路271號, 台灣台南市善化區",
            displayAddress: "Heping Rd"
        ))
    }

    func testMapItemResolverAcceptsRomanizedDisplayOutsideTainan() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "中正路100號, 台北市中山區",
            displayAddress: "No. 100, Zhongzheng Rd, Zhongshan District, Taipei City"
        ))
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "中山路50號, 高雄市前金區",
            displayAddress: "No. 50, Zhongshan Rd, Qianjin District, Kaohsiung City"
        ))
    }

    func testMapItemResolverAcceptsHashStyleHouseNumber() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "生態街59號, 台南市安南區",
            displayAddress: "#59 Shengtai St, Annan District, Tainan City"
        ))
    }

    func testMapItemResolverUsesDynamicTransliterationForUnlistedLocality() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "中正路100號, 桃園市中壢區",
            displayAddress: "No. 100, Zhongzheng Rd, Zhongli District, Taoyuan City"
        ))
        // District-only display: only the dynamic transliteration path can accept this.
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "中正路100號, 桃園市中壢區",
            displayAddress: "No. 100, Zhongzheng Rd, Zhongli District"
        ))
    }

    func testMapItemResolverRejectsDifferentHouseNumberInHanDisplay() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "南科北路1號, 台南市新市區",
            displayAddress: "台南市新市區南科北路231號"
        ))
    }

    func testMapItemResolverRejectsBareLocalityForSpecificStreetQuery() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "自由路271號, 台南市善化區",
            displayAddress: "台南市"
        ))
    }

    func testMapItemResolverRejectsWrongCityWithMatchingStreetName() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "民生路25號, 台北市大同區",
            displayAddress: "No. 25, Minsheng Rd, Banqiao District, New Taipei City"
        ))
    }

    func testMapItemResolverAcceptsEnglishPOIWithLocalizedAddressDisplay() {
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "Taipei Main Station",
            displayAddress: "3 Beiping W Rd, Zhongzheng District, Taipei City"
        ))
    }

    func testMapItemResolverRejectsNewTaipeiFragmentForEnglishTaipeiQuery() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "Taipei Main Station",
            displayAddress: "Maan, Fushan Village, Wulai District, New Taipei City"
        ))
    }

    func testMapItemResolverRejectsEnglishQueryWithWrongCity() {
        XCTAssertFalse(MapItemResolver.isAcceptableResolvedAddress(
            query: "Zhongzheng Rd, Taipei City",
            displayAddress: "Zhongzheng Rd, Qianjin District, Kaohsiung City"
        ))
    }

    func testPreferredSearchLocaleFollowsQueryLanguage() {
        XCTAssertEqual(MapItemResolver.preferredSearchLocale(for: "台北市中正區北平西路3號").identifier, "zh-Hant-TW")
        XCTAssertEqual(MapItemResolver.preferredSearchLocale(for: "Taipei Main Station").identifier, "en-US")
        // Mixed input keeps Chinese results.
        XCTAssertEqual(MapItemResolver.preferredSearchLocale(for: "台積電 Fab 18, Tainan").identifier, "zh-Hant-TW")
    }

    func testMapItemResolverAcceptsStreetsNamedAfterCounties() {
        // 金門街 is a Taipei street; the county name inside it must not register as a
        // city mention and trigger the wrong-city rejection.
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "中正區金門街10號",
            displayAddress: "No. 10 Jinmen St, Zhongzheng District, Taipei City"
        ))
        XCTAssertTrue(MapItemResolver.isAcceptableResolvedAddress(
            query: "基隆路100號, 台北市大安區",
            displayAddress: "No. 100, Keelung Rd, Da'an District"
        ))
    }
}
