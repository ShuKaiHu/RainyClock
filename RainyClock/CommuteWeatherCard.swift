import SwiftUI

/// One sky for the commute. Endpoint forecasts remain separate from the route's
/// maximum rain probability, which is what the alarm decision uses.
struct CommuteWeatherCard: View {
    let weather: RouteWeatherSnapshot?
    let homeAddress: String
    let workAddress: String
    let mode: CommuteAlarmSettings.CommuteMode
    var compact = false
    var isActive = true
    var isLoading = false
    var notice: String?
    var hasError = false
    var showsWeatherAttribution = false
    let openRoute: () -> Void
    let retry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var home: RouteWeatherSegment? { weather?.segments.first }
    // A partial response must not duplicate Home's forecast as Work's weather.
    private var work: RouteWeatherSegment? {
        guard let segments = weather?.segments, segments.count >= 2 else { return nil }
        return segments.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                Text("ux_tomorrow_weather").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: 22) {
                    place("ux_weather_home", address: homeAddress, alignment: .leading)
                    place("ux_weather_work", address: workAddress, alignment: .trailing)
                }.padding(.top, compact ? 17 : 22)
                ZStack {
                    Color.clear
                    if weather == nil && isLoading {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white.opacity(0.75))
                            Text("ux_weather_fetching").font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }.frame(height: compact ? 58 : 88)
                HStack(alignment: .bottom) {
                    forecast(home, alignment: .leading)
                    Spacer(minLength: 18)
                    forecast(work, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 1)
                    Button(action: openRoute) {
                        HStack(spacing: 10) {
                            Label(mode.displayName, systemImage: modeIcon).font(.caption.weight(.medium))
                                .fixedSize().foregroundStyle(.white.opacity(0.88))
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 4).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("ux_weather_open_route"))
                    Capsule().fill(.white.opacity(0.18)).frame(height: 1)
                }.padding(.top, compact ? 0 : 4)
            }
            .foregroundStyle(.white)
            .padding(compact ? 18 : 22)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                CommuteSky(home: home?.condition, work: work?.condition,
                           animates: isActive && scenePhase == .active && !reduceMotion)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }

            if let notice, !(weather == nil && isLoading && !hasError) {
                HStack(alignment: .center, spacing: 8) {
                    if isLoading { ProgressView().controlSize(.mini) }
                    else if hasError { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text(notice).font(.caption).foregroundStyle(hasError ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if hasError {
                        Button("ux_retry", action: retry).font(.caption.weight(.semibold))
                            .frame(minHeight: 32).disabled(isLoading)
                    }
                }.padding(.horizontal, 5)
            }
            if showsWeatherAttribution && weather != nil {
                WeatherAttributionView().padding(.horizontal, 5)
            }
        }
    }

    private func place(_ title: LocalizedStringKey, address: String, alignment: HorizontalAlignment) -> some View {
        Button(action: openRoute) {
            VStack(alignment: alignment, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(address.isEmpty ? String(localized: "ux_weather_set_address") : address)
                    .font(.caption).foregroundStyle(.white.opacity(0.90))
                    .lineLimit(2).multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .frame(minHeight: 32, alignment: .top)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("ux_weather_open_route"))
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func forecast(_ segment: RouteWeatherSegment?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 7) {
            Text(conditionTitle(segment?.condition))
                .font(.system(compact ? .title3 : .title2, design: .rounded, weight: .medium))
            if let segment {
                Label(String.localizedStringWithFormat(String(localized: "ux_rain_chance"),
                                                       Int((segment.precipitationProbability * 100).rounded())),
                      systemImage: "drop.fill")
                    .font(.caption).foregroundStyle(.white.opacity(0.90))
            } else {
                Text("—").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func conditionTitle(_ condition: RouteWeatherSegment.Condition?) -> String {
        switch condition {
        case .clear: String(localized: "ux_weather_clear")
        case .cloudy: String(localized: "ux_weather_cloudy")
        case .rain: String(localized: "ux_weather_rain")
        case nil: "—"
        }
    }

    private var modeIcon: String {
        switch mode {
        case .car: "car.fill"
        case .scooter: "scooter"
        case .walking: "figure.walk"
        case .publicTransit: "tram.fill"
        }
    }
}

private struct CommuteSky: View {
    let home: RouteWeatherSegment.Condition?
    let work: RouteWeatherSegment.Condition?
    let animates: Bool
    private var isMixed: Bool { home != work }

    var body: some View {
        ZStack {
            if isMixed {
                LinearGradient(stops: [.init(color: color(home), location: 0.25),
                                       .init(color: color(work), location: 0.75)],
                               startPoint: .leading, endPoint: .trailing)
            } else { color(home) }
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animates || (home == nil && work == nil))) { timeline in
                // Freeze to a deterministic still under Reduce Motion/inactive scenes.
                let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0
                if isMixed {
                    particles(home, time: time, center: 0.24)
                        .mask(LinearGradient(stops: [.init(color: .white, location: 0.35), .init(color: .clear, location: 0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                    particles(work, time: time, center: 0.76)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .white, location: 0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                } else { particles(home, time: time, center: 0.5) }
            }
            // Keep the text legible while leaving the central sky clear and saturated.
            LinearGradient(stops: [.init(color: .black.opacity(0.20), location: 0),
                                   .init(color: .black.opacity(0.20), location: 0.30),
                                   .init(color: .clear, location: 0.46),
                                   .init(color: .black.opacity(0.28), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func color(_ condition: RouteWeatherSegment.Condition?) -> Color {
        switch condition {
        case .clear: Color(red: 0.07, green: 0.49, blue: 0.77)
        case .cloudy: Color(red: 0.40, green: 0.42, blue: 0.45)
        case .rain: Color(red: 0.23, green: 0.16, blue: 0.39)
        case nil: Color(red: 0.10, green: 0.14, blue: 0.20)
        }
    }

    private func particles(_ condition: RouteWeatherSegment.Condition?, time: Double, center: CGFloat) -> some View {
        Canvas { context, size in
            switch condition {
            case .clear:
                sun(context: &context, size: size, time: time, center: center)
            case .cloudy:
                clouds(context: &context, size: size, time: time, rain: false)
            case .rain:
                clouds(context: &context, size: size, time: time, rain: true)
                for index in 0..<42 {
                    let seed = Double(index)
                    let x = (seed * 0.6180339).truncatingRemainder(dividingBy: 1) * size.width
                    let progress = (time * (0.48 + Double(index % 3) * 0.08) + seed * 0.137)
                        .truncatingRemainder(dividingBy: 1)
                    let y = progress * (size.height + 40) - 20
                    let length = CGFloat(11 + index % 10)
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: y))
                    drop.addLine(to: CGPoint(x: x - 3, y: y + length))
                    context.stroke(drop, with: .color(.init(red: 0.80, green: 0.75, blue: 1).opacity(0.34 + Double(index % 3) * 0.10)),
                                   style: StrokeStyle(lineWidth: index % 3 == 0 ? 1.7 : 0.95, lineCap: .round))
                }
            case nil: break
            }
        }
    }

    private func sun(context: inout GraphicsContext, size: CGSize, time: Double, center: CGFloat) {
        let point = CGPoint(x: size.width * center, y: size.height * 0.49)
        let radius: CGFloat = 28
        let pulse = 1 + sin(time * 0.7) * 0.06
        // A close, warm halo keeps the sunshine crisp instead of tinting the sky like haze.
        let glowRadius: CGFloat = 66
        let glow = Path(ellipseIn: CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                       width: glowRadius * 2, height: glowRadius * 2))
        context.fill(glow, with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.69, blue: 0.18).opacity(0.20 * pulse), .clear]),
                                               center: point, startRadius: radius * 0.6, endRadius: glowRadius))
        var rays = Path()
        for index in 0..<12 {
            let angle = Double(index) * .pi / 6 + time * 0.10
            rays.move(to: CGPoint(x: point.x + cos(angle) * 36, y: point.y + sin(angle) * 36))
            rays.addLine(to: CGPoint(x: point.x + cos(angle) * 50, y: point.y + sin(angle) * 50))
        }
        context.stroke(rays, with: .color(Color(red: 1, green: 0.80, blue: 0.35).opacity(0.92)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.87, blue: 0.46), Color(red: 1, green: 0.64, blue: 0.12)]),
                                           center: point, startRadius: 0, endRadius: radius))
    }

    private func clouds(context: inout GraphicsContext, size: CGSize, time: Double, rain: Bool) {
        for index in 0..<5 {
            let drift = sin(time * 0.24 + Double(index) * 1.7) * 32
            let x = size.width * CGFloat(index) / 4 + drift - 35
            let y = size.height * (rain ? 0.40 : 0.45) + CGFloat(index % 3) * 20
            let width: CGFloat = 90 + CGFloat(index % 2) * 50
            var cloud = Path()
            cloud.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: 25), cornerSize: CGSize(width: 13, height: 13))
            cloud.addEllipse(in: CGRect(x: x + width * 0.15, y: y - 14, width: 42, height: 40))
            cloud.addEllipse(in: CGRect(x: x + width * 0.43, y: y - 25, width: 53, height: 50))
            let cloudColor = rain ? Color(red: 0.62, green: 0.54, blue: 0.80) : Color(red: 0.96, green: 0.96, blue: 0.97)
            context.fill(cloud, with: .color(cloudColor.opacity(rain ? 0.25 : 0.28)))
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Separate visual harness: no real settings, notifications, or synthetic cache writes.
struct CommuteWeatherPreviewHost: View {
    private let args = ProcessInfo.processInfo.arguments
    private var isLoading: Bool { args.contains("-weather-loading") }
    private func conditionArgument(_ name: String) -> RouteWeatherSegment.Condition? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return RouteWeatherSegment.Condition(rawValue: args[index + 1])
    }
    private var snapshot: RouteWeatherSnapshot? {
        if args.contains("-weather-empty") || isLoading { return nil }
        let home = conditionArgument("-weather-home")
            ?? (args.contains("-weather-rain") ? .rain : (args.contains("-weather-cloudy") ? .cloudy : .clear))
        let work = conditionArgument("-weather-work") ?? (args.contains("-weather-same") ? home : .rain)
        return RouteWeatherSnapshot(checkedAt: Date(), forecastAt: Date(), segments: [
            .init(name: "Home", condition: home, precipitationProbability: home == .rain ? 0.8 : 0.1),
            .init(name: "Work", condition: work, precipitationProbability: work == .rain ? 0.9 : 0.1)
        ])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Weather visual preview · sample data").font(.caption).foregroundStyle(.orange)
            Text("tab_alarm").font(.largeTitle.bold())
            CommuteWeatherCard(weather: snapshot, homeAddress: "臺南市善化區", workAddress: "臺南市安定區", mode: .car,
                               isLoading: isLoading,
                               notice: snapshot == nil ? String(localized: isLoading ? "ux_tomorrow_weather_loading" : "ux_tomorrow_weather_failed") : nil,
                               hasError: snapshot == nil && !isLoading, openRoute: {}, retry: {})
            Spacer()
        }.padding(20).background(Color.black).preferredColorScheme(.dark)
    }
}
#endif
