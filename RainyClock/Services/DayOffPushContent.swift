import Foundation

/// Turns the server's one-size-fits-all day-off push into what this phone should
/// actually show. Runs inside the notification service extension with the app
/// closed, so it depends on nothing but the shared state, a freshly fetched feed
/// and the clock — and it reuses the same evaluator the alarm itself uses, so the
/// notification can never claim more than the alarm would act on.
enum DayOffPushContent {
    enum Urgency: String, Equatable, Sendable {
        /// A current, matching suspension for one of the user's districts that the
        /// app has not applied yet: sound, time-sensitive. The alarm will honour it
        /// when the app runs.
        case matched
        /// The announcement concerns a day the app has already skipped. True, but
        /// not news: silent and passive, so a typhoon night's stream of other
        /// counties' updates does not ring this phone once per revision.
        case alreadyApplied
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

    /// The day an announcement concerns, in Taipei time like the announcements themselves.
    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DisasterNoticeParser.taipeiCalendar.timeZone
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    static func evaluate(state: DayOffSharedState?, feed: DisasterFeed?, now: Date, chinese: Bool) -> Result {
        let generic = Result(urgency: .unknown,
                             title: chinese ? "停班停課公告已更新" : "Work/school closure update",
                             body: chinese ? "打開雨天鬧鐘確認下一次鬧鐘。" : "Open Rainy Clock to check your next alarm.")
        guard let state, state.enabled, state.observesWork || state.observesSchool,
              state.home?.isValid == true || state.destination?.isValid == true,
              let feed else { return generic }
        // Every upcoming normal date, including ones the app already skipped: a repeat
        // announcement for a day that is already off must still read as a match.
        let dates = state.candidateAlarmDates(after: now)
        guard let nearest = dates.first else { return generic }
        func decide(_ date: Date) -> DisasterDecision {
            DisasterSuspensionEvaluator.decision(
                feed: feed, normalAlarmDate: date, now: now,
                home: state.home, destination: state.destination,
                observesWork: state.observesWork, observesSchool: state.observesSchool)
        }
        let suppressing = dates.compactMap { date -> (Date, DisasterDecision)? in
            let decision = decide(date)
            return decision.shouldSkip ? (date, decision) : nil
        }
        func matched(_ date: Date, _ decision: DisasterDecision, urgency: Urgency, action: String) -> Result {
            Result(urgency: urgency,
                   title: chinese ? decision.reason : "\(decision.area ?? ""): closure announced",
                   body: action + "\n" + sourceLine(updatedAt: feed.sourceUpdatedAt ?? decision.sourceUpdatedAt, chinese: chinese))
        }
        // News first: a closure the app has not applied yet outranks a day that is
        // already off, even when the already-off day comes earlier.
        if let (date, decision) = suppressing.first(where: { !state.isAlreadySkipped($0.0) }) {
            let day = dayLabel(date)
            let action = date == nearest
                ? (chinese ? "下一次鬧鐘會依你的設定處理，打開 App 確認。" : "Your next alarm will follow your settings. Open the app to confirm.")
                : (chinese ? "\(day) 的鬧鐘會依你的設定處理，打開 App 確認。" : "\(day): that day's alarm will follow your settings. Open the app to confirm.")
            return matched(date, decision, urgency: .matched, action: action)
        }
        if let (date, decision) = suppressing.first {
            let day = dayLabel(date)
            return matched(date, decision, urgency: .alreadyApplied,
                           action: chinese ? "\(day) 當天的鬧鐘已略過。" : "\(day): that day's alarm has already been skipped.")
        }
        // Nothing suppresses any more, yet the nearest day is one the app skipped:
        // the phone and the announcements disagree until the app runs again, and
        // "the alarm rings as usual" would name a day that is not armed. Say nothing
        // specific; the generic text asks the user to open the app.
        if state.isAlreadySkipped(nearest) { return generic }
        let decision = decide(nearest)
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
