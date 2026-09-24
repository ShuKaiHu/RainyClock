import SwiftUI
import WidgetKit

/// Renders `TomorrowWidgetPresentation`; every display rule lives there.
///
/// Every string is built first (`LocalizedLine.resolve`) and rendered with
/// `Text(verbatim:)`, and every time goes through the app's `ClockTimeFormat` in the
/// extension's own localization, so the 12/24-hour setting and 上午-first ordering
/// match the app. `Text(date, style: .time)` would ignore both.
struct TomorrowWidgetView: View {
    let entry: TomorrowWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let presentation = TomorrowWidgetPresentation(entry.state)
        let style = WidgetStyle(entry: entry, fullColor: renderingMode == .fullColor, family: family)
        Group {
            switch family {
            case .systemMedium:
                MediumTomorrowView(entry: entry, presentation: presentation, style: style)
                    .containerBackground(for: .widget) {
                        TomorrowSkyBackground(home: presentation.home, work: presentation.work, layout: .scene)
                    }
            case .accessoryRectangular:
                RectangularTomorrowView(entry: entry, presentation: presentation, style: style)
                    .containerBackground(for: .widget) { Color.clear }
            case .accessoryCircular:
                CircularTomorrowView(entry: entry, presentation: presentation, style: style)
                    .containerBackground(for: .widget) { Color.clear }
            case .accessoryInline:
                InlineTomorrowView(entry: entry, presentation: presentation, style: style)
                    .containerBackground(for: .widget) { Color.clear }
            default:
                SmallTomorrowView(entry: entry, presentation: presentation, style: style)
                    .containerBackground(for: .widget) {
                        TomorrowSkyBackground(home: presentation.home, work: presentation.work, layout: .ambient)
                    }
            }
        }
        // White ink over the sky in full colour; the system's own scheme otherwise.
        .environment(\.colorScheme, style.fullColor ? .dark : systemColorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: style.accessibilityLabel(presentation)))
    }

    @Environment(\.colorScheme) private var systemColorScheme
}

// MARK: - Shared style

/// Locale, ink and the strings every family shares.
struct WidgetStyle {
    let entry: TomorrowWidgetEntry
    let fullColor: Bool
    let family: WidgetFamily
    /// Dates and times follow the language the text resolves in, never the region alone.
    let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    var isChinese: Bool { locale.language.languageCode?.identifier == "zh" }

    // Ink: explicit white over the sky in full colour; hierarchical styles when the
    // system tints or makes the widget vibrant.
    var primary: AnyShapeStyle { fullColor ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary) }
    var secondary: AnyShapeStyle { fullColor ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary) }
    var tertiary: AnyShapeStyle { fullColor ? AnyShapeStyle(Color.white.opacity(0.65)) : AnyShapeStyle(.tertiary) }
    var quaternary: AnyShapeStyle { fullColor ? AnyShapeStyle(Color.white.opacity(0.5)) : AnyShapeStyle(.quaternary) }
    /// Orange only in full colour.
    var warning: AnyShapeStyle { fullColor ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary) }

    func text(_ key: String) -> String { LocalizedLine(key: key).resolve() }
    func text(_ line: LocalizedLine) -> String { line.resolve() }

    func parts(_ date: Date) -> ClockTimeFormat.Parts { entry.clockFormat.parts(date, locale: locale) }
    func time(_ date: Date) -> String { entry.clockFormat.time(date, locale: locale) }

    func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    /// The card's header format: 9月24日 週三 / Wed, Sep 24.
    func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated).locale(locale))
    }

    /// 明天 · 週三 / Tomorrow · Wed
    func smallHeader(_ presentation: TomorrowWidgetPresentation) -> String {
        guard let day = presentation.day else { return text("app_title") }
        return text("ux_tomorrow") + " · " + weekday(day)
    }

    /// The small header's fallback where a leading symbol leaves no room: 明天 / Tomorrow.
    func smallHeaderShort(_ presentation: TomorrowWidgetPresentation) -> String {
        text(presentation.day == nil ? "app_title" : "ux_tomorrow")
    }

    /// 明天 9月24日 週三 / Tomorrow · Wed, Sep 24: English sets the word apart from a date
    /// that carries its own comma. VoiceOver passes ", " so it never reads the dot.
    func mediumHeader(_ presentation: TomorrowWidgetPresentation, separator: String = " · ") -> String {
        guard let day = presentation.day else { return text("app_title") }
        return text("ux_tomorrow") + (isChinese ? " " : separator) + longDate(day)
    }

    func openAppText(_ reason: TomorrowWidgetTimeline.NeedsApp) -> String {
        text(reason == .missing ? "widget_open_to_start" : "widget_open_to_refresh")
    }

    func modeSymbol(_ mode: TomorrowWidgetSnapshot.CommuteMode) -> String {
        switch mode {
        case .car: "car.fill"
        case .scooter: "scooter"
        case .walking: "figure.walk"
        case .publicTransit: "tram.fill"
        }
    }

    func modeName(_ mode: TomorrowWidgetSnapshot.CommuteMode) -> String {
        switch mode {
        case .car: text("commute_mode_car")
        case .scooter: text("commute_mode_scooter")
        case .walking: text("commute_mode_walking")
        case .publicTransit: text("commute_mode_public_transit")
        }
    }

    func conditionName(_ condition: TomorrowWidgetSnapshot.Condition) -> String {
        switch condition {
        case .clear: text("ux_weather_clear")
        case .cloudy: text("ux_weather_cloudy")
        case .rain: text("ux_weather_rain")
        }
    }

    /// One label for the whole widget: header, expected ring (or the hero), footer.
    func accessibilityLabel(_ presentation: TomorrowWidgetPresentation) -> String {
        var pieces = [mediumHeader(presentation, separator: ", ")]
        switch presentation.hero {
        case .time(let ring, _):
            var piece = text("ux_expected_ring") + " " + time(ring)
            // Rain moved the ring across midnight: the header's day is not the ring's.
            if case .on(let ringDay)? = presentation.ringDay { piece += " " + longDate(ringDay) }
            pieces.append(piece)
        case .skipped: pieces.append(text("ux_tomorrow_skipped"))
        case .notSet: pieces.append(text("ux_not_set"))
        case .openApp(let reason): pieces.append(openAppText(reason))
        }
        if let line = presentation.line { pieces.append(text(line.full)) }
        return pieces.joined(separator: isChinese ? "，" : ", ")
    }
}

// MARK: - Building blocks

private struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// Digits and day period, sized separately; the period moves above the digits
/// when the row does not fit.
private struct HeroTime: View {
    let parts: ClockTimeFormat.Parts
    let digitSize: CGFloat
    let style: WidgetStyle

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if parts.periodLeads, let period = parts.period { periodText(period) }
                digits
                if !parts.periodLeads, let period = parts.period { periodText(period) }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let period = parts.period { periodText(period) }
                digits
            }
        }
    }

    private var digits: some View {
        Text(verbatim: parts.clock)
            .font(.system(size: digitSize, weight: .medium, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(style.primary)
            .widgetAccentable()
    }

    private func periodText(_ period: String) -> some View {
        Text(verbatim: period)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(style.secondary)
            .lineLimit(1)
    }
}

/// The footer line: its symbol (orange for a warning in full colour), text in quiet ink.
private struct LineView: View {
    let line: TomorrowWidgetPresentation.Line
    let text: String
    let style: WidgetStyle

    var body: some View {
        if let symbol = line.leadingSymbol {
            Label {
                Text(verbatim: text).foregroundStyle(style.secondary)
            } icon: {
                Image(systemName: symbol)
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .foregroundStyle(line.isWarning ? style.warning : style.secondary)
            }
            .labelStyle(TightLabelStyle())
        } else {
            Text(verbatim: text).foregroundStyle(style.secondary)
        }
    }
}

/// A footer of at most `lines` lines: the full text at the footer's size, else the full
/// text one step smaller, else the short text (shrunk, then tail-truncated, as the last
/// resort). ViewThatFits judges each option by its unlimited height, so a hidden
/// `lines`-line placeholder of the same view bounds the height it may use; a line limit
/// on the options themselves would make every one of them "fit".
private struct FittedLineView: View {
    let line: TomorrowWidgetPresentation.Line
    let style: WidgetStyle
    var lines = 2

    var body: some View {
        let full = style.text(line.full)
        let short = style.text(line.short)
        LineView(line: line, text: Array(repeating: "Ag", count: lines).joined(separator: "\n"), style: style)
            .lineLimit(lines)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                ViewThatFits(in: .vertical) {
                    LineView(line: line, text: full, style: style).lineLimit(nil)
                    LineView(line: line, text: full, style: style).lineLimit(nil).font(.caption2)
                    LineView(line: line, text: short, style: style).lineLimit(lines).minimumScaleFactor(0.85)
                }
            }
    }
}

/// The state glyph, with a small warning badge when a warning is not the footer.
private struct GlyphBadge: View {
    let glyph: TomorrowWidgetPresentation.Glyph
    let showsBadge: Bool
    let style: WidgetStyle
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: glyph.rawValue)
            .widgetAccentedRenderingMode(.accentedDesaturated)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(glyph == .closure && style.fullColor ? AnyShapeStyle(SkyPalette.closure) : style.primary)
            .widgetAccentable()
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    Image(systemName: TomorrowWidgetPresentation.Glyph.warning.rawValue)
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(style.warning)
                        .offset(x: 4, y: 3)
                }
            }
    }
}

/// StandBy drops the sky; the header then carries the home condition, and gives up
/// the weekday rather than truncate beside it.
private struct HeaderText: View {
    let text: String
    let short: String
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        HStack(spacing: 4) {
            if !showsBackground, let symbol = presentation.standByConditionSymbol {
                Image(systemName: symbol).widgetAccentedRenderingMode(.accentedDesaturated)
            }
            ViewThatFits(in: .horizontal) {
                Text(verbatim: text).lineLimit(1)
                Text(verbatim: short).lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(style.secondary)
    }
}

// MARK: - systemSmall (also StandBy)

private struct SmallTomorrowView: View {
    let entry: TomorrowWidgetEntry
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HeaderText(text: style.smallHeader(presentation), short: style.smallHeaderShort(presentation),
                           presentation: presentation, style: style)
                Spacer(minLength: 4)
                GlyphBadge(glyph: presentation.glyph, showsBadge: presentation.showsWarningBadge, style: style)
            }
            Spacer(minLength: 2)
            SmallHero(presentation: presentation, style: style, digitSize: 44)
            Spacer(minLength: 2)
            if let line = presentation.line {
                FittedLineView(line: line, style: style).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SmallHero: View {
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle
    let digitSize: CGFloat

    var body: some View {
        switch presentation.hero {
        case .time(let ring, _):
            VStack(alignment: .leading, spacing: 0) {
                HeroTime(parts: style.parts(ring), digitSize: digitSize, style: style)
                if presentation.ringIsOnAnotherDay {
                    Text(verbatim: style.longDate(ring))
                        .font(.caption2)
                        .foregroundStyle(style.tertiary)
                        .lineLimit(1)
                }
            }
        case .skipped:
            Text(verbatim: style.text("ux_tomorrow_skipped"))
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(style.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .notSet:
            Text(verbatim: style.text("ux_not_set"))
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(style.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        case .openApp(let reason):
            // Nothing else is on this face, so it may take three lines: the English
            // "missing" copy needs them on every iPhone (two suffice in zh-Hant).
            Text(verbatim: style.openAppText(reason))
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(style.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
        }
    }
}

// MARK: - systemMedium

private struct MediumTomorrowView: View {
    let entry: TomorrowWidgetEntry
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle

    private var status: TomorrowWidgetSnapshot.Entry? {
        if case .status(let status) = entry.state { return status }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            left.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let status {
                weatherColumn(status).frame(width: 148)
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                if style.isChinese {
                    // 明天 and the date: shrinks a little rather than drop the date.
                    Text(verbatim: style.mediumHeader(presentation))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    // Gives up the month and day before it would truncate.
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: style.mediumHeader(presentation)).lineLimit(1)
                        Text(verbatim: style.smallHeader(presentation))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            } icon: {
                GlyphBadge(glyph: presentation.glyph, showsBadge: presentation.showsWarningBadge, style: style, size: 13)
            }
            .labelStyle(TightLabelStyle(spacing: 5))
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.secondary)
            Spacer(minLength: 2)
            SmallHero(presentation: presentation, style: style, digitSize: 46)
            if case .time(_, let original?) = presentation.hero {
                Label {
                    Text(verbatim: style.time(original))
                } icon: {
                    Image(systemName: "alarm").widgetAccentedRenderingMode(.accentedDesaturated)
                }
                .labelStyle(TightLabelStyle(spacing: 3))
                .font(.caption2)
                .foregroundStyle(style.tertiary)
            }
            Spacer(minLength: 2)
            // Never the weather notice: the weather column beside it already says that.
            if let line = presentation.mediumLine {
                FittedLineView(line: line, style: style).font(.caption)
            }
        }
    }

    /// A mini weather card without addresses; skipped days still show tomorrow's weather.
    private func weatherColumn(_ status: TomorrowWidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                // The rules are the flexible part; the endpoint names must never truncate.
                Text(verbatim: style.text("ux_weather_home")).fixedSize()
                Capsule().fill(style.fullColor ? AnyShapeStyle(Color.white.opacity(0.35)) : AnyShapeStyle(.tertiary))
                    .frame(height: 1)
                Image(systemName: style.modeSymbol(entry.mode))
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .font(.caption2)
                    .foregroundStyle(style.fullColor ? AnyShapeStyle(Color.white.opacity(0.88)) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(Text(verbatim: style.modeName(entry.mode)))
                Capsule().fill(style.fullColor ? AnyShapeStyle(Color.white.opacity(0.35)) : AnyShapeStyle(.tertiary))
                    .frame(height: 1)
                Text(verbatim: style.text("ux_weather_work")).fixedSize()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.primary)
            .lineLimit(1)
            Spacer(minLength: 4)
            HStack(alignment: .bottom) {
                endpoint(status.forecast?.home, alignment: .leading)
                Spacer(minLength: 4)
                endpoint(status.forecast?.work, alignment: .trailing)
            }
            weatherFooter(status)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)
        }
    }

    private func endpoint(_ endpoint: TomorrowWidgetSnapshot.Endpoint?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let endpoint {
                Text(verbatim: style.conditionName(endpoint.condition))
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                Label {
                    Text(verbatim: style.text(LocalizedLine(key: "ux_rain_chance", arguments: [.int(endpoint.percent)])))
                } icon: {
                    Image(systemName: "drop.fill").widgetAccentedRenderingMode(.accentedDesaturated)
                }
                .labelStyle(TightLabelStyle(spacing: 2))
                .font(.caption2)
                .foregroundStyle(style.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                Text(verbatim: "—")
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(style.quaternary)
            }
        }
    }

    @ViewBuilder
    private func weatherFooter(_ status: TomorrowWidgetSnapshot.Entry) -> some View {
        if let notice = status.weatherNotice {
            let line = TomorrowWidgetPresentation.Line.notice(notice)
            ViewThatFits(in: .horizontal) {
                LineView(line: line, text: style.text(line.full), style: style)
                LineView(line: line, text: style.text(line.short), style: style)
            }
        } else if let forecast = status.forecast {
            Text(verbatim: style.text(LocalizedLine(key: "ux_weather_updated", arguments: [.string(style.time(forecast.checkedAt))])))
                .foregroundStyle(style.tertiary)
        }
    }
}

// MARK: - accessoryRectangular

private struct RectangularTomorrowView: View {
    let entry: TomorrowWidgetEntry
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .openApp(let reason) = presentation.hero {
                Label(style.text("app_title"), systemImage: TomorrowWidgetPresentation.Glyph.refresh.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .widgetAccentable()
                    .lineLimit(1)
                // The hero row is empty in this state, so the message may wrap once.
                Text(verbatim: style.openAppText(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Label(header, systemImage: presentation.hasIssue ? TomorrowWidgetPresentation.Glyph.warning.rawValue
                                                                  : presentation.glyph.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .widgetAccentable()
                    .lineLimit(1)
                hero
                if let line = presentation.line {
                    ViewThatFits(in: .horizontal) {
                        LineView(line: line, text: style.text(line.full), style: style)
                        LineView(line: line, text: style.text(line.short), style: style)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 明天 週三 / Tomorrow · Wed, or the ring's own date when rain moved it across
    /// midnight: the time below is then not on tomorrow.
    private var header: String {
        if case .on(let ringDay)? = presentation.ringDay { return style.longDate(ringDay) }
        guard let day = presentation.day else { return style.text("app_title") }
        return style.text("ux_tomorrow") + (style.isChinese ? " " : " · ") + style.weekday(day)
    }

    @ViewBuilder
    private var hero: some View {
        switch presentation.hero {
        case .time(let ring, _):
            let parts = style.parts(ring)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if parts.periodLeads, let period = parts.period { periodText(period) }
                Text(verbatim: parts.clock)
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .widgetAccentable()
                if !parts.periodLeads, let period = parts.period { periodText(period) }
            }
            .lineLimit(1)
        case .skipped:
            Text(verbatim: style.text("ux_tomorrow_skipped"))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
        case .notSet:
            Text(verbatim: style.text("ux_not_set"))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .openApp:
            EmptyView()
        }
    }

    private func periodText(_ period: String) -> some View {
        Text(verbatim: period).font(.system(size: 13, weight: .semibold, design: .rounded))
    }
}

// MARK: - accessoryCircular

private struct CircularTomorrowView: View {
    let entry: TomorrowWidgetEntry
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle

    private var glyph: String {
        presentation.hasIssue ? TomorrowWidgetPresentation.Glyph.warning.rawValue : presentation.glyph.rawValue
    }

    var body: some View {
        switch presentation.hero {
        case .time(let ring, _):
            // No gauge ring: at this size nothing can say what a ring measures, and the
            // rectangular family already carries the rain chance in words.
            let parts = style.parts(ring)
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: glyph).font(.system(size: 12, weight: .semibold))
                    Text(verbatim: parts.clock)
                        .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .widgetAccentable()
                    if let period = parts.period {
                        Text(verbatim: period)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 3)
            }
        case .skipped:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: presentation.hasIssue ? glyph
                          : (presentation.glyph == .closure ? TomorrowWidgetPresentation.Glyph.closure.rawValue
                             : TomorrowWidgetPresentation.Glyph.silent.rawValue))
                        .font(.system(size: 20))
                        .widgetAccentable()
                    Text(verbatim: style.text(presentation.skipLabelKey ?? "widget_skip_other"))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        case .notSet:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: glyph).font(.system(size: 20)).widgetAccentable()
            }
        case .openApp:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: TomorrowWidgetPresentation.Glyph.refresh.rawValue).font(.system(size: 22))
            }
        }
    }
}

// MARK: - accessoryInline

private struct InlineTomorrowView: View {
    let entry: TomorrowWidgetEntry
    let presentation: TomorrowWidgetPresentation
    let style: WidgetStyle

    var body: some View {
        let texts = self.texts
        ViewThatFits {
            Label(texts.full, systemImage: texts.symbol)
            Label(texts.short, systemImage: texts.symbol)
        }
    }

    private var texts: (full: String, short: String, symbol: String) {
        if presentation.hasIssue {
            let text = style.text("widget_issue_short")
            return (text, text, TomorrowWidgetPresentation.Glyph.warning.rawValue)
        }
        let symbol = presentation.glyph.rawValue
        switch presentation.hero {
        case .time(let ring, _):
            let time = style.time(ring)
            var earlierMinutes: Int?
            if case .status(let status) = entry.state, status.reason == .rain, status.leadTimeMinutes > 0 {
                earlierMinutes = status.leadTimeMinutes
            }
            if case .on(let ringDay)? = presentation.ringDay {
                // Rain moved the ring across midnight: name its weekday, never 明天, and
                // keep the day even in the short form.
                let weekday = style.weekday(ringDay)
                let dated = style.text(LocalizedLine(key: "widget_inline_ring_on", arguments: [.string(weekday), .string(time)]))
                guard let earlierMinutes else { return (dated, dated, symbol) }
                let rain = style.text(LocalizedLine(key: "widget_inline_rain_on",
                                                    arguments: [.string(weekday), .string(time), .int(earlierMinutes)]))
                return (rain, dated, symbol)
            }
            let ringLine = style.text(LocalizedLine(key: "widget_inline_ring", arguments: [.string(time)]))
            if let earlierMinutes {
                let rain = style.text(LocalizedLine(key: "widget_inline_rain",
                                                    arguments: [.string(time), .int(earlierMinutes)]))
                return (rain, ringLine, symbol)
            }
            return (ringLine, time, symbol)
        case .skipped:
            return (presentation.line.map { style.text($0.full) } ?? style.text("widget_inline_skipped"),
                    style.text("widget_inline_skipped"), symbol)
        case .notSet:
            return (style.text("ux_route_needed"), style.text("ux_not_set"), symbol)
        case .openApp(let reason):
            // Never "refresh" before the app has published anything (openAppText's rule).
            let keys = reason == .missing ? ("widget_inline_start", "widget_inline_start_short")
                                          : ("widget_inline_refresh", "widget_inline_refresh_short")
            return (style.text(keys.0), style.text(keys.1), TomorrowWidgetPresentation.Glyph.refresh.rawValue)
        }
    }
}
