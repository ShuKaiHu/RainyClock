import SwiftUI

/// Bundled boundaries remain available without location permission or a network
/// connection. Geometry includes remote islands even when an overview crops them.
enum TaiwanTownshipCatalog {
    struct Point: Hashable, Sendable {
        let longitude: Double
        let latitude: Double
        // A local equirectangular projection keeps Taiwan's proportions without
        // depending on a map service. All viewports use the same projection.
        var projected: CGPoint {
            CGPoint(x: longitude * cos(23.6 * .pi / 180), y: -latitude)
        }
    }

    struct Polygon: Sendable {
        let rings: [[Point]]
        let bounds: CGRect

        init(rings: [[Point]]) {
            self.rings = rings
            guard let first = rings.first?.first?.projected else { bounds = .null; return }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for ring in rings {
                for coordinate in ring {
                    let point = coordinate.projected
                    minX = min(minX, point.x); maxX = max(maxX, point.x)
                    minY = min(minY, point.y); maxY = max(maxY, point.y)
                }
            }
            bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    struct Feature: Identifiable, Sendable {
        let id: String
        let region: DisasterRegion
        let polygons: [Polygon]
    }

    struct BoundarySegment: Hashable, Sendable {
        let start: Point
        let end: Point
        init(_ first: Point, _ second: Point) {
            let forward = first.longitude < second.longitude
                || (first.longitude == second.longitude && first.latitude <= second.latitude)
            start = forward ? first : second
            end = forward ? second : first
        }
    }

    static let features: [Feature] = {
        guard let url = Bundle.main.url(forResource: "taiwan-townships", withExtension: "geojson"),
              let data = try? Data(contentsOf: url), data.count <= 24 * 1024 * 1024,
              let values = try? decode(data) else { return [] }
        return values
    }()

    /// The source retains shared topology. Two copies of a segment within one
    /// county form a township border; a single copy forms the county's outline.
    static let countyBoundaries: [String: [BoundarySegment]] = {
        var counts: [String: [BoundarySegment: Int]] = [:]
        for feature in features {
            for polygon in feature.polygons {
                for ring in polygon.rings {
                    for (first, second) in zip(ring, ring.dropFirst()) where first != second {
                        counts[feature.region.county, default: [:]][BoundarySegment(first, second), default: 0] += 1
                    }
                }
            }
        }
        return counts.mapValues { $0.compactMap { $0.value == 1 ? $0.key : nil } }
    }()

    /// Internal for geometry validation tests; malformed geometry fails closed.
    static func decode(_ data: Data) throws -> [Feature] {
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        guard collection.type == "FeatureCollection", !collection.features.isEmpty else {
            throw GeometryError.invalid
        }
        var identifiers = Set<String>()
        return try collection.features.map { value in
            let region = DisasterRegion(county: DisasterRegion.normalize(value.properties.county),
                                        district: DisasterRegion.normalize(value.properties.district))
            guard value.type == "Feature", region.isValid, !value.properties.townCode.isEmpty,
                  identifiers.insert(value.properties.townCode).inserted,
                  !value.geometry.coordinates.isEmpty else { throw GeometryError.invalid }
            let polygons = try value.geometry.coordinates.map { polygon in
                guard !polygon.isEmpty else { throw GeometryError.invalid }
                let rings = try polygon.map { ring in
                    guard ring.count >= 4 else { throw GeometryError.invalid }
                    let points = try ring.map { coordinate in
                        guard coordinate.count >= 2, coordinate[0].isFinite, coordinate[1].isFinite,
                              (-180...180).contains(coordinate[0]), (-90...90).contains(coordinate[1]) else {
                            throw GeometryError.invalid
                        }
                        return Point(longitude: coordinate[0], latitude: coordinate[1])
                    }
                    guard points.first == points.last else { throw GeometryError.invalid }
                    return points
                }
                return Polygon(rings: rings)
            }
            return Feature(id: value.properties.townCode, region: region, polygons: polygons)
        }.sorted { $0.id < $1.id }
    }

    private enum GeometryError: Error { case invalid }
    private struct Collection: Decodable {
        let type: String
        let features: [GeoFeature]
    }
    private struct GeoFeature: Decodable {
        let type: String
        let properties: Properties
        let geometry: Geometry
    }
    private struct Properties: Decodable {
        let county: String
        let district: String
        let townCode: String
    }
    private struct Geometry: Decodable {
        let coordinates: [[[[Double]]]]
        private enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(String.self, forKey: .type) {
            case "MultiPolygon": coordinates = try values.decode([[[[Double]]]].self, forKey: .coordinates)
            case "Polygon": coordinates = [try values.decode([[[Double]]].self, forKey: .coordinates)]
            default: throw GeometryError.invalid
            }
        }
    }
}

struct TaiwanDisasterMap: View {
    let statuses: [DisasterRegion: DisasterMapStatus]
    let home: DisasterRegion?
    let work: DisasterRegion?
    @Binding var focusedCounty: String?
    @Binding var selectedRegion: DisasterRegion?

    var body: some View {
        GeometryReader { geometry in
            let layout = TownshipMapLayout(size: geometry.size, focusedCounty: focusedCounty)
            if layout.townships.isEmpty {
                ContentUnavailableView {
                    Label("disaster_map_geometry_unavailable", systemImage: "map")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, _ in
                    draw(layout, in: &context)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    // Smaller polygons win a shared boundary/overlap. Even-odd
                    // containment respects lakes and other interior holes.
                    guard let hit = layout.townships.sorted(by: { $0.area < $1.area })
                        .first(where: { $0.path.contains(value.location, eoFill: true) }) else { return }
                    selectedRegion = hit.region
                    if focusedCounty == nil { focusedCounty = hit.region.county }
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("disaster_map_accessibility_label"))
                .accessibilityValue(Text(selectedRegion?.name ?? focusedCounty ?? ""))
                .accessibilityHint(Text("disaster_map_accessibility_hint"))
            }
        }
        .background(Color.appCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func draw(_ layout: TownshipMapLayout, in context: inout GraphicsContext) {
        for inset in layout.insets {
            let shape = Path(roundedRect: inset.frame, cornerRadius: 12)
            context.fill(shape, with: .color(Color.white.opacity(0.025)))
            context.stroke(shape, with: .color(Color.white.opacity(0.09)), lineWidth: 0.7)
            let compact = inset.frame.height < 32
            let title = Text(LocalizedStringKey(inset.label)).font(.system(size: compact ? 9 : 11, weight: .medium))
                .foregroundStyle(Color.secondary)
            context.draw(title, at: CGPoint(x: inset.frame.midX, y: inset.frame.minY + (compact ? 7 : 13)))
        }
        for township in layout.townships {
            let state = statuses[township.region]?.state ?? .unknown
            context.fill(township.path, with: .color(state.mapColor), style: FillStyle(eoFill: true))
            context.stroke(township.path, with: .color(Color.black.opacity(0.4)),
                           style: TownshipMapOutline.style(width: focusedCounty == nil ? 0.45 : 0.75))
        }
        for boundary in layout.countyLines {
            context.stroke(boundary, with: .color(Color.white.opacity(0.4)), style: TownshipMapOutline.style(width: 1.05))
        }
        // A separate pass keeps outlines visible above every neighboring polygon.
        for township in layout.townships where township.region == home || township.region == work {
            context.stroke(township.path, with: .color(Color(red: 0.43, green: 0.7, blue: 1)), style: TownshipMapOutline.style(width: 2.3))
            context.stroke(township.path, with: .color(Color.white.opacity(0.85)), style: TownshipMapOutline.style(width: 0.8))
        }
        for township in layout.townships where township.region == selectedRegion {
            context.stroke(township.path, with: .color(Color.black.opacity(0.35)), style: TownshipMapOutline.style(width: 4))
            context.stroke(township.path, with: .color(.white), style: TownshipMapOutline.style(width: 2))
        }
        for township in layout.townships where township.region == home || township.region == work {
            guard let point = township.markerPoint else { continue }
            let icons = [township.region == home ? "house.fill" : nil,
                         township.region == work ? "building.2.fill" : nil].compactMap { $0 }
            let width: CGFloat = icons.count == 2 ? 26 : 17
            let badge = Path(roundedRect: CGRect(x: point.x - width / 2, y: point.y - 8.5, width: width, height: 17), cornerRadius: 8.5)
            context.fill(badge, with: .color(Color(red: 0.12, green: 0.34, blue: 0.60)))
            context.stroke(badge, with: .color(Color.white.opacity(0.9)), lineWidth: 0.75)
            for (index, icon) in icons.enumerated() {
                let x = point.x + (CGFloat(index) - CGFloat(icons.count - 1) / 2) * 10
                context.draw(Text(Image(systemName: icon)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white),
                             at: CGPoint(x: x, y: point.y))
            }
        }
    }
}

/// Thick miter joins exaggerate sharp bends into spikes that are not present in
/// the source boundary. Round joins stay within half the line width of the path.
enum TownshipMapOutline {
    static func style(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    static func segments(of path: Path) -> [(CGPoint, CGPoint)] {
        var result: [(CGPoint, CGPoint)] = []
        var first = CGPoint.zero, previous = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let point): first = point; previous = point
            case .line(let point): result.append((previous, point)); previous = point
            case .closeSubpath: result.append((previous, first)); previous = first
            default: break // The geographic path contains straight segments only.
            }
        }
        return result
    }

    static func distanceSquared(_ point: CGPoint, to segment: (CGPoint, CGPoint)) -> CGFloat {
        let dx = segment.1.x - segment.0.x, dy = segment.1.y - segment.0.y
        let squaredLength = dx * dx + dy * dy
        let fraction = squaredLength == 0 ? 0 : min(1, max(0,
            ((point.x - segment.0.x) * dx + (point.y - segment.0.y) * dy) / squaredLength))
        let x = point.x - segment.0.x - fraction * dx
        let y = point.y - segment.0.y - fraction * dy
        return x * x + y * y
    }
}

struct TownshipMapLayout {
    struct Township {
        let region: DisasterRegion
        let path: Path
        let area: CGFloat

        /// A marker must lie inside the township, including concave shapes and
        /// islands. Choose an interior sample with clearance from its edges.
        var markerPoint: CGPoint? {
            let bounds = path.boundingRect
            let segments = TownshipMapOutline.segments(of: path)
            var best: (point: CGPoint, clearance: CGFloat)?
            for row in 0..<15 {
                for column in 0..<15 {
                    let point = CGPoint(x: bounds.minX + bounds.width * (CGFloat(column) + 0.5) / 15,
                                        y: bounds.minY + bounds.height * (CGFloat(row) + 0.5) / 15)
                    guard path.contains(point, eoFill: true) else { continue }
                    let clearance = segments.map { TownshipMapOutline.distanceSquared(point, to: $0) }.min() ?? 0
                    if best == nil || clearance > best!.clearance { best = (point, clearance) }
                }
            }
            return best?.point
        }
    }
    struct Inset {
        let frame: CGRect
        let label: String
    }
    var townships: [Township] = []
    var insets: [Inset] = []
    var countyLines: [Path] = []

    private static let offshoreCounties: Set<String> = ["澎湖縣", "金門縣", "連江縣"]
    // Kaohsiung's official geometry also includes very distant South China Sea
    // islands. Keep those polygons in the catalog, but outside Taiwan's viewport.
    private static let taiwanWindow = CGRect(
        x: 119.8 * cos(23.6 * .pi / 180), y: -25.5,
        width: (122.3 - 119.8) * cos(23.6 * .pi / 180), height: 25.5 - 21.7)

    init(size: CGSize, focusedCounty: String?) {
        guard size.width > 24, size.height > 24 else { return }
        let fullFrame = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14)
        let features = TaiwanTownshipCatalog.features
        if let focusedCounty {
            let county = DisasterRegion.normalize(focusedCounty)
            let selected = features.filter { $0.region.county == county }
            if county == "金門縣", selected.contains(where: { $0.region.district == "烏坵鄉" }) {
                let side = min(88, fullFrame.width * 0.28, fullFrame.height * 0.28)
                let mainFrame = CGRect(x: fullFrame.minX, y: fullFrame.minY + side + 10,
                                       width: fullFrame.width, height: max(1, fullFrame.height - side - 10))
                append(selected.filter { $0.region.district != "烏坵鄉" }, frame: mainFrame, mainlandOnly: false)
                appendInset(selected.filter { $0.region.district == "烏坵鄉" },
                            frame: CGRect(x: fullFrame.minX, y: fullFrame.minY, width: side, height: side),
                            label: "disaster_map_wuqiu")
            } else {
                append(selected, frame: fullFrame, mainlandOnly: !Self.offshoreCounties.contains(county))
            }
            return
        }

        let insetWidth = min(96, max(64, size.width * 0.25))
        let insetHeight = min(108, max(60, (fullFrame.height - 24) / 3))
        let insetX = fullFrame.minX
        let insetTop = fullFrame.midY - (insetHeight * 3 + 24) / 2
        let mainlandFrame = CGRect(x: insetX + insetWidth + 9, y: fullFrame.minY,
                                   width: max(1, fullFrame.width - insetWidth - 9), height: fullFrame.height)
        append(features.filter { !Self.offshoreCounties.contains($0.region.county) }, frame: mainlandFrame, mainlandOnly: true)
        for (index, entry) in [("連江縣", "disaster_map_matsu"), ("金門縣", "disaster_map_kinmen"), ("澎湖縣", "disaster_map_penghu")].enumerated() {
            let frame = CGRect(x: insetX, y: insetTop + CGFloat(index) * (insetHeight + 12), width: insetWidth, height: insetHeight)
            let countyFeatures = features.filter { $0.region.county == entry.0 }
            if entry.0 == "金門縣", countyFeatures.contains(where: { $0.region.district == "烏坵鄉" }) {
                // Wuqiu is a distant township of Kinmen, not a point on its main
                // island. Give it its own labeled viewport instead of relocating it.
                insets.append(Inset(frame: frame, label: entry.1))
                let drawingFrame = frame.insetBy(dx: 6, dy: 6)
                append(countyFeatures.filter { $0.region.district != "烏坵鄉" },
                       frame: CGRect(x: drawingFrame.minX, y: frame.minY + 26,
                                     width: drawingFrame.width, height: max(1, frame.height - 50)), mainlandOnly: false)
                let wuqiuFrame = CGRect(x: frame.maxX - 38, y: frame.maxY - 30, width: 32, height: 24)
                append(countyFeatures.filter { $0.region.district == "烏坵鄉" },
                       frame: CGRect(x: wuqiuFrame.minX + 2, y: wuqiuFrame.minY + 14, width: 28, height: 8), mainlandOnly: false)
                insets.append(Inset(frame: wuqiuFrame, label: "disaster_map_wuqiu"))
            } else {
                appendInset(countyFeatures, frame: frame, label: entry.1)
            }
        }
    }

    private mutating func appendInset(_ features: [TaiwanTownshipCatalog.Feature], frame: CGRect, label: String) {
        insets.append(Inset(frame: frame, label: label))
        append(features, frame: CGRect(x: frame.minX + 7, y: frame.minY + 28,
                                       width: max(1, frame.width - 14), height: max(1, frame.height - 36)), mainlandOnly: false)
    }

    private mutating func append(_ features: [TaiwanTownshipCatalog.Feature], frame: CGRect, mainlandOnly: Bool) {
        let visible = features.map { feature in
            (feature, feature.polygons.filter { !mainlandOnly || $0.bounds.intersects(Self.taiwanWindow) })
        }
        let bounds = visible.flatMap { $0.1 }.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(frame.width / bounds.width, frame.height / bounds.height)
        let offsetX = frame.midX - bounds.midX * scale
        let offsetY = frame.midY - bounds.midY * scale
        let visibleBounds = bounds.insetBy(dx: -0.000001, dy: -0.000001)
        for county in Set(visible.filter { !$0.1.isEmpty }.map { $0.0.region.county }) {
            var outline = Path()
            for segment in TaiwanTownshipCatalog.countyBoundaries[county] ?? [] {
                let start = segment.start.projected, end = segment.end.projected
                guard visibleBounds.contains(start), visibleBounds.contains(end) else { continue }
                outline.move(to: CGPoint(x: start.x * scale + offsetX, y: start.y * scale + offsetY))
                outline.addLine(to: CGPoint(x: end.x * scale + offsetX, y: end.y * scale + offsetY))
            }
            countyLines.append(outline)
        }
        for (feature, polygons) in visible where !polygons.isEmpty {
            var path = Path()
            for polygon in polygons {
                for ring in polygon.rings {
                    for (index, coordinate) in ring.enumerated() {
                        let point = coordinate.projected
                        let mapped = CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY)
                        if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                    }
                    path.closeSubpath()
                }
            }
            let pathBounds = path.boundingRect
            townships.append(Township(region: feature.region, path: path, area: pathBounds.width * pathBounds.height))
        }
    }
}
