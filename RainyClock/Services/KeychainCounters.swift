import Foundation
import Security

/// A few small integers that have to outlive the app's own container.
///
/// `UserDefaults` is deleted with the app; a generic-password keychain item is
/// not, so a count written here is still there after a delete-and-reinstall.
/// Nothing about this is an identifier: each item is a number keyed by a
/// name the app chose, readable only by this app on this device, and never
/// sent anywhere. It is marked *this device only* and left non-synchronising,
/// so it does not travel through iCloud Keychain to another phone either.
///
/// Apple documents no guarantee that keychain items survive uninstall — it is
/// long-standing behaviour rather than a contract — so the counts are stored
/// as a courtesy to fairness, not as a security boundary. The server-side
/// daily budget in `weather-proxy` is the boundary.
struct KeychainCounters {
    let service: String

    func integer(forKey key: String) -> Int? {
        var query = self.query(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Int(text)
    }

    /// Returns the keychain's status so a caller can tell "written" from
    /// "this process may not use the keychain" — an unsigned build cannot, and
    /// nothing in the API says so except this value.
    @discardableResult
    func set(_ value: Int, forKey key: String) -> OSStatus {
        let data = Data(String(value).utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(forKey: key) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else {
            return status
        }

        var add = query(forKey: key)
        add[kSecValueData as String] = data
        // Readable once the device has been unlocked after boot, which is when
        // a background refresh or an alarm-time read could plausibly need it.
        // "ThisDeviceOnly" keeps it out of encrypted backups restored onto a
        // different device — the count belongs to the phone, not the person.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Removes every counter under this service. Used by tests to start clean.
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
