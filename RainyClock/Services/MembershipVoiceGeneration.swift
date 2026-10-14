import Foundation
import CryptoKit

struct MembershipGenerationInput: Codable, Equatable, Sendable {
    let text: String
    let persona: String
    let language: String

    func persistenceKey(memberId: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = try encoder.encode(self)
        let bytes = Data(memberId.utf8) + Data([0]) + input
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct MembershipPendingGeneration: Codable, Equatable, Sendable {
    let requestId: String
    let memberId: String
    let input: MembershipGenerationInput
    let createdAt: Date
}

/// Contains only unfinished requests, excluded from device backups. Atomic protected
/// files are written before networking, so a crash cannot silently create another job.
struct MembershipGenerationJournal {
    let directory: URL

    static var standard: Self {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: base.appendingPathComponent("MembershipPendingGenerations", isDirectory: true))
    }

    func pending(memberId: String, input: MembershipGenerationInput) throws -> MembershipPendingGeneration? {
        let location = try url(memberId: memberId, input: input)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        // A corrupt journal fails closed; treating it as empty could double-generate.
        let pending = try JSONDecoder().decode(MembershipPendingGeneration.self, from: Data(contentsOf: location))
        guard pending.memberId == memberId, pending.input == input else { throw MembershipError.unverified }
        return pending
    }

    func save(_ value: MembershipPendingGeneration) throws {
        let target = try url(memberId: value.memberId, input: value.input)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        try JSONEncoder().encode(value).write(to: target,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ value: MembershipPendingGeneration) throws {
        let location = try url(memberId: value.memberId, input: value.input)
        // Completing an old response cannot remove a newer attempt's journal.
        guard try pending(memberId: value.memberId, input: value.input)?.requestId == value.requestId else { return }
        try FileManager.default.removeItem(at: location)
    }

    func removeMember(_ memberId: String) throws {
        let location = memberDirectory(memberId)
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
    }

    func url(memberId: String, input: MembershipGenerationInput) throws -> URL {
        memberDirectory(memberId).appendingPathComponent(try input.persistenceKey(memberId: memberId) + ".json")
    }

    private func memberDirectory(_ memberId: String) -> URL {
        let identifier = SHA256.hash(data: Data(memberId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(identifier, isDirectory: true)
    }
}

enum MembershipGenerationResult {
    case speech(Data, MembershipPendingGeneration)
    case pending
    case expired(MembershipPendingGeneration)
}

@MainActor
final class MembershipVoiceGeneration {
    static let shared = MembershipVoiceGeneration()
    private let journal = MembershipGenerationJournal.standard
    private let membership = MembershipManager.shared

    func generate(_ text: String, persona: VoicePersona, replaceExpired: MembershipPendingGeneration? = nil) async throws -> MembershipGenerationResult {
        try await membership.ensureIdentity()
        guard let memberId = membership.snapshot?.memberId else { throw MembershipError.missingIdentity }
        let input = MembershipGenerationInput(text: text, persona: persona.rawValue,
            language: Locale.current.language.languageCode?.identifier == "zh" ? "zh-Hant" : "en-US")
        if let replaceExpired {
            guard replaceExpired.memberId == memberId, replaceExpired.input == input else { throw MembershipError.unverified }
            // This branch is only reachable after an explicit new-charge confirmation.
            try journal.remove(replaceExpired)
        }
        let existing = try journal.pending(memberId: memberId, input: input)
        let pending = existing ?? MembershipPendingGeneration(requestId: UUID().uuidString,
            memberId: memberId, input: input, createdAt: Date())
        if existing == nil { try journal.save(pending) }
        do {
            var data: Data
            if existing != nil {
                do { data = try await result(pending) }
                catch MembershipError.server(let code, let status) where code == "generation_not_found" && status == 404 {
                    // Original request may never have reached the server. Resubmit the
                    // SAME id and body; the server atomically arbitrates any race.
                    data = try await submit(pending)
                }
            } else { data = try await submit(pending) }

            for attempt in 0..<9 {
                let response = try JSONDecoder().decode(Response.self, from: data)
                if let state = response.state {
                    guard state.memberId == pending.memberId else { throw MembershipError.unverified }
                    // Another screen may have established a different account while
                    // this HTTP request was in flight. Never replace that account's UI.
                    guard membership.snapshot?.memberId == pending.memberId else { throw MembershipError.sessionExpired }
                    try membership.updateSnapshot(JSONEncoder().encode(state))
                }
                if response.status == "succeeded" {
                    guard response.sampleRate == Int(GeneratedVoiceAssembler.speechSampleRate),
                          let encoded = response.pcm, let pcm = Data(base64Encoded: encoded),
                          !pcm.isEmpty, pcm.count <= 600_000, pcm.count.isMultiple(of: 2) else { throw MembershipError.unverified }
                    return .speech(pcm, pending)
                }
                guard ["processing", "uncertain"].contains(response.status) else { throw MembershipError.unverified }
                if attempt == 8 { return .pending }
                try await Task.sleep(for: .milliseconds(1_500))
                data = try await result(pending)
            }
            return .pending
        } catch MembershipError.server(let code, let status) {
            if status == 410 && code == "generation_result_expired" { return .expired(pending) }
            // Only definitive server outcomes release the local request ID. Network
            // failures/unknown commit states retain it and recover the same result.
            if ["generation_failed", "generation_interrupted", "rejected", "quota_exhausted",
                "legacy_migration_pending", "invalid_generation_input"].contains(code) {
                try journal.remove(pending)
                try? await membership.refreshStatus()
            }
            throw MembershipError.server(code, status)
        }
    }

    /// Call only after the WAV was reliably saved and attached to local settings.
    func complete(_ pending: MembershipPendingGeneration) throws { try journal.remove(pending) }

    private func submit(_ pending: MembershipPendingGeneration) async throws -> Data {
        let payload = Request(requestId: pending.requestId, input: pending.input)
        return try await membership.performAuthenticated(path: "/v1/membership/generations", body: JSONEncoder().encode(payload), expectedMemberId: pending.memberId)
    }

    private func result(_ pending: MembershipPendingGeneration) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["requestId": pending.requestId])
        return try await membership.performAuthenticated(path: "/v1/membership/generations/result", body: body, expectedMemberId: pending.memberId)
    }

    private struct Request: Encodable { let requestId: String; let input: MembershipGenerationInput }
    private struct Response: Decodable {
        let status: String
        let pcm: String?
        let sampleRate: Int?
        let state: MembershipSnapshot?
    }
}
