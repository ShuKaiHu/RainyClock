import Foundation
import UserNotifications

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
        /// The announcement concerns a day the user set to ring regardless (a manual
        /// "ring" outranks a closure). Already decided: silent and passive, like
        /// `alreadyApplied`, so every revision of a typhoon night does not ring.
        case keptByUser
        /// The user turned the alarm off: nothing an announcement says changes it.
        /// Silent and passive.
        case alarmOff
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

    /// How each urgency is presented. Shared with the extension so the tests pin what
    /// the phone actually does: nil leaves the server's generic content untouched.
    struct Presentation: Equatable, Sendable {
        var playsSound: Bool
        var interruptionLevel: UNNotificationInterruptionLevel
    }

    static func presentation(for urgency: Urgency) -> Presentation? {
        switch urgency {
        case .unknown: nil
        case .matched: Presentation(playsSound: true, interruptionLevel: .timeSensitive)
        case .related: Presentation(playsSound: true, interruptionLevel: .active)
        case .unrelated, .alreadyApplied, .keptByUser, .alarmOff: Presentation(playsSound: false, interruptionLevel: .passive)
        }
    }

    /// Each server instance caches the snapshot for a few seconds, so a fetch right after
    /// a broadcast can still return the previous revision — and evaluating that would
    /// describe the old announcements, possibly "not for your districts" for the very
    /// closure this push is about. Wait out the cache once; if the revision still differs,
    /// return nil so the server's generic text is shown. A push without a revision is
    /// taken as it comes.
    static func fetchFeed(matching pushedRevision: String?, retryAfter delay: Duration = .seconds(6),
                          fetch: () async throws -> DisasterFeed,
                          sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> DisasterFeed? {
        guard let first = try? await fetch() else { return nil }
        guard let pushedRevision, first.revision != pushedRevision else { return first }
        do { try await sleep(delay) } catch { return nil }
        guard let second = try? await fetch(), second.revision == pushedRevision else { return nil }
        return second
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
              state.home?.isValid == true || state.destination?.isValid == true else { return generic }
        if state.alarmOff == true {
            return Result(urgency: .alarmOff, title: generic.title,
                          body: chinese ? "你的鬧鐘目前關閉，這則公告不會改變鬧鐘。" : "Your alarm is off, so this announcement doesn't change it.")
        }
        guard let feed else { return generic }
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
        func related(_ decision: DisasterDecision) -> Result? {
            switch decision.status {
            case "noAnnouncement", "disabled", "missingRegion": return nil
            default:
                if decision.shouldSkip || feedProblemReasons.contains(decision.reason) { return nil }
                return Result(urgency: .related, title: generic.title,
                              body: chinese ? decision.reason
                                            : englishRelatedReasons[decision.reason] ?? englishRelatedFallback)
            }
        }
        // 1. News: a closure the app has not applied and the user has not overridden.
        //    It outranks a day that is already off, even when that day comes earlier.
        if let (date, decision) = suppressing.first(where: {
            !state.isAlreadySkipped($0.0) && !state.isKeptRinging($0.0) && !state.isUserSkipped($0.0)
        }) {
            let day = dayLabel(date)
            let action = date == nearest
                ? (chinese ? "下一次鬧鐘會依你的設定處理，打開 App 確認。" : "Your next alarm will follow your settings. Open the app to confirm.")
                : (chinese ? "\(day) 的鬧鐘會依你的設定處理，打開 App 確認。" : "\(day): that day's alarm will follow your settings. Open the app to confirm.")
            return matched(date, decision, urgency: .matched, action: action)
        }
        // 2. The next day that will actually ring has an announcement that does not
        //    silence it (partial area, unclear wording): that is worth a sound, and it
        //    outranks a repeat for a day that is already off.
        if let armed = dates.first(where: { !state.isAlreadySkipped($0) && !state.isUserSkipped($0) }),
           let result = related(decide(armed)) {
            return result
        }
        // 3. Already decided: skipped by the app, or kept ringing by the user's own setting.
        if let (date, decision) = suppressing.first(where: { state.isAlreadySkipped($0.0) || state.isUserSkipped($0.0) }) {
            return matched(date, decision, urgency: .alreadyApplied,
                           action: chinese ? "\(dayLabel(date)) 當天的鬧鐘已略過。" : "\(dayLabel(date)): that day's alarm has already been skipped.")
        }
        if let (date, decision) = suppressing.first {
            return matched(date, decision, urgency: .keptByUser,
                           action: chinese ? "\(dayLabel(date)) 依你的設定照響。" : "\(dayLabel(date)): your alarm rings as you set it.")
        }
        // Nothing suppresses any more, yet the nearest day is one the app skipped:
        // the phone and the announcements disagree until the app runs again, and
        // "the alarm rings as usual" would name a day that is not armed. Say nothing
        // specific; the generic text asks the user to open the app.
        // A morning the user turned off once is not "the alarm": judge the next armed one.
        guard let judged = dates.first(where: { !state.isUserSkipped($0) }) else { return generic }
        if state.isAlreadySkipped(judged) { return generic }
        if decide(judged).status == "noAnnouncement" {
            return Result(urgency: .unrelated, title: generic.title,
                          body: chinese ? "與你設定的地區無關，鬧鐘照常。" : "Not for your districts; the alarm rings as usual.")
        }
        return generic
    }
}
