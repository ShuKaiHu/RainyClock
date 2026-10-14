import XCTest
import SwiftUI
@testable import RainyClock

@MainActor
final class TaiwanDisasterMapTests: XCTestCase {
    func testBundledBoundariesCoverTheCompleteRegionCatalog() throws {
        let features = TaiwanTownshipCatalog.features
        XCTAssertEqual(features.count, 368)
        XCTAssertEqual(Set(features.map(\.id)).count, 368)
        XCTAssertEqual(Set(features.map { $0.region.county }).count, 22)
        XCTAssertEqual(Set(features.map(\.region)), Set(DisasterRegionCatalog.all))
        XCTAssertEqual(features.filter { $0.region.county == "連江縣" }.count, 4)
        XCTAssertTrue(features.contains { $0.region.name == "金門縣烏坵鄉" })
        XCTAssertTrue(features.flatMap(\.polygons).flatMap(\.rings).flatMap { $0 }.contains { $0.latitude < 15 },
                      "Viewport cropping must not discard remote islands from the catalog")
    }

    func testEveryBundledPolygonRingIsClosedAndFinite() throws {
        let features = TaiwanTownshipCatalog.features
        XCTAssertFalse(features.isEmpty)
        for feature in features {
            XCTAssertFalse(feature.polygons.isEmpty, feature.region.name)
            for polygon in feature.polygons {
                XCTAssertFalse(polygon.rings.isEmpty, feature.region.name)
                XCTAssertFalse(polygon.bounds.isNull, feature.region.name)
                for ring in polygon.rings {
                    XCTAssertGreaterThanOrEqual(ring.count, 4, feature.region.name)
                    XCTAssertEqual(ring.first, ring.last, feature.region.name)
                    XCTAssertTrue(ring.allSatisfy {
                        $0.longitude.isFinite && $0.latitude.isFinite
                            && (-180...180).contains($0.longitude) && (-90...90).contains($0.latitude)
                    }, feature.region.name)
                }
            }
        }
        XCTAssertEqual(Set(TaiwanTownshipCatalog.countyBoundaries.keys), Set(DisasterRegion.counties))
        XCTAssertTrue(TaiwanTownshipCatalog.countyBoundaries.values.allSatisfy { !$0.isEmpty })
    }

    func testInvalidGeometryCannotBecomeATappableShape() throws {
        let openRing = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"county":"臺北市","district":"信義區","townCode":"test"},"geometry":{"type":"Polygon","coordinates":[[[121,25],[122,25],[122,24],[121,24]]]}}]}
        """
        XCTAssertThrowsError(try TaiwanTownshipCatalog.decode(Data(openRing.utf8)))
        let invalidLatitude = openRing.replacingOccurrences(of: "[121,24]", with: "[121,95]")
        XCTAssertThrowsError(try TaiwanTownshipCatalog.decode(Data(invalidLatitude.utf8)))
        XCTAssertThrowsError(try TaiwanTownshipCatalog.decode(Data("{\"type\":\"FeatureCollection\",\"features\":[]}".utf8)))
    }

    func testShanhuaAndAndingMatchPinnedOfficialBoundsAndShareAnEdge() throws {
        // NLSC/TGOS TOWN_MOI_1140318, after the documented 50 m display
        // simplification. Locks the geometry/name association, not just a count.
        let expected: [(String, String, [Double])] = [
            ("善化區", "67000190", [120.254896, 23.104882, 120.346275, 23.176363]),
            ("安定區", "67000210", [120.187400, 23.066551, 120.269244, 23.135039])
        ]
        var boundaries: [Set<TaiwanTownshipCatalog.BoundarySegment>] = []
        for (district, id, bounds) in expected {
            let feature = try XCTUnwrap(TaiwanTownshipCatalog.features.first { $0.region.name == "臺南市" + district })
            XCTAssertEqual(feature.id, id)
            XCTAssertEqual(feature.polygons.count, 1)
            let polygon = try XCTUnwrap(feature.polygons.first)
            XCTAssertEqual(polygon.rings.count, 1)
            let ring = try XCTUnwrap(polygon.rings.first)
            XCTAssertEqual(try XCTUnwrap(ring.map(\.longitude).min()), bounds[0], accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(ring.map(\.latitude).min()), bounds[1], accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(ring.map(\.longitude).max()), bounds[2], accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(ring.map(\.latitude).max()), bounds[3], accuracy: 0.000001)
            boundaries.append(Set(zip(ring, ring.dropFirst()).map { TaiwanTownshipCatalog.BoundarySegment($0.0, $0.1) }))
        }
        XCTAssertFalse(boundaries[0].intersection(boundaries[1]).isEmpty)
    }

    func testTainanProjectionPreservesProportionsAndMarkersStayInsideDistricts() throws {
        for size in [CGSize(width: 360, height: 265), CGSize(width: 265, height: 360)] {
            let layout = TownshipMapLayout(size: size, focusedCounty: "臺南市")
            XCTAssertEqual(layout.townships.count, 37)
            for district in ["善化區", "安定區"] {
                let feature = try XCTUnwrap(TaiwanTownshipCatalog.features.first { $0.region.name == "臺南市" + district })
                let township = try XCTUnwrap(layout.townships.first { $0.region == feature.region })
                let source = feature.polygons.reduce(CGRect.null) { $0.union($1.bounds) }
                let rendered = township.path.boundingRect
                XCTAssertEqual(rendered.width / rendered.height, source.width / source.height, accuracy: 0.000001)
                XCTAssertTrue(township.path.contains(try XCTUnwrap(township.markerPoint), eoFill: true))
            }
            let shanhua = try XCTUnwrap(layout.townships.first { $0.region.district == "善化區" }).path.boundingRect
            let anding = try XCTUnwrap(layout.townships.first { $0.region.district == "安定區" }).path.boundingRect
            XCTAssertGreaterThan(shanhua.midX, anding.midX)
            XCTAssertLessThan(shanhua.midY, anding.midY, "North stays up; the map must not mirror or rotate the source")
        }
    }

    func testTownshipHighlightCannotGrowMiterSpikesOutsideItsStrokeRadius() throws {
        for size in [CGSize(width: 360, height: 265), CGSize(width: 265, height: 360)] {
            let layout = TownshipMapLayout(size: size, focusedCounty: "臺南市")
            for district in ["善化區", "安定區"] {
                let township = try XCTUnwrap(layout.townships.first { $0.region.district == district })
                let segments = TownshipMapOutline.segments(of: township.path)
                var vertices: [CGPoint] = []
                township.path.strokedPath(TownshipMapOutline.style(width: 4)).forEach { element in
                    switch element {
                    case .move(let point), .line(let point): vertices.append(point)
                    case .quadCurve(let point, _): vertices.append(point)
                    case .curve(let point, _, _): vertices.append(point)
                    case .closeSubpath: break
                    }
                }
                XCTAssertFalse(vertices.isEmpty)
                let furthest = vertices.map { point in
                    segments.map { TownshipMapOutline.distanceSquared(point, to: $0) }.min() ?? .infinity
                }.max() ?? .infinity
                XCTAssertLessThanOrEqual(sqrt(furthest), 2.01, "The old 4 pt miter stroke reached over 5 pt from these real boundaries")
            }
        }
    }
}
