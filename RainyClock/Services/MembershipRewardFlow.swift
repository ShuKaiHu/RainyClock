import Foundation

/// A client reward callback only starts polling. The LevelPlay-signed server
/// callback is the only code path allowed to increase membership credits.
@MainActor
final class MembershipRewardFlow {
    static let shared = MembershipRewardFlow()
    struct Attempt {
        let memberId: String
        let grantCount: Int
    }

    func prepare() async throws -> Attempt {
        let manager = MembershipManager.shared
        guard manager.isConfigured, !manager.isLocalStoreKitTesting else {
            throw MembershipError.notConfigured
        }
        try await manager.ensureIdentity()
        guard let snapshot = manager.snapshot, let count = snapshot.quota.rewardGrantCount else {
            throw MembershipError.unverified
        }
        try await manager.configureAdvertisingForVerifiedSession()
        guard manager.snapshot?.memberId == snapshot.memberId else { throw MembershipError.sessionExpired }
        return Attempt(memberId: snapshot.memberId, grantCount: count)
    }

    func waitForCredit(attempt: Attempt) async throws {
        let manager = MembershipManager.shared
        for delay in [0, 1, 2, 3, 5, 8, 10] {
            try await Task.sleep(for: .seconds(delay))
            guard manager.snapshot?.memberId == attempt.memberId else { throw MembershipError.sessionExpired }
            let data = try await manager.performAuthenticated(path: "/v1/membership/status", expectedMemberId: attempt.memberId)
            let value = try JSONDecoder().decode(MembershipSnapshot.self, from: data)
            guard value.memberId == attempt.memberId, manager.snapshot?.memberId == attempt.memberId else {
                throw MembershipError.sessionExpired
            }
            try manager.updateSnapshot(data)
            // Another device may already have spent the credit. Confirm the
            // monotonic verified grant count, not the current spendable balance.
            if (value.quota.rewardGrantCount ?? 0) > attempt.grantCount { return }
        }
        // Credit may arrive later; do not manufacture one to hide latency.
        throw MembershipError.server("reward_confirmation_pending", 202)
    }
}
