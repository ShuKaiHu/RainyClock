import UserNotifications

/// Personalises the day-off push on the phone. The server sends the same
/// notification to every registered device; this extension — which the system
/// runs even when the app is closed — reads the districts the app keeps in the
/// App Group, fetches the announcements, and decides whether this one is
/// time-sensitive, merely informative, or silent. It never touches an alarm:
/// that stays the app's job, on its own evidence, when it next runs.
///
/// If anything fails or the ~30 s budget runs out, the system shows the server's
/// generic, localised fallback unchanged — which is still correct, just vaguer.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var pending: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard request.content.userInfo["type"] as? String == "dayoff-sync",
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.lock()
        handler = contentHandler
        pending = content
        lock.unlock()
        work = Task { [weak self] in
            let state = DayOffSharedState.load()
            var feed: DisasterFeed?
            if let url = state?.serviceURL {
                feed = try? await DisasterFeedClient(endpoint: url.appendingPathComponent("v1/suspensions")).fetch()
            }
            let chinese = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
            let result = DayOffPushContent.evaluate(state: state, feed: feed, now: Date(), chinese: chinese)
            self?.finish { Self.apply(result, to: $0) }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish { _ in }
    }

    private func finish(_ mutate: (UNMutableNotificationContent) -> Void) {
        lock.lock()
        let handler = self.handler
        let content = self.pending
        self.handler = nil
        self.pending = nil
        lock.unlock()
        guard let handler, let content else { return }
        mutate(content)
        handler(content)
    }

    static func apply(_ result: DayOffPushContent.Result, to content: UNMutableNotificationContent) {
        switch result.urgency {
        case .unknown:
            return
        case .matched:
            content.title = result.title
            content.body = result.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case .related:
            content.title = result.title
            content.body = result.body
            content.sound = .default
            content.interruptionLevel = .active
        case .unrelated:
            content.title = result.title
            content.body = result.body
            content.sound = nil
            content.interruptionLevel = .passive
        }
    }
}
