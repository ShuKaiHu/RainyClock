import MapKit
import SwiftUI

struct RoutePreviewMapView: View {
    let preview: RoutePreview
    @State private var position: MapCameraPosition

    init(preview: RoutePreview) {
        self.preview = preview
        _position = State(initialValue: .rect(preview.route.polyline.boundingMapRect.paddedForDisplay))
    }

    var body: some View {
        Map(position: $position) {
            Marker(String(localized: "route_preview_home_pin"), coordinate: preview.homeCoordinate)
                .tint(.blue)
            Marker(String(localized: "route_preview_work_pin"), coordinate: preview.workCoordinate)
                .tint(.orange)
            MapPolyline(preview.route.polyline)
                .stroke(.blue, lineWidth: 5)
        }
        .frame(minHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }
}

private extension MKMapRect {
    var paddedForDisplay: MKMapRect {
        let minimumSize: Double = 1_500
        let normalizedWidth = max(size.width, minimumSize)
        let normalizedHeight = max(size.height, minimumSize)
        let normalized = MKMapRect(
            x: midX - normalizedWidth / 2,
            y: midY - normalizedHeight / 2,
            width: normalizedWidth,
            height: normalizedHeight
        )

        return normalized.insetBy(
            dx: -normalized.size.width * 0.22,
            dy: -normalized.size.height * 0.22
        )
    }
}
