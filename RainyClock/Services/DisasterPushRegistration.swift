import Foundation
import Security
import UIKit

/// Push is an opportunity to fetch, never an instruction to silence an alarm.
final class DisasterPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await DisasterPushRegistration.shared.received(token: token) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard AppEnvironment.supportsTemporaryClosures,
              userInfo["type"] as? String == "dayoff-sync" else { completionHandler(.noData); return }
        Task { @MainActor in
            let model = CommuteAlarmRefresher.currentModel()
            guard model.effectiveSchedulingSettings.isDisasterSuspensionEnabled else { completionHandler(.noData); return }
            let changed = await model.refreshDisasterSuspensions(force: true)
            completionHandler(model.disasterRefreshFailed ? .failed : (changed ? .newData : .noData))
        }
    }
}

@MainActor
final class DisasterPushRegistration: DisasterSyncReporting {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Identity: Codable, Sendable { var installationId: String; var credential: String }

    static let shared = DisasterPushRegistration(
        serviceURL: AppEnvironment.dayOffServiceURL,
        networkEnabled: !AppEnvironment.isRunningTests,
        supportsTemporaryClosures: AppEnvironment.supportsTemporaryClosures,
        registrationChanged: { enabled in
            if enabled { UIApplication.shared.registerForRemoteNotifications() }
            else { UIApplication.shared.unregisterForRemoteNotifications() }
        })

    private enum Keys {
        static let enabled = "disasterPushEnabled"
        static let token = "disasterPushToken"
        static let pendingReceipt = "disasterPendingSyncReceipt.v1"
        static let deletionPending = "disasterPushDeletionPending"
    }
    private let defaults: UserDefaults
    private let serviceURL: URL?
    private let networkEnabled: Bool
    private let supportsTemporaryClosures: Bool
    private let transport: Transport
    private let identityProvider: @MainActor () -> Identity?
    private let registrationChanged: @MainActor (Bool) -> Void
    // nil supports a pre-receipt installation's first background launch. Once an
    // explicit disable is known, a late report can never enable this service.
    private var enabled: Bool?
    private var isSyncing = false
    private var syncRequested = false
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    private var registeredToken: String?
    private var activeRequest: Task<(Data, HTTPURLResponse), Error>?
    private var latestReceiptIntent: DisasterSyncReceipt?
    private var pendingReceipt: DisasterSyncReceipt? {
        didSet {
            if let pendingReceipt, let data = try? JSONEncoder().encode(pendingReceipt) {
                defaults.set(data, forKey: Keys.pendingReceipt)
            } else { defaults.removeObject(forKey: Keys.pendingReceipt) }
        }
    }
    private var deletionPending: Bool {
        get { defaults.bool(forKey: Keys.deletionPending) }
        set { defaults.set(newValue, forKey: Keys.deletionPending) }
    }
    private var token: String? {
        get { defaults.string(forKey: Keys.token) }
        set { defaults.set(newValue, forKey: Keys.token) }
    }

    /// Tests inject an isolated defaults suite, identity, transport, and no UIKit
    /// hooks. Neither construction nor decoding a pending receipt sends traffic.
    init(serviceURL: URL?, defaults: UserDefaults = .standard, networkEnabled: Bool = true,
         supportsTemporaryClosures: Bool = AppEnvironment.supportsTemporaryClosures,
         transport: Transport? = nil, identityProvider: (@MainActor () -> Identity?)? = nil,
         registrationChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.defaults = defaults
        self.serviceURL = serviceURL
        self.networkEnabled = networkEnabled
        self.supportsTemporaryClosures = supportsTemporaryClosures
        self.transport = transport ?? { try await Self.performHTTP($0) }
        self.identityProvider = identityProvider ?? { Self.loadIdentity() }
        self.registrationChanged = registrationChanged
        enabled = defaults.object(forKey: Keys.enabled) == nil ? nil : defaults.bool(forKey: Keys.enabled)
        if enabled != false, let data = defaults.data(forKey: Keys.pendingReceipt) {
            pendingReceipt = try? JSONDecoder().decode(DisasterSyncReceipt.self, from: data)
        } else {
            pendingReceipt = nil
            defaults.removeObject(forKey: Keys.pendingReceipt)
        }
        latestReceiptIntent = pendingReceipt
    }

    func update(enabled: Bool) async {
        let enabled = enabled && supportsTemporaryClosures
        let shouldRemove = self.enabled == true || token != nil || registeredToken != nil || deletionPending
        self.enabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        if !enabled {
            // Cancel any pending upload before scheduling deletion. A request
            // already received by the server is reconciled by DELETE afterward.
            activeRequest?.cancel()
            pendingReceipt = nil
            latestReceiptIntent = nil
            deletionPending = shouldRemove
        } else {
            deletionPending = false
            // Foreground activation renews server TTL and restores a registration
            // that may have been removed while this process kept its token cached.
            registeredToken = nil
        }
        if networkEnabled, !enabled || validEndpoint != nil { registrationChanged(enabled) }
        await syncLatestState()
    }

    func received(token: String) async {
        guard supportsTemporaryClosures else { return }
        guard token.utf8.count == 64, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return }
        self.token = token.lowercased()
        guard enabled == true else { return }
        await syncLatestState()
    }

    func report(_ receipt: DisasterSyncReceipt) async {
        guard supportsTemporaryClosures, enabled != false else { return }
        if enabled == nil {
            // Only a caller that completed an enabled-feature evaluation reports.
            // This handles legacy cold starts without overriding a later disable.
            enabled = true
            defaults.set(true, forKey: Keys.enabled)
            if networkEnabled, validEndpoint != nil { registrationChanged(true) }
        }
        if let latestReceiptIntent, !receipt.isNewer(than: latestReceiptIntent) {
            if receipt == latestReceiptIntent, pendingReceipt != nil { await syncLatestState() }
            return
        }
        latestReceiptIntent = receipt
        pendingReceipt = receipt
        await syncLatestState()
    }

    /// One serial pump owns registration, receipt, and deletion requests. Failure
    /// keeps the latest receipt; only a later activation/push/new intent retries.
    private func syncLatestState() async {
        syncRequested = true
        if isSyncing {
            await withCheckedContinuation { syncWaiters.append($0) }
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            let waiters = syncWaiters
            syncWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        while syncRequested {
            syncRequested = false
            guard !Task.isCancelled, networkEnabled, validEndpoint != nil else { continue }
            if enabled == false {
                guard deletionPending, let identity = identityProvider() else { continue }
                let response = await request(path: "v1/devices", method: "DELETE", body: Self.credentials(identity))
                if let response, (200..<300).contains(response.1.statusCode) || response.1.statusCode == 404 {
                    registeredToken = nil
                    if enabled == false { deletionPending = false; token = nil }
                }
                continue
            }
            guard enabled == true, let token, let identity = identityProvider() else { continue }
            if registeredToken != token {
                var body = Self.credentials(identity)
                body["deviceToken"] = token
                let response = await request(path: "v1/devices", method: "POST", body: body)
                guard enabled == true, self.token == token else { continue }
                guard let response, (200..<300).contains(response.1.statusCode) else { continue }
                registeredToken = token
            }
            guard enabled == true, !Task.isCancelled, let receipt = pendingReceipt else { continue }
            var body = Self.credentials(identity)
            body["revision"] = receipt.revision
            body["checkedAt"] = DisasterISO8601.string(receipt.checkedAt)
            body["appliedAt"] = DisasterISO8601.string(receipt.appliedAt)
            body["result"] = receipt.result.rawValue
            let response = await request(path: "v1/devices/sync-receipt", method: "POST", body: body)
            guard enabled == true, let response else { continue }
            if response.1.statusCode == 404 {
                // Registration may have been removed on the server. Re-register
                // at the next opportunity; do not start a retry loop here.
                registeredToken = nil
            } else if response.1.statusCode == 200,
                      let result = try? JSONDecoder().decode(ReceiptResponse.self, from: response.0),
                      pendingReceipt == receipt {
                // recorded:false also acknowledges an equal/newer server receipt.
                _ = result.recorded
                pendingReceipt = nil
            }
        }
    }

    private struct ReceiptResponse: Decodable { var recorded: Bool }

    private var validEndpoint: URL? {
        guard let serviceURL, serviceURL.scheme?.lowercased() == "https", serviceURL.host?.isEmpty == false,
              serviceURL.user == nil, serviceURL.password == nil, serviceURL.query == nil,
              serviceURL.fragment == nil else { return nil }
        return serviceURL
    }

    private static func credentials(_ identity: Identity) -> [String: String] {
        ["installationId": identity.installationId, "credential": identity.credential]
    }

    private func request(path: String, method: String, body: [String: String]) async -> (Data, HTTPURLResponse)? {
        guard !Task.isCancelled, let base = validEndpoint, method != "POST" || enabled == true else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let encoded = try? JSONEncoder().encode(body), encoded.count <= 1024 else { return nil }
        request.httpBody = encoded
        let transport = self.transport
        let task = Task { try await transport(request) }
        activeRequest = task
        defer { activeRequest = nil }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, !task.isCancelled, result.0.count <= 1024,
                  result.1.url == request.url else { return nil }
            return result
        } catch { return nil }
    }

    private nonisolated static func performHTTP(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request, delegate: NoRegistrationRedirects())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private static let identityKey = "disaster-push-identity-v1"
    private static func loadIdentity() -> Identity? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "RainyClock",
            kSecAttrAccount as String: identityKey]
        var read = query
        read[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           let value = try? JSONDecoder().decode(Identity.self, from: data) { return value }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let value = Identity(installationId: UUID().uuidString,
            credential: bytes.map { String(format: "%02x", $0) }.joined())
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return value
    }
}

private final class NoRegistrationRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
