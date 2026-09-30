import Foundation

struct DisasterRegion: Codable, Equatable, Hashable, Sendable {
    var county: String
    var district: String
    var name: String { county + district }
    var isValid: Bool {
        Self.counties.contains(Self.normalize(county)) && !district.isEmpty
            && district.range(of: #"^[\p{Han}]{1,8}[鄉鎮市區]$"#, options: .regularExpression) != nil
    }
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "台", with: "臺")
    }
    static let counties = ["臺北市", "新北市", "桃園市", "臺中市", "臺南市", "高雄市", "基隆市", "新竹市", "嘉義市",
                           "新竹縣", "苗栗縣", "彰化縣", "南投縣", "雲林縣", "嘉義縣", "屏東縣", "宜蘭縣", "花蓮縣", "臺東縣", "澎湖縣", "金門縣", "連江縣"]
}

/// The service transports the government's original wording; the device decides
/// against its own region, date and preferences. Neither address is uploaded.
struct DisasterNotice: Codable, Equatable, Sendable {
    var id: String
    var sentAt: Date
    var description: String
    var severity: String
    var msgType: String
    var status: String
    var geocodes: [String]
    var references: [String]

    init(id: String, sentAt: Date, description: String, severity: String, msgType: String = "Alert", status: String = "Actual", geocodes: [String] = [], references: [String] = []) {
        self.id = id; self.sentAt = sentAt; self.description = description; self.severity = severity
        self.msgType = msgType; self.status = status; self.geocodes = geocodes; self.references = references
    }
    private enum CodingKeys: String, CodingKey { case id, sentAt, description, severity, msgType, status, geocodes, references }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sentAt = try DisasterISO8601.decode(c.decode(String.self, forKey: .sentAt), codingPath: decoder.codingPath)
        description = try c.decode(String.self, forKey: .description)
        severity = try c.decode(String.self, forKey: .severity)
        msgType = try c.decode(String.self, forKey: .msgType)
        status = try c.decode(String.self, forKey: .status)
        geocodes = try c.decode([String].self, forKey: .geocodes)
        references = try c.decode([String].self, forKey: .references)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(DisasterISO8601.string(sentAt), forKey: .sentAt)
        try c.encode(description, forKey: .description); try c.encode(severity, forKey: .severity)
        try c.encode(msgType, forKey: .msgType); try c.encode(status, forKey: .status)
        try c.encode(geocodes, forKey: .geocodes); try c.encode(references, forKey: .references)
    }
}

struct DisasterFeed: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var revision: String?
    var checkedAt: Date
    var sourceUpdatedAt: Date?
    var notices: [DisasterNotice]
    init(schemaVersion: Int = 1, revision: String? = nil, checkedAt: Date, sourceUpdatedAt: Date? = nil, notices: [DisasterNotice]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.checkedAt = checkedAt; self.sourceUpdatedAt = sourceUpdatedAt; self.notices = notices
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, checkedAt, sourceUpdatedAt, notices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        checkedAt = try DisasterISO8601.decode(c.decode(String.self, forKey: .checkedAt), codingPath: decoder.codingPath)
        sourceUpdatedAt = try c.decodeIfPresent(String.self, forKey: .sourceUpdatedAt).map { try DisasterISO8601.decode($0, codingPath: decoder.codingPath) }
        notices = try c.decode([DisasterNotice].self, forKey: .notices)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(DisasterISO8601.string(checkedAt), forKey: .checkedAt)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encodeIfPresent(sourceUpdatedAt.map(DisasterISO8601.string), forKey: .sourceUpdatedAt)
        try c.encode(notices, forKey: .notices)
    }
}

enum DisasterISO8601 {
    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func decode(_ value: String, codingPath: [any CodingKey]) throws -> Date {
        guard let date = date(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid ISO8601 timestamp"))
        }
        return date
    }
}

protocol DisasterFeedProviding: Sendable {
    func fetch() async throws -> DisasterFeed
}

enum DisasterFeedError: Error, LocalizedError {
    case notConfigured, invalidEndpoint, invalidResponse, unsupportedSchema
    var errorDescription: String? {
        switch self {
        case .notConfigured: "天災公告服務尚未設定"
        case .invalidEndpoint: "天災公告服務需要 HTTPS"
        case .invalidResponse: "無法取得有效的天災公告"
        case .unsupportedSchema: "天災公告資料版本尚不支援"
        }
    }
}

struct DisasterFeedClient: DisasterFeedProviding {
    let endpoint: URL?
    var session: URLSession = .shared
    func fetch() async throws -> DisasterFeed {
        guard let endpoint else { throw DisasterFeedError.notConfigured }
        guard Self.isHTTPS(endpoint) else { throw DisasterFeedError.invalidEndpoint }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request, delegate: DisasterRedirectGuard(host: endpoint.host!))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, Self.isHTTPS(finalURL), finalURL.host == endpoint.host,
              bytes.count <= 2_000_000, http.mimeType == "application/json" else { throw DisasterFeedError.invalidResponse }
        let feed = try JSONDecoder().decode(DisasterFeed.self, from: bytes)
        guard feed.schemaVersion == 1 else { throw DisasterFeedError.unsupportedSchema }
        return feed
    }
    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}

private final class DisasterRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && url?.host == host && url?.user == nil && url?.password == nil ? request : nil)
    }
}

/// Parsing remains deliberately narrow: unfamiliar wording preserves the alarm.
enum DisasterNoticeParser {
    enum State: String, Sendable { case suspended, normal, unknown }
    enum DayPart: String, Sendable { case full, morning, noon, afternoon, evening }
    struct Parsed: Sendable {
        var area: String
        var targetDateToken: String
        var targetDate: Date?
        var dayPart: DayPart
        var work: State
        var school: State
        var startsAtMinute: Int?
        var isRecognized: Bool
    }
    static var taipeiCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return value
    }
    static func parse(_ notice: DisasterNotice) -> Parsed? {
        guard let pieces = captures(#"^\[停班停課通知\]([^:：]+)[:：](.*)$"#, in: notice.description) else { return nil }
        let area = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = pieces[1].components(separatedBy: "行政院人事行政總處")[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: "。 \n\r\t"))
        guard let parts = captures(#"^(今天|明天|[0-9]{1,2}/[0-9]{1,2})?(上午|中午|下午|晚上)?([0-9]{1,2}:[0-9]{2}起)?(.*)$"#, in: body) else { return nil }
        let token = parts[0]
        let dayPart: DayPart = ["上午": .morning, "中午": .noon, "下午": .afternoon, "晚上": .evening][parts[1]] ?? .full
        var start: Int?
        var validStart = true
        if !parts[2].isEmpty {
            let time = parts[2].dropLast().split(separator: ":").compactMap { Int($0) }
            if time.count == 2, (0...23).contains(time[0]), (0...59).contains(time[1]) {
                var hour = time[0]
                if [.noon, .afternoon, .evening].contains(dayPart), hour < 12 { hour += 12 }
                start = hour * 60 + time[1]
            } else { validStart = false }
        }
        var work = State.unknown, school = State.unknown
        var recognized = true
        switch parts[3] {
        case "停止上班、停止上課", "已達停止上班及上課標準": work = .suspended; school = .suspended
        case "照常上班、照常上課", "未達停止上班及上課標準": work = .normal; school = .normal
        case "照常上班、停止上課": work = .normal; school = .suspended
        case "停止上班、照常上課": work = .suspended; school = .normal
        case "尚未宣布消息", "尚未列入警戒區": break
        default: recognized = false
        }
        let calendar = taipeiCalendar
        let sentDay = calendar.startOfDay(for: notice.sentAt)
        var target: Date?
        if token == "今天" { target = sentDay }
        else if token == "明天" { target = calendar.date(byAdding: .day, value: 1, to: sentDay) }
        else if token.contains("/") {
            let values = token.split(separator: "/").compactMap { Int($0) }
            if values.count == 2 {
                let month = values[0], day = values[1]
                let year = calendar.component(.year, from: sentDay) + (month < calendar.component(.month, from: sentDay) ? 1 : 0)
                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                   calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day { target = date }
            }
        }
        return Parsed(area: area, targetDateToken: token.isEmpty ? "none" : token == "今天" ? "today" : token == "明天" ? "tomorrow" : "explicit:\(token)", targetDate: target, dayPart: dayPart, work: work, school: school, startsAtMinute: start, isRecognized: recognized && validStart)
    }
    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }
}

struct DisasterDecision: Codable, Equatable, Sendable {
    var shouldSkip: Bool
    var noticeIDs: [String]
    var reason: String
    var area: String?
    var sourceUpdatedAt: Date?
    /// Distinguishes incomplete local announcements from an empty feed.
    var status: String
    static func ring(_ reason: String, status: String = "unavailable") -> Self {
        Self(shouldSkip: false, noticeIDs: [], reason: reason, area: nil, sourceUpdatedAt: nil, status: status)
    }
}

enum DisasterSuspensionEvaluator {
    /// How old the downloaded feed may be, and a notice that names no day (spec §8.2).
    static let maximumAge: TimeInterval = 18 * 60 * 60
    /// Spec v4: how many Taipei days before the day it names a notice may be sent.
    static let maximumLeadDays = 2
    static func decision(feed: DisasterFeed?, normalAlarmDate: Date, now: Date, home: DisasterRegion?, destination: DisasterRegion?, observesWork: Bool, observesSchool: Bool) -> DisasterDecision {
        guard observesWork || observesSchool else { return .ring("未選擇停班或停課規則", status: "disabled") }
        let regions = [home, destination].compactMap { $0 }.filter(\.isValid)
        guard !regions.isEmpty else { return .ring("尚未設定台灣行政區", status: "missingRegion") }
        guard let feed, feed.schemaVersion == 1, feed.checkedAt <= now,
              now.timeIntervalSince(feed.checkedAt) <= maximumAge, normalAlarmDate > now else { return .ring("公告尚未更新，維持原鬧鐘") }
        if let source = feed.sourceUpdatedAt, source > feed.checkedAt || source > now { return .ring("公告時間異常，維持原鬧鐘") }
        let calendar = DisasterNoticeParser.taipeiCalendar
        let actual = feed.notices.filter { $0.status == "Actual" }
        // CAP references can be bare identifiers or sender,identifier,sent triples.
        let withdrawn = Set(actual.filter { $0.msgType == "Cancel" || $0.msgType == "Update" }.flatMap(\.references).map { reference in
            let pieces = reference.split(separator: ",", omittingEmptySubsequences: false)
            return pieces.count == 3 ? String(pieces[1]) : reference
        })
        var fallback = DisasterDecision.ring("沒有符合的停班停課公告", status: "noAnnouncement")
        for region in regions {
            let district = DisasterRegion.normalize(region.name), county = DisasterRegion.normalize(region.county)
            var candidates: [(DisasterNotice, DisasterNoticeParser.Parsed)] = []
            for notice in actual where !withdrawn.contains(notice.id) {
                guard let parsed = DisasterNoticeParser.parse(notice) else { continue }
                let area = DisasterRegion.normalize(parsed.area)
                guard area == county || area == district || area.hasPrefix(district) else { continue }
                if let target = parsed.targetDate, !calendar.isDate(target, inSameDayAs: normalAlarmDate) { continue }
                // A newer malformed/cancelled notice must not expose an older positive result.
                candidates.append((notice, parsed))
            }
            guard let newest = candidates.map({ $0.0.sentAt }).max() else { continue }
            let latest = candidates.filter { $0.0.sentAt == newest }
            guard latest.count == 1, let (notice, parsed) = latest.first else {
                fallback = .ring("公告內容有衝突，維持原鬧鐘"); continue
            }
            // Spec v4 (owner, 2026-10-01): a notice that names the alarm's day stays current
            // for that day however long ago it was sent — a 12:00 "明天" turned 18 h old at
            // 06:00 and undid its own skip. The fresh feed above is what proves nothing newer
            // replaced it; the lead limit keeps a year-rolled "M/D" in a frozen archive out.
            // A notice naming no day never suppresses and still ages out after 18 h.
            let lead = parsed.targetDate.flatMap {
                calendar.dateComponents([.day], from: calendar.startOfDay(for: notice.sentAt), to: $0).day
            }
            let isCurrent = lead.map { $0 <= maximumLeadDays } ?? (now.timeIntervalSince(notice.sentAt) <= maximumAge)
            guard notice.sentAt <= now, notice.sentAt <= feed.checkedAt, isCurrent else {
                fallback = .ring("公告已過期或時間異常，維持原鬧鐘"); continue
            }
            let area = DisasterRegion.normalize(parsed.area)
            guard area == county || area == district else {
                fallback = .ring("僅部分地區停班停課，維持原鬧鐘", status: "partialDistrict"); continue
            }
            // A village code must not become a whole-district suspension even if
            // the headline dropped its village name. Empty codes are allowed:
            // historical feed entries do not always carry a geocode.
            guard !notice.geocodes.contains(where: { $0.contains("-") }) else {
                fallback = .ring("僅部分地區停班停課，維持原鬧鐘", status: "partialDistrict"); continue
            }
            guard notice.geocodes.allSatisfy({ $0.range(of: #"^(?:[0-9]{2}|[0-9]{5}|[0-9]{7})$"#, options: .regularExpression) != nil }) else {
                fallback = .ring("公告行政區格式不明，維持原鬧鐘"); continue
            }
            guard notice.msgType == "Alert" || notice.msgType == "Update", parsed.isRecognized,
                  let target = parsed.targetDate, calendar.isDate(target, inSameDayAs: normalAlarmDate) else {
                fallback = .ring("公告尚未確認，維持原鬧鐘", status: parsed.work == .unknown && parsed.school == .unknown ? "undeclared" : "unavailable"); continue
            }
            guard ["Extreme", "Severe", "Minor"].contains(notice.severity),
                  (parsed.work == .suspended) == (notice.severity == "Extreme") else {
                fallback = .ring("公告資訊不一致，維持原鬧鐘"); continue
            }
            let hour = calendar.component(.hour, from: normalAlarmDate)
            let minute = hour * 60 + calendar.component(.minute, from: normalAlarmDate)
            guard parsed.dayPart == .full || (parsed.dayPart == .morning && hour < 12),
                  parsed.startsAtMinute.map({ minute >= $0 }) ?? true else { continue }
            // Owner decision 2026-09-22 (spec v3): with both switches on, either
            // suspension alone is enough — the user asked to be told about both.
            let workSuspended = observesWork && parsed.work == .suspended
            let schoolSuspended = observesSchool && parsed.school == .suspended
            guard workSuspended || schoolSuspended else { continue }
            let type = workSuspended && schoolSuspended ? "停班停課" : workSuspended ? "停班" : "停課"
            return DisasterDecision(shouldSkip: true, noticeIDs: [notice.id], reason: "\(parsed.area)已公告\(type)", area: parsed.area, sourceUpdatedAt: notice.sentAt, status: "suspended")
        }
        return fallback
    }
}
