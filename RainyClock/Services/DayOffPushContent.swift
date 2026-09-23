import Foundation

/// Turns the server's one-size-fits-all day-off push into what this phone should
/// actually show. Runs inside the notification service extension with the app
/// closed, so it depends on nothing but the shared state, a freshly fetched feed
/// and the clock — and it reuses the same evaluator the alarm itself uses, so the
/// notification can never claim more than the alarm would act on.
enum DayOffPushContent {
    enum Urgency: String, Equatable, Sendable {
        /// A current, matching suspension for one of the user's districts: sound,
        /// time-sensitive. The alarm will (or already did) honour it when the app runs.
        case matched
        /// The user's district has a new announcement that does not silence the
        /// alarm (partial area, unrecognised wording, contradictory data): sound,
        /// normal urgency, with the reason.
        case related
        /// Nothing for the user's districts: silent, passive, kept in the centre.
        case unrelated
        /// Cannot tell (feature off, no districts, no next alarm, feed unreachable):
        /// leave the server's generic fallback untouched.
        case unknown
    }

    struct Result: Equatable, Sendable {
        var urgency: Urgency
        var title: String
        var body: String
    }

    /// Reasons the evaluator gives when the *feed*, not the announcement, is the
    /// problem. Those are the extension's own fetch failing, not news for the user.
    private static let feedProblemReasons: Set<String> = ["公告尚未更新，維持原鬧鐘", "公告時間異常，維持原鬧鐘"]

    static func evaluate(state: DayOffSharedState?, feed: DisasterFeed?, now: Date, chinese: Bool) -> Result {
        let generic = Result(urgency: .unknown,
                             title: chinese ? "停班停課公告已更新" : "Work/school closure update",
                             body: chinese ? "打開雨天鬧鐘確認明天的鬧鐘。" : "Open Rainy Clock to check tomorrow's alarm.")
        guard let state, state.enabled, state.observesWork || state.observesSchool,
              state.home?.isValid == true || state.destination?.isValid == true,
              let alarmDate = state.normalAlarmDate, alarmDate > now,
              let feed else { return generic }
        let decision = DisasterSuspensionEvaluator.decision(
            feed: feed, normalAlarmDate: alarmDate, now: now,
            home: state.home, destination: state.destination,
            observesWork: state.observesWork, observesSchool: state.observesSchool)
        if decision.shouldSkip {
            let area = decision.area ?? ""
            return Result(urgency: .matched,
                          title: chinese ? decision.reason : "\(area): closure announced",
                          body: chinese ? "明天的鬧鐘會依你的設定處理，打開 App 確認。"
                                        : "Tomorrow's alarm will follow your settings. Open the app to confirm.")
        }
        switch decision.status {
        case "noAnnouncement":
            return Result(urgency: .unrelated, title: generic.title,
                          body: chinese ? "與你設定的地區無關，鬧鐘照常。" : "Not for your districts; the alarm rings as usual.")
        case "disabled", "missingRegion":
            return generic
        default:
            if feedProblemReasons.contains(decision.reason) { return generic }
            return Result(urgency: .related, title: generic.title,
                          body: chinese ? decision.reason
                                        : "Your district has a new announcement, but the alarm stays on: \(decision.reason)")
        }
    }
}
