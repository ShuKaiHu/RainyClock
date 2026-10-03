import SwiftUI
import WidgetKit
#if WIDGET_VIEWS_IN_TESTS
@testable import RainyClock   // see TomorrowWidgetViews.swift
#endif
#if !WIDGET_VIEWS_IN_TESTS || WIDGET_RENDER

/// One moment of the "tomorrow" widget: a state from the shared timeline plan plus
/// the two display preferences the snapshot carries.
struct TomorrowWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let state: TomorrowWidgetTimeline.State
    let clockFormat: ClockTimeFormat                 // snapshot's; .twelveHour when missing
    let mode: TomorrowWidgetSnapshot.CommuteMode     // snapshot's; .car when missing

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: TomorrowWidgetPresentation(state).relevanceScore)
    }

    /// The first planned item of a sample snapshot: gallery, placeholder and previews.
    static func sample(_ scenario: TomorrowWidgetSamples.Scenario, now: Date = .now) -> Self {
        let snapshot = TomorrowWidgetSamples.snapshot(scenario, now: now)
        let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: TimeZone.current.identifier)
        return Self(date: now, state: plan.items[0].state, clockFormat: snapshot?.clockFormat ?? .twelveHour,
                    mode: snapshot?.mode ?? .car)
    }
}

/// Nonisolated, and decodes the App Group snapshot fresh on every call. Entries carry
/// absolute dates, so a reboot or a late reload is safe.
struct TomorrowTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TomorrowWidgetEntry {
        .sample(.normalClear)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (TomorrowWidgetEntry) -> Void) {
        if context.isPreview {
            // The gallery shows the case the widget exists for.
            completion(.sample(.rainForecast))
            return
        }
        completion(entries(now: .now).entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TomorrowWidgetEntry>) -> Void) {
        let result = entries(now: .now)
        completion(Timeline(entries: result.entries, policy: .after(result.reloadAfter)))
    }

    private func entries(now: Date) -> (entries: [TomorrowWidgetEntry], reloadAfter: Date) {
        let snapshot = TomorrowWidgetStore.appGroup.load()
        let plan = TomorrowWidgetTimeline.plan(snapshot: snapshot, now: now, currentTimeZoneID: TimeZone.current.identifier)
        let entries = plan.items.map {
            TomorrowWidgetEntry(date: $0.date, state: $0.state, clockFormat: snapshot?.clockFormat ?? .twelveHour,
                                mode: snapshot?.mode ?? .car)
        }
        return (entries, plan.reloadAfter)
    }
}

/// Home Screen and Lock Screen: tomorrow's expected alarm and whether rain moved it.
struct TomorrowAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TomorrowWidgetSnapshot.kind, provider: TomorrowTimelineProvider()) { entry in
            TomorrowWidgetView(entry: entry)
        }
        .configurationDisplayName("widget_display_name")
        .description("widget_description")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
#endif
