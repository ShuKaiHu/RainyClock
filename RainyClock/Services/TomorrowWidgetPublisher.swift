import Combine
import Foundation
import UIKit
import WidgetKit

/// Keeps the App Group snapshot the "tomorrow" widget reads in step with the card.
///
/// One instance per process, attached to the model every path shares
/// (`CommuteAlarmRefresher.currentModel()`), so foreground edits, background
/// refreshes and pushes all republish through the same dedupe.
@MainActor
final class TomorrowWidgetPublisher {
    static let shared = TomorrowWidgetPublisher()

    /// The extension is iOS 26+; on iOS 17–25 publishing is a no-op.
    static var systemHostsWidget: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private let store: TomorrowWidgetStore
    private let reload: @MainActor () -> Void
    private let isEnabled: Bool
    private weak var model: AlarmViewModel?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    /// A foreground publish that arrived before the model did, or before its plan was
    /// settled; the first publish that goes through then reloads too.
    private var reloadWhenStarted = false

    init(store: TomorrowWidgetStore = .appGroup,
         reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: TomorrowWidgetSnapshot.kind) },
         isEnabled: Bool = TomorrowWidgetPublisher.systemHostsWidget && !AppEnvironment.isRunningTests) {
        self.store = store
        self.reload = reload
        self.isEnabled = isEnabled
    }

    /// Idempotent. `objectWillChange` fires BEFORE the change, hence the debounce.
    func start(observing model: AlarmViewModel) {
        guard isEnabled, self.model == nil else { return }
        self.model = model
        subscription = model.objectWillChange.merge(with: MembershipManager.shared.objectWillChange)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.publish() }
            }
        observers = [Notification.Name.NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.publish() }
            }
        }
        // Never during SwiftUI body evaluation, which is where currentModel() first runs.
        // A forced reload asked for before the model arrived rides along (`publish`).
        Task { @MainActor [weak self] in
            _ = self?.publish()
        }
    }

    /// Synchronous. Returns whether it wrote.
    ///
    /// `forceReload` reloads the widget even when the snapshot is unchanged. The dedupe
    /// compares against the stored snapshot, not against what the widget shows, and a
    /// widget can be showing a face that only a reload clears ("open the app to refresh"
    /// after a time zone or clock change that has since been undone). The app passes it
    /// when it comes to the foreground, where reloads do not count against the budget.
    ///
    /// Nothing is written until the model has tried to restore the plan
    /// (`AlarmViewModel.membershipPlanIsSettled`). A cold background or push launch attaches
    /// this publisher before that restore, and a snapshot built then drops a saved closure
    /// rule: the widget would show a closure-skipped morning ringing, and the corrective
    /// reload that follows the restore may be throttled. The restore publishes the model's
    /// change, which brings the first write; a forced reload asked for meanwhile waits for it.
    @discardableResult
    func publish(now: Date = Date(), forceReload: Bool = false) -> Bool {
        guard isEnabled else { return false }
        guard let model, model.membershipPlanIsSettled else {
            if forceReload { reloadWhenStarted = true }
            return false
        }
        let force = forceReload || reloadWhenStarted
        reloadWhenStarted = false
        return write(TomorrowWidgetSnapshotBuilder.snapshot(for: model, now: now), now: now, forceReload: force)
    }

    /// Dedupe: skip when the stored snapshot already describes every moment from `now` on.
    /// An equivalent snapshot is still reloaded when `forceReload` is set.
    @discardableResult
    func write(_ snapshot: TomorrowWidgetSnapshot, now: Date, forceReload: Bool = false) -> Bool {
        if let old = store.load(), old.isEquivalent(to: snapshot, at: now) {
            if forceReload { reload() }
            return false
        }
        guard store.save(snapshot) else { return false }
        reload()
        return true
    }
}
