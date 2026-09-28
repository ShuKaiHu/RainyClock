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

    /// English wording for the evaluator's Chinese "alarm stays on" reasons, so an English
    /// notification never mixes languages. Anything unmapped gets the generic sentence.
    private static let englishRelatedReasons: [String: String] = [
        "僅部分地區停班停課，維持原鬧鐘": "Only part of your district is closed, so your alarm stays on.",
        "公告內容有衝突，維持原鬧鐘": "The announcements for your district conflict, so your alarm stays on.",
        "公告已過期或時間異常，維持原鬧鐘": "The announcement for your district is out of date, so your alarm stays on.",
        "公告行政區格式不明，維持原鬧鐘": "The announcement's district is unclear, so your alarm stays on.",
        "公告尚未確認，維持原鬧鐘": "The announcement for your district is not confirmed yet, so your alarm stays on.",
        "公告資訊不一致，維持原鬧鐘": "The announcement for your district is inconsistent, so your alarm stays on.",
    ]
    private static let englishRelatedFallback = "Your district has a new announcement, but your alarm stays on."

    /// docs/DAYOFF-SPEC.md §7: a "your district is closed" surface names the source and
    /// the source's own update time. Taipei time, because the announcements are Taiwan's.
    static func sourceLine(updatedAt: Date?, chinese: Bool) -> String {
        let credit = chinese ? "資料來源：行政院人事行政總處（經 NCDR 發布）" : "Source: DGPA via NCDR"
        guard let updatedAt else { return credit }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DisasterNoticeParser.taipeiCalendar.timeZone
        formatter.dateFormat = "M/d HH:mm"
        let time = formatter.string(from: updatedAt)
        return chinese ? "\(credit)，更新 \(time)" : "\(credit), updated \(time)"
    }

    static func evaluate(state: DayOffSharedState?, feed: DisasterFeed?, now: Date, chinese: Bool) -> Result {
        let generic = Result(urgency: .unknown,
                             title: chinese ? "停班停課公告已更新" : "Work/school closure update",
                             body: chinese ? "打開雨天鬧鐘確認下一次鬧鐘。" : "Open Rainy Clock to check your next alarm.")
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
                          body: (chinese ? "下一次鬧鐘會依你的設定處理，打開 App 確認。\n"
                                         : "Your next alarm will follow your settings. Open the app to confirm.\n")
                              + sourceLine(updatedAt: feed.sourceUpdatedAt ?? decision.sourceUpdatedAt, chinese: chinese))
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
                                        : englishRelatedReasons[decision.reason] ?? englishRelatedFallback)
        }
    }
}
