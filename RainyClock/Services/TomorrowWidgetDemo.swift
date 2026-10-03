#if DEBUG
import SwiftUI
import WidgetKit

/// DEBUG-only visual harness for the "tomorrow" widget. Writes sample snapshots into
/// the App Group and reloads the widget; never touches the user's settings.
///
///     -widget-demo                          open the isolated demo host
///     -widget-demo-scenario <name>|tour     a TomorrowWidgetSamples.Scenario raw value, or the tour
///     -widget-demo-clock 12h|24h            clock format written into the snapshot (default 12h)
///     -widget-demo-tour-spacing <seconds>   tour step (default 30)
///     -widget-demo-mark image|text          the widgets'  Weather mark: fetch Apple's mark into the
///                                           App Group (needs WeatherKit), or delete it (text fallback)
enum TomorrowWidgetDemo {
    static let launchArgument = "-widget-demo"
    static let scenarioArgument = "-widget-demo-scenario"      // a Scenario rawValue, or "tour"
    static let clockArgument = "-widget-demo-clock"            // "12h" (default) | "24h"
    static let tourSpacingArgument = "-widget-demo-tour-spacing" // seconds, default 30
    static let markArgument = "-widget-demo-mark"                // "image" | "text"
    static let tourName = "tour"
    static let defaultTourSpacing: TimeInterval = 30

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var launchClock: ClockTimeFormat {
        argument(after: clockArgument) == "24h" ? .twentyFourHour : .twelveHour
    }

    static var launchTourSpacing: TimeInterval {
        guard let value = argument(after: tourSpacingArgument).flatMap(TimeInterval.init), value >= 5 else {
            return defaultTourSpacing
        }
        return value
    }

    /// Writes TomorrowWidgetSamples.snapshot(...) through TomorrowWidgetStore.appGroup (or clear() for
    /// .missing), then reloads the widget's timelines.
    @MainActor
    static func apply(_ scenario: TomorrowWidgetSamples.Scenario, clock: ClockTimeFormat, now: Date = Date()) {
        if let snapshot = TomorrowWidgetSamples.snapshot(scenario, clockFormat: clock, now: now) {
            TomorrowWidgetStore.appGroup.save(snapshot)
        } else {
            TomorrowWidgetStore.appGroup.clear()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TomorrowWidgetSnapshot.kind)
    }

    enum MarkState: String { case image, text }

    /// The widgets'  Weather mark in either state App Review can meet: Apple's image
    /// (fetched through WeatherKit, as the app does for real) or the text fallback (no image
    /// in the App Group). Returns whether the requested state is now in place.
    @MainActor
    static func setMark(_ state: MarkState) async -> Bool {
        let store = WeatherAttributionMarkStore.appGroup
        switch state {
        case .image:
            if await WeatherAttributionMarkCache.refreshIfNeeded(force: true) { return true }
            return store.data(for: WeatherAttributionMarkStore.widgetVariant) != nil
        case .text:
            store.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: TomorrowWidgetSnapshot.kind)
            return store.data(for: WeatherAttributionMarkStore.widgetVariant) == nil
        }
    }

    /// One snapshot whose entries step through every scenario except .expired/.missing, `spacing` apart,
    /// with expiresAt = last + spacing so the tour ends on the expired face.
    @MainActor
    static func applyTour(clock: ClockTimeFormat, spacing: TimeInterval = defaultTourSpacing, now: Date = Date()) {
        let scenarios = TomorrowWidgetSamples.Scenario.allCases.filter { $0 != .expired && $0 != .missing }
        var entries: [TomorrowWidgetSnapshot.Entry] = []
        for (index, scenario) in scenarios.enumerated() {
            guard var entry = TomorrowWidgetSamples.entry(scenario, now: now) else { continue }
            entry.validFrom = now.addingTimeInterval(Double(index) * spacing)
            entries.append(entry)
        }
        guard let last = entries.last else { return }
        let snapshot = TomorrowWidgetSnapshot(
            version: TomorrowWidgetSnapshot.currentVersion, publishedAt: now, timeZoneID: TimeZone.current.identifier,
            clockFormat: clock, mode: .car, expiresAt: last.validFrom.addingTimeInterval(spacing), entries: entries)
        TomorrowWidgetStore.appGroup.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TomorrowWidgetSnapshot.kind)
    }
}

/// Isolated host: never creates AlarmViewModel, never mounts ContentView, never touches ads or notifications.
struct TomorrowWidgetDemoHost: View {
    @State private var clock = TomorrowWidgetDemo.launchClock
    @State private var selection: String?
    @State private var appliedLaunchArguments = false
    @State private var markStatus = TomorrowWidgetDemoHost.currentMarkStatus

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(selection: $clock) {
                        Text(verbatim: "12h").tag(ClockTimeFormat.twelveHour)
                        Text(verbatim: "24h").tag(ClockTimeFormat.twentyFourHour)
                    } label: {
                        Text(verbatim: "Clock")
                    }
                    .pickerStyle(.segmented)
                    Button(action: startTour) {
                        row(TomorrowWidgetDemo.tourName, detail: "\(Int(TomorrowWidgetDemo.launchTourSpacing)) s per step")
                    }
                } header: {
                    Text(verbatim: "Widget demo · sample data")
                }
                Section {
                    Button { setMark(.image) } label: { row("mark: Apple image", detail: nil) }
                    Button { setMark(.text) } label: { row("mark: text fallback", detail: nil) }
                } header: {
                    Text(verbatim: "Widget  Weather mark")
                } footer: {
                    Text(verbatim: markStatus)
                }
                Section {
                    ForEach(TomorrowWidgetSamples.Scenario.allCases, id: \.self) { scenario in
                        Button { select(scenario) } label: { row(scenario.rawValue, detail: nil) }
                    }
                } header: {
                    Text(verbatim: "Scenarios")
                }
            }
            .navigationTitle(Text(verbatim: "Widget demo"))
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: applyLaunchArguments)
        .onChange(of: clock) { _, _ in reapply() }
    }

    private func row(_ title: String, detail: String?) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            if let detail { Text(verbatim: detail).foregroundStyle(.secondary) }
            if selection == title { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
    }

    private static var currentMarkStatus: String {
        WeatherAttributionMarkStore.appGroup.data(for: WeatherAttributionMarkStore.widgetVariant) == nil
            ? "No image in the App Group: the widget draws the text mark."
            : "Apple's image is in the App Group: the widget draws it."
    }

    private func setMark(_ state: TomorrowWidgetDemo.MarkState) {
        markStatus = "Working…"
        Task { @MainActor in
            let done = await TomorrowWidgetDemo.setMark(state)
            markStatus = (done ? "" : "Could not set \(state.rawValue) (WeatherKit unavailable?). ") + Self.currentMarkStatus
        }
    }

    private func applyLaunchArguments() {
        guard !appliedLaunchArguments else { return }
        appliedLaunchArguments = true
        if let mark = TomorrowWidgetDemo.argument(after: TomorrowWidgetDemo.markArgument)
            .flatMap(TomorrowWidgetDemo.MarkState.init(rawValue:)) {
            setMark(mark)
        }
        let requested = TomorrowWidgetDemo.argument(after: TomorrowWidgetDemo.scenarioArgument)
        if requested == TomorrowWidgetDemo.tourName {
            startTour()
        } else {
            select(requested.flatMap(TomorrowWidgetSamples.Scenario.init(rawValue:)) ?? .rainForecast)
        }
    }

    private func select(_ scenario: TomorrowWidgetSamples.Scenario) {
        selection = scenario.rawValue
        TomorrowWidgetDemo.apply(scenario, clock: clock)
    }

    private func startTour() {
        selection = TomorrowWidgetDemo.tourName
        TomorrowWidgetDemo.applyTour(clock: clock, spacing: TomorrowWidgetDemo.launchTourSpacing)
    }

    private func reapply() {
        if selection == TomorrowWidgetDemo.tourName { startTour() }
        else if let selection, let scenario = TomorrowWidgetSamples.Scenario(rawValue: selection) { select(scenario) }
    }
}
#endif
