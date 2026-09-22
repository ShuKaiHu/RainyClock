import Foundation

enum DisasterMapState: String, CaseIterable, Sendable {
    case normal, closed, workOnly, schoolOnly, partial, unknown
}

/// Display-only government announcement status. This does not evaluate a user's
/// alarm, work/school preferences, or whether a scheduled alarm should be skipped.
struct DisasterMapStatus: Equatable, Sendable {
    enum Reason: String, Sendable {
        case announcement, noAnnouncement, sourceUnavailable, stale, invalid
        case conflict, withdrawn, partialTime, partialArea
    }

    let state: DisasterMapState
    let reason: Reason
    let latestNotice: DisasterNotice?
    let work: DisasterNoticeParser.State?
    let school: DisasterNoticeParser.State?
    let dayPart: DisasterNoticeParser.DayPart?
    let startsAtMinute: Int?

    static let maximumFeedAge: TimeInterval = 15 * 60

    private struct Candidate: Sendable {
        let notice: DisasterNotice
        let parsed: DisasterNoticeParser.Parsed?
    }

    private struct Prepared {
        let actual: [DisasterNotice]
        let parsed: [Candidate]
        let withdrawnIDs: Set<String>

        init(_ feed: DisasterFeed) {
            actual = feed.notices.filter { $0.status == "Actual" }
            parsed = actual.map { Candidate(notice: $0, parsed: DisasterNoticeParser.parse($0)) }
            withdrawnIDs = Set(actual.filter { $0.msgType == "Cancel" || $0.msgType == "Update" }
                .flatMap(\.references).map(DisasterMapStatus.referenceID))
        }
    }

    static func resolve(region: DisasterRegion, date: Date, feed: DisasterFeed?,
                        now: Date, sourceFailed: Bool) -> Self {
        resolve(region: region, date: date, feed: feed, now: now, sourceFailed: sourceFailed, prepared: nil)
    }

    /// Parse the CAP wording once when coloring the complete township map.
    static func resolve(regions: [DisasterRegion], date: Date, feed: DisasterFeed?,
                        now: Date, sourceFailed: Bool) -> [DisasterRegion: Self] {
        let prepared = sourceFailed ? nil : feed.map(Prepared.init)
        var result: [DisasterRegion: Self] = [:]
        for region in regions where result[region] == nil {
            result[region] = resolve(region: region, date: date, feed: feed, now: now,
                sourceFailed: sourceFailed, prepared: prepared)
        }
        return result
    }

    private static func resolve(region: DisasterRegion, date: Date, feed: DisasterFeed?,
                                now: Date, sourceFailed: Bool, prepared: Prepared?) -> Self {
        guard region.isValid, date.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else { return status(.unknown, .invalid) }
        let calendar = DisasterNoticeParser.taipeiCalendar
        let target = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              target == today || target == tomorrow else { return status(.unknown, .invalid) }
        guard !sourceFailed, let feed else { return status(.unknown, .sourceUnavailable) }
        guard feed.schemaVersion == 1, feed.checkedAt <= now,
              feed.sourceUpdatedAt.map({ $0 <= feed.checkedAt && $0 <= now }) ?? true else {
            return status(.unknown, .invalid)
        }
        guard now.timeIntervalSince(feed.checkedAt) <= maximumFeedAge else { return status(.unknown, .stale) }

        let county = DisasterRegion.normalize(region.county)
        let district = DisasterRegion.normalize(region.name)
        let prepared = prepared ?? Prepared(feed)
        let actual = prepared.actual
        let parsed = prepared.parsed
        let matching = parsed.filter { candidate in
            guard let value = candidate.parsed else { return false }
            let area = DisasterRegion.normalize(value.area)
            guard area == county || area == district || area.hasPrefix(district) else { return false }
            // An undated newer notice blocks an older result until confirmed.
            return value.targetDate.map { calendar.isDate($0, inSameDayAs: target) } ?? true
        }
        var relevantIDs = Set(matching.map(\.notice.id))
        // Follow update/cancel chains even when intermediate CAP messages have
        // no parseable area headline of their own.
        var expanded = true
        while expanded {
            expanded = false
            for notice in actual where notice.msgType == "Cancel" || notice.msgType == "Update" {
                if notice.references.map(referenceID).contains(where: relevantIDs.contains),
                   relevantIDs.insert(notice.id).inserted { expanded = true }
            }
        }
        let withdrawnIDs = prepared.withdrawnIDs
        var candidates = matching.filter { !withdrawnIDs.contains($0.notice.id) }
        // CAP cancellations often contain only "撤銷". Follow their references
        // so the map can show a withdrawal instead of falling back to an older
        // county-wide result after a district exception was withdrawn.
        for candidate in parsed where candidate.notice.msgType == "Cancel" || candidate.notice.msgType == "Update" {
            guard candidate.notice.references.map(referenceID).contains(where: relevantIDs.contains),
                  !candidates.contains(where: { $0.notice == candidate.notice }) else { continue }
            candidates.append(candidate)
        }
        guard let newest = candidates.map(\.notice.sentAt).max() else {
            return status(.unknown, .noAnnouncement)
        }
        var latest: [Candidate] = []
        for candidate in candidates where candidate.notice.sentAt == newest {
            if !latest.contains(where: { $0.notice == candidate.notice }) { latest.append(candidate) }
        }
        latest.sort { $0.notice.id < $1.notice.id }
        guard latest.count == 1, let candidate = latest.first else {
            return status(.unknown, .conflict, latest.first)
        }
        let notice = candidate.notice
        guard notice.sentAt <= now, notice.sentAt <= feed.checkedAt,
              let previousDay = calendar.date(byAdding: .day, value: -1, to: target),
              notice.sentAt >= previousDay,
              notice.sentAt < calendar.date(byAdding: .day, value: 1, to: target)! else {
            return status(.unknown, .stale, candidate)
        }
        // Yesterday's announcement can remain valid for all of today, including
        // after an ordinary wake-up time. Alarm scheduling's future-time and
        // 18-hour guard are intentionally not used by this date-based display.
        if notice.msgType == "Cancel" { return status(.unknown, .withdrawn, candidate) }
        guard notice.msgType == "Alert" || notice.msgType == "Update", let value = candidate.parsed,
              let parsedDate = value.targetDate, calendar.isDate(parsedDate, inSameDayAs: target),
              value.isRecognized else { return status(.unknown, .invalid, candidate) }
        guard value.work != .unknown, value.school != .unknown else {
            return status(.unknown, .noAnnouncement, candidate)
        }
        guard ["Extreme", "Severe", "Minor"].contains(notice.severity),
              (value.work == .suspended) == (notice.severity == "Extreme") else {
            return status(.unknown, .invalid, candidate)
        }
        let area = DisasterRegion.normalize(value.area)
        guard area == county || area == district || area.hasPrefix(district) else {
            return status(.unknown, .withdrawn, candidate)
        }
        // A village name/code or district-level code under a county headline
        // never expands into a whole-district/whole-county green or red polygon.
        let villageCode = notice.geocodes.contains { $0.contains("-") }
        let narrowerCountyCode = area == county && notice.geocodes.contains { $0.count > 5 }
        guard notice.geocodes.allSatisfy({
            $0.range(of: #"^(?:[0-9]{2}|[0-9]{5}|[0-9]{7})(?:-[0-9]{1,8})?$"#, options: .regularExpression) != nil
        }) else { return status(.unknown, .invalid, candidate) }
        if (area != county && area != district) || villageCode || narrowerCountyCode {
            return status(.partial, .partialArea, candidate)
        }
        if value.dayPart != .full || value.startsAtMinute != nil {
            return status(.partial, .partialTime, candidate)
        }
        switch (value.work, value.school) {
        case (.normal, .normal): return status(.normal, .announcement, candidate)
        case (.suspended, .suspended): return status(.closed, .announcement, candidate)
        case (.suspended, .normal): return status(.workOnly, .announcement, candidate)
        case (.normal, .suspended): return status(.schoolOnly, .announcement, candidate)
        default: return status(.unknown, .noAnnouncement, candidate)
        }
    }

    private static func referenceID(_ value: String) -> String {
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
        return (pieces.count == 3 ? String(pieces[1]) : value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func status(_ state: DisasterMapState, _ reason: Reason, _ candidate: Candidate? = nil) -> Self {
        Self(state: state, reason: reason, latestNotice: candidate?.notice,
            work: candidate?.parsed?.work, school: candidate?.parsed?.school,
            dayPart: candidate?.parsed?.dayPart, startsAtMinute: candidate?.parsed?.startsAtMinute)
    }
}
