import Foundation
import CryptoKit
import DeviceCheck
import Security

struct MembershipKeychain: Sendable {
    var service = MembershipConfiguration.keychainService

    func membershipWasDeleted(for verifiedAccountIdentity: String) -> Bool {
        if read(Bool.self, key: deletionKey(for: verifiedAccountIdentity)) == true { return true }
        guard read(Bool.self, key: "dataDeleted") == true else { return false }
        if let deletedIdentity = read(String.self, key: "deletedAccountIdentity") {
            return deletedIdentity == verifiedAccountIdentity
        }
        if let storedIdentity = read(String.self, key: "accountIdentity") {
            return storedIdentity == verifiedAccountIdentity
        }
        // Earlier versions removed accountIdentity on deletion. Without a bound
        // identity, require an explicit action rather than silently re-register.
        return true
    }

    func markMembershipDeleted(for verifiedAccountIdentity: String) throws {
        try write(true, key: deletionKey(for: verifiedAccountIdentity))
        try write(verifiedAccountIdentity, key: "deletedAccountIdentity")
        try write(true, key: "dataDeleted")
    }

    func clearMembershipDeletion(for verifiedAccountIdentity: String) throws {
        remove(deletionKey(for: verifiedAccountIdentity))
        let legacyIdentity = read(String.self, key: "deletedAccountIdentity")
        if legacyIdentity == nil || legacyIdentity == verifiedAccountIdentity {
            try write(false, key: "dataDeleted")
            remove("deletedAccountIdentity")
        }
    }

    private func deletionKey(for identity: String) -> String {
        "deletedAccount." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw keychainFailure(status) }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainFailure(added) }
    }

    private func keychainFailure(_ status: OSStatus) -> MembershipDiagnosticFailure {
        MembershipDiagnosticFailure(cause: MembershipError.keychainUnavailable,
            diagnostic: MembershipDiagnostic(stage: .keychain,
                error: NSError(domain: NSOSStatusErrorDomain, code: Int(status))))
    }

    func remove(_ key: String) { SecItemDelete(query(key) as CFDictionary) }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
}

struct MembershipChallenge: Decodable, Sendable {
    let id: String
    let challenge: String
    let expiresAt: Double
}

enum MembershipRequestBinding {
    static func hash(purpose: String, challenge: MembershipChallenge, method: String,
                     path: String, body: Data) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let content = ["RainyClockMembershipV1", purpose, challenge.id, challenge.challenge,
                       method.uppercased(), path, bodyHash].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(content.utf8)))
    }
}

actor MembershipDeviceProof {
    private let keychain: MembershipKeychain

    init(keychain: MembershipKeychain = MembershipKeychain()) {
        self.keychain = keychain
    }

    func keyID() async throws -> String {
        do {
            guard DCAppAttestService.shared.isSupported else { throw MembershipError.deviceUnsupported }
            if let existing = keychain.read(String.self, key: "attestKeyID") { return existing }
            let id = try await DCAppAttestService.shared.generateKey()
            try keychain.write(id, key: "attestKeyID")
            return id
        } catch { throw MembershipDiagnosticFailure.wrapping(error, at: .appAttestKey) }
    }

    func headers(keyID: String, hash: Data, bootstrap: Bool) async throws -> [String: String] {
        if bootstrap && keychain.read(String.self, key: "attestedKeyID") != keyID {
            let data: Data
            do { data = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash) }
            catch { throw MembershipDiagnosticFailure.wrapping(error, at: .appAttestRegistration) }
            // Apple permits attestation only once per key. Record that immediately;
            // if the upload/response is lost, retry with an assertion on the same key.
            // A server that never received registration answers key_not_registered.
            try markAttested(keyID)
            return ["X-RC-Attestation": data.base64EncodedString()]
        }
        let data: Data
        do { data = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash) }
        catch { throw MembershipDiagnosticFailure.wrapping(error, at: .appAttestAssertion) }
        return ["X-RC-Assertion": data.base64EncodedString()]
    }

    func markAttested(_ keyID: String) throws { try keychain.write(keyID, key: "attestedKeyID") }

    /// App Attest keys do not survive reinstall; a stale key cannot silently bypass proof.
    func resetInvalidKey() {
        keychain.remove("attestKeyID")
        keychain.remove("attestedKeyID")
    }

    /// Keychain items outlive the app; its Secure Enclave key does not. After a
    /// reinstall, restore or migration the stored ID names a key this install lacks,
    /// which Apple reports as invalidInput (not only invalidKey). serverUnavailable
    /// means retry with the same key and never counts.
    nonisolated static func isUnusableLocalKey(_ error: Error) -> Bool {
        guard let deviceError = MembershipDiagnosticFailure.original(error) as? DCError else { return false }
        return deviceError.code == .invalidKey || deviceError.code == .invalidInput
    }

    /// Bootstrap only: it carries a fresh Apple proof and retries once, so a new key
    /// is still attested. A stored key can also fail its assertion with
    /// unknownSystemFailure; a failed attestation of a new key never rotates on it.
    ///
    /// `invalid_assertion` is the server rejecting a key it does know (signature or
    /// counter): on 2026-10-03 the owner's phone hit it on every launch after moving
    /// between TestFlight and App Store installs, and nothing on the phone could
    /// recover because only the codes below rotated. A rotated key still has to pass
    /// attestation and the server's replay checks, so this grants nothing.
    nonisolated static func requiresKeyRotation(_ error: Error) -> Bool {
        if isUnusableLocalKey(error) { return true }
        let original = MembershipDiagnosticFailure.original(error)
        if let deviceError = original as? DCError {
            return deviceError.code == .unknownSystemFailure
                && (error as? MembershipDiagnosticFailure)?.diagnostic.stage == .appAttestAssertion
        }
        if case MembershipError.server(let code, _) = original {
            return ["key_not_registered", "invalid_key", "invalid_assertion", "attestation_key_rotation_required"].contains(code)
        }
        return false
    }
}
