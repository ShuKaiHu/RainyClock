import SwiftUI
import WeatherKit

struct WeatherAttributionView: View {
    @State private var attribution: WeatherAttribution?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let attribution {
                Link(destination: attribution.legalPageURL) {
                    AsyncImage(url: markURL(for: attribution)) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(height: 16)
                    } placeholder: {
                        Text(verbatim: attribution.serviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(verbatim: "Apple Weather")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            attribution = try? await WeatherService.shared.attribution
        }
    }

    private func markURL(for attribution: WeatherAttribution) -> URL {
        colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
    }
}
