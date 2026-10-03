import Foundation

/// A receipt confirms a completed local evaluation, never notification delivery.
/// It deliberately contains no locations, alarm times, or skipped dates.
struct DisasterSyncReceipt: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable {
        case applied
        case noAlarm = "no_alarm"
    }

    let revision: String
    let checkedAt: Date
    let appliedAt: Date
    let result: Result

    init?(revision: String?, checkedAt: Date, appliedAt: Date, result: Result) {
        guard let revision, revision.utf8.count == 64,
              revision.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              checkedAt.timeIntervalSince1970.isFinite, appliedAt.timeIntervalSince1970.isFinite,
              checkedAt.timeIntervalSince(appliedAt) <= 300 else { return nil }
        self.revision = revision.lowercased()
        self.checkedAt = checkedAt
        self.appliedAt = appliedAt
        self.result = result
    }

    func isNewer(than other: Self) -> Bool {
        checkedAt > other.checkedAt || (checkedAt == other.checkedAt && appliedAt > other.appliedAt)
    }

    private enum CodingKeys: String, CodingKey { case revision, checkedAt, appliedAt, result }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try values.decode(String.self, forKey: .revision)
        let checkedAt = try DisasterISO8601.decode(values.decode(String.self, forKey: .checkedAt), codingPath: decoder.codingPath)
        let appliedAt = try DisasterISO8601.decode(values.decode(String.self, forKey: .appliedAt), codingPath: decoder.codingPath)
        let result = try values.decode(Result.self, forKey: .result)
        guard let receipt = Self(revision: revision, checkedAt: checkedAt, appliedAt: appliedAt, result: result) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid disaster sync receipt"))
        }
        self = receipt
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(DisasterISO8601.string(checkedAt), forKey: .checkedAt)
        try values.encode(DisasterISO8601.string(appliedAt), forKey: .appliedAt)
        try values.encode(result, forKey: .result)
    }
}

@MainActor
protocol DisasterSyncReporting {
    func report(_ receipt: DisasterSyncReceipt) async
}
