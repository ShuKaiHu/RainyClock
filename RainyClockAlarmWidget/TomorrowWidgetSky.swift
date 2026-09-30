import SwiftUI
import WidgetKit

/// The widget's sky: the app's CommuteSky colours and particles, frozen at time 0.
///
/// `.ambient` (small, StandBy) keeps particles quiet and full-bleed so the digits stay
/// readable; `.scene` (medium) draws the card's clouds and rain in the right half, behind
/// the mini weather card (its sun is drawn by the column itself, `ColumnSun`, in the gap
/// its text leaves). Particles are static `Canvas` drawings, never a `TimelineView`, and
/// appear only in full colour.
struct TomorrowSkyBackground: View {
    enum Layout { case ambient, scene }

    let home: TomorrowWidgetSnapshot.Condition?
    let work: TomorrowWidgetSnapshot.Condition?
    let layout: Layout

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var hasWeather: Bool { home != nil || work != nil }
    private var isMixed: Bool { home != work }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                base(size: size)
                if renderingMode == .fullColor && hasWeather {
                    switch layout {
                    case .ambient: ambient
                    case .scene: scene(size: size)
                    }
                }
                // The app's legibility overlay: text sits at the top and bottom.
                LinearGradient(stops: [.init(color: .black.opacity(0.20), location: 0),
                                       .init(color: .black.opacity(0.20), location: 0.30),
                                       .init(color: .clear, location: 0.46),
                                       .init(color: .black.opacity(0.28), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Base colour

    @ViewBuilder
    private func base(size: CGSize) -> some View {
        if !hasWeather {
            ZStack {
                LinearGradient(colors: [SkyPalette.navyTop, SkyPalette.navyBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [SkyPalette.glow.opacity(0.10), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: size.width * 0.9)
            }
        } else if isMixed {
            LinearGradient(stops: [.init(color: SkyPalette.color(home), location: 0.25),
                                   .init(color: SkyPalette.color(work), location: 0.75)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            SkyPalette.color(home)
        }
    }

    // MARK: Ambient (small)

    @ViewBuilder
    private var ambient: some View {
        if isMixed {
            ambientParticles(home)
                .mask(LinearGradient(stops: [.init(color: .white, location: 0.35), .init(color: .clear, location: 0.65)],
                                     startPoint: .leading, endPoint: .trailing))
            ambientParticles(work)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .white, location: 0.65)],
                                     startPoint: .leading, endPoint: .trailing))
        } else {
            ambientParticles(home)
        }
    }

    private func ambientParticles(_ condition: TomorrowWidgetSnapshot.Condition?) -> some View {
        Canvas { context, size in
            switch condition {
            case .clear:
                // A warm halo only: white digits over a yellow disc are unreadable.
                let center = CGPoint(x: size.width * 0.95, y: -size.height * 0.05)
                let radius = size.width * 0.9
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [SkyPalette.halo.opacity(0.30), .clear]),
                                                   center: center, startRadius: 0, endRadius: radius))
            case .rain:
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.20)),
                             with: .linearGradient(Gradient(colors: [SkyPalette.rainCloud.opacity(0.25), .clear]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.20)))
                for index in 0..<28 {
                    SkyParticles.streak(index: index, in: &context, size: size, color: SkyPalette.ambientStreak,
                                        opacity: 0.22 + Double(index % 3) * 0.08)
                }
            case .cloudy:
                for index in 0..<3 {
                    let scale: CGFloat = 0.6
                    let width = (90 + CGFloat(index % 2) * 50) * scale
                    let x = size.width * (0.04 + CGFloat(index) * 0.34) + CGFloat(sin(Double(index) * 1.7)) * 8
                    let y = size.height * (0.72 + CGFloat(index % 2) * 0.06) + 25 * scale
                    context.fill(SkyParticles.cloud(x: x, y: y, width: width, scale: scale),
                                 with: .color(SkyPalette.cloudLight.opacity(0.18)))
                }
            case nil:
                break
            }
        }
    }

    // MARK: Scene (medium)

    private func scene(size: CGSize) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: size.width * 0.5)
            ZStack {
                if isMixed {
                    sceneParticles(home, center: 0.24)
                        .mask(LinearGradient(stops: [.init(color: .white, location: 0.35), .init(color: .clear, location: 0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                    sceneParticles(work, center: 0.76)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .white, location: 0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                } else {
                    // 0.48 of the right half is 0.74 of the widget.
                    sceneParticles(home, center: 0.48)
                }
            }
            .frame(width: size.width * 0.5)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.40), .init(color: .white, location: 0.55)],
                             startPoint: .leading, endPoint: .trailing))
    }

    /// CommuteSky's particles at time 0.
    private func sceneParticles(_ condition: TomorrowWidgetSnapshot.Condition?, center: CGFloat) -> some View {
        Canvas { context, size in
            switch condition {
            case .clear:
                // No sun here: the medium's weather column draws it in its own gap between the
                // top row and the endpoint names (`ColumnSun`). A band guessed from the widget's
                // height cannot follow that layout; the  Weather row pushed the names up into
                // the old one (0.22h–0.54h), and its rays crossed 晴天 / Sunny.
                break
            case .cloudy:
                SkyParticles.clouds(in: &context, size: size, rain: false)
            case .rain:
                SkyParticles.clouds(in: &context, size: size, rain: true)
                for index in 0..<42 {
                    SkyParticles.streak(index: index, in: &context, size: size, color: SkyPalette.sceneStreak,
                                        opacity: 0.34 + Double(index % 3) * 0.10)
                }
            case nil:
                break
            }
        }
    }
}

/// CommuteSky's colours (CommuteWeatherCard.swift), plus the widget's brand navy.
enum SkyPalette {
    static let clear = Color(red: 0.07, green: 0.49, blue: 0.77)       // #127DC4
    static let cloudy = Color(red: 0.40, green: 0.42, blue: 0.45)      // #666B73
    static let rain = Color(red: 0.23, green: 0.16, blue: 0.39)        // #3B2963
    static let navyTop = Color(red: 0x1A / 255, green: 0x24 / 255, blue: 0x33 / 255)
    static let navyBottom = Color(red: 0x0F / 255, green: 0x16 / 255, blue: 0x24 / 255)
    static let glow = Color(red: 0x6E / 255, green: 0xE3 / 255, blue: 0xFD / 255)
    static let halo = Color(red: 1, green: 0xB0 / 255, blue: 0x2E / 255)          // #FFB02E
    static let ambientStreak = Color(red: 0xCC / 255, green: 0xBF / 255, blue: 1)  // #CCBFFF
    static let sceneStreak = Color(red: 0.80, green: 0.75, blue: 1)
    static let rainCloud = Color(red: 0.62, green: 0.54, blue: 0.80)             // #9E8ACC
    static let cloudLight = Color(red: 0.96, green: 0.96, blue: 0.97)            // #F5F5F7
    static let closure = Color(red: 0xE7 / 255, green: 0x79 / 255, blue: 0x78 / 255) // #E77978

    static func color(_ condition: TomorrowWidgetSnapshot.Condition?) -> Color {
        switch condition {
        case .clear: clear
        case .cloudy: cloudy
        case .rain: rain
        case nil: navyTop
        }
    }
}

/// CommuteSky's drawing routines with `time` fixed at 0.
enum SkyParticles {
    static func streak(index: Int, in context: inout GraphicsContext, size: CGSize, color: Color, opacity: Double) {
        let seed = Double(index)
        let x = (seed * 0.6180339).truncatingRemainder(dividingBy: 1) * size.width
        let progress = (seed * 0.137).truncatingRemainder(dividingBy: 1)
        let y = progress * (size.height + 40) - 20
        let length = CGFloat(11 + index % 10)
        var drop = Path()
        drop.move(to: CGPoint(x: x, y: y))
        drop.addLine(to: CGPoint(x: x - 3, y: y + length))
        context.stroke(drop, with: .color(color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: index % 3 == 0 ? 1.7 : 0.95, lineCap: .round))
    }

    static func cloud(x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat = 1) -> Path {
        var cloud = Path()
        cloud.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: 25 * scale),
                             cornerSize: CGSize(width: 13 * scale, height: 13 * scale))
        cloud.addEllipse(in: CGRect(x: x + width * 0.15, y: y - 14 * scale, width: 42 * scale, height: 40 * scale))
        cloud.addEllipse(in: CGRect(x: x + width * 0.43, y: y - 25 * scale, width: 53 * scale, height: 50 * scale))
        return cloud
    }

    static func clouds(in context: inout GraphicsContext, size: CGSize, rain: Bool) {
        for index in 0..<5 {
            let drift = sin(Double(index) * 1.7) * 32
            let x = size.width * CGFloat(index) / 4 + drift - 35
            let y = size.height * (rain ? 0.40 : 0.45) + CGFloat(index % 3) * 20
            let width: CGFloat = 90 + CGFloat(index % 2) * 50
            let color = rain ? SkyPalette.rainCloud : SkyPalette.cloudLight
            context.fill(cloud(x: x, y: y, width: width), with: .color(color.opacity(rain ? 0.25 : 0.28)))
        }
    }

    /// Where the card's rays end, at scale 1.
    static let sunOuterRadius: CGFloat = 50

    /// The card's sun at `scale` 1 and `centerY` 0.49; the widget passes both.
    static func sun(in context: inout GraphicsContext, size: CGSize, center: CGFloat,
                    centerY: CGFloat = 0.49, scale: CGFloat = 1) {
        let point = CGPoint(x: size.width * center, y: size.height * centerY)
        let radius: CGFloat = 28 * scale
        let glowRadius: CGFloat = 66 * scale
        let rayStart: CGFloat = 36 * scale
        let rayEnd: CGFloat = sunOuterRadius * scale
        let glow = Path(ellipseIn: CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                          width: glowRadius * 2, height: glowRadius * 2))
        context.fill(glow, with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.69, blue: 0.18).opacity(0.20), .clear]),
                                                 center: point, startRadius: radius * 0.6, endRadius: glowRadius))
        var rays = Path()
        for index in 0..<12 {
            let angle = Double(index) * .pi / 6
            rays.move(to: CGPoint(x: point.x + cos(angle) * rayStart, y: point.y + sin(angle) * rayStart))
            rays.addLine(to: CGPoint(x: point.x + cos(angle) * rayEnd, y: point.y + sin(angle) * rayEnd))
        }
        context.stroke(rays, with: .color(Color(red: 1, green: 0.80, blue: 0.35).opacity(0.92)),
                       style: StrokeStyle(lineWidth: max(1.4, 2.2 * scale), lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.87, blue: 0.46), Color(red: 1, green: 0.64, blue: 0.12)]),
                                           center: point, startRadius: 0, endRadius: radius))
    }
}
