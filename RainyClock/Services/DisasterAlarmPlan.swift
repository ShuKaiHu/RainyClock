import Foundation

struct DisasterScheduleFingerprint: Codable, Equatable {
    var home: DisasterRegion?
    var destination: DisasterRegion?
    var observesWork: Bool
    var observesSchool: Bool
}

struct AppliedDisasterSkip: Codable, Equatable, Sendable {
    var normalDate: Date
    var noticeIDs: [String]
    var appliedAt: Date
}

enum DisasterAlarmPlan {
    /// A manual "ring" wins. A disaster never creates an alarm on an otherwise
    /// silent day, and never changes any date except the matched occurrence.
    static func filtering(_ plan: CalendarAlarmPlan, settings: CommuteAlarmSettings,
                          feed: DisasterFeed?, now: Date) -> (plan: CalendarAlarmPlan, skips: [AppliedDisasterSkip]) {
        guard settings.isDisasterSuspensionEnabled else { return (plan, []) }
        var result = plan
        var skips: [AppliedDisasterSkip] = []
        result.occurrences = plan.occurrences.filter { occurrence in
            if settings.calendarSettings.forcesRing(on: occurrence.normalDate) { return true }
            let decision = DisasterSuspensionEvaluator.decision(feed: feed, normalAlarmDate: occurrence.normalDate,
                now: now, home: settings.homeSuspensionRegion, destination: settings.workSuspensionRegion,
                observesWork: settings.observesWorkSuspensions, observesSchool: settings.observesSchoolSuspensions)
            guard decision.shouldSkip, occurrence.ringDate > now else { return true }
            skips.append(.init(normalDate: occurrence.normalDate, noticeIDs: decision.noticeIDs.sorted(), appliedAt: now))
            return false
        }
        return (result, skips)
    }
}
