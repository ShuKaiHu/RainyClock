import CoreLocation
import Foundation
import MapKit

enum RoutePolylineSampler {
    static func sampleCoordinates(from polyline: MKPolyline, maximumCount: Int = 5) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0, maximumCount > 0 else {
            return []
        }

        var coordinates = Array(repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))

        guard coordinates.count > maximumCount else {
            return coordinates
        }

        let lastIndex = coordinates.count - 1
        return (0..<maximumCount).map { sampleIndex in
            let position = Double(sampleIndex) * Double(lastIndex) / Double(maximumCount - 1)
            return coordinates[Int(position.rounded())]
        }
    }
}
