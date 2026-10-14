import Foundation

struct MembershipAppleProof: Sendable {
    let environment: MembershipAppleEnvironment
    let signedAppTransaction: String
    let appTransactionID: String
    let deviceVerificationID: String
    let signedTransactions: [String]
}

/// Serializes challenge/assertion pairs so App Attest's monotonic counter cannot arrive
/// out of order when two parts of the UI request membership updates together.
actor MembershipClient {
    private let routing: MembershipRouting
    private let deviceProof: MembershipDeviceProof
    private let keychain: MembershipKeychain
    private let network: URLSession
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(routing: MembershipRouting, network: URLSession = .shared) {
        self.routing = routing
        let keychain = MembershipKeychain(service: routing.keychainService)
        self.keychain = keychain
        self.deviceProof = MembershipDeviceProof(keychain: keychain)
        self.network = network
    }

    func bootstrap(_ proof: MembershipAppleProof) async throws -> MembershipSession {
        guard proof.environment == routing.appleEnvironment else { throw MembershipError.unverified }
        await acquire()
        defer { release() }
        // Retry only an invalid/missing App Attest key, including one left in the
        // keychain by an earlier install. Network failures cannot create a new key or
        // make an unverified session usable.
        do { return try await establish(proof) }
        catch {
            guard MembershipDeviceProof.requiresKeyRotation(error) else { throw error }
            await deviceProof.resetInvalidKey()
            // This retries once, with another server challenge and the already fresh
            // Apple proof. The server still enforces its five-minute proof age limit.
            return try await establish(proof)
        }
    }

    func forgetDeletedMembership() async {
        await acquire()
        defer { release() }
        keychain.remove("session")
        await deviceProof.resetInvalidKey()
    }

    private func establish(_ proof: MembershipAppleProof) async throws -> MembershipSession {
        do {
            let keyID = try await deviceProof.keyID()
            let body = try JSONSerialization.data(withJSONObject: [
                "signedAppTransaction": proof.signedAppTransaction,
                "deviceVerificationID": proof.deviceVerificationID,
                "keyID": keyID,
                "signedTransactions": proof.signedTransactions,
                "timeZone": TimeZone.current.identifier
            ])
            let challenge = try await challenge(purpose: "bootstrap", keyID: keyID)
            let path = "/v1/membership/session"
            let hash = MembershipRequestBinding.hash(purpose: "bootstrap", challenge: challenge,
                                                    method: "POST", path: path, body: body)
            var headers = try await deviceProof.headers(keyID: keyID, hash: hash, bootstrap: true)
            headers["X-RC-Challenge"] = challenge.id
            headers["X-RC-Key-ID"] = keyID
            let data = try await send(path: path, body: body, headers: headers)
            let session = try JSONDecoder().decode(MembershipSession.self, from: data)
            guard !session.token.isEmpty, session.isValid,
                  session.memberId == session.state.memberId,
                  session.state.environment == routing.appleEnvironment.rawValue else { throw MembershipError.unverified }
            try await deviceProof.markAttested(keyID)
            // Only the MainActor owner may persist this session, after confirming
            // that its verified account and environment have not changed in flight.
            return session
        } catch { throw MembershipDiagnosticFailure.wrapping(error, at: .session) }
    }

    func request(path: String, body: Data = Data("{}".utf8), expectedMemberId: String? = nil) async throws -> Data {
        await acquire()
        defer { release() }
        guard let session = keychain.read(MembershipSession.self, key: "session"), session.isValid,
              session.state.environment == routing.appleEnvironment.rawValue else {
            throw MembershipError.sessionExpired
        }
        if let expectedMemberId, session.memberId != expectedMemberId { throw MembershipError.sessionExpired }
        let keyID = try await deviceProof.keyID()
        let challenge = try await challenge(purpose: "request", keyID: keyID, token: session.token)
        let hash = MembershipRequestBinding.hash(purpose: "request", challenge: challenge,
                                                method: "POST", path: path, body: body)
        var headers = try await deviceProof.headers(keyID: keyID, hash: hash, bootstrap: false)
        headers["X-RC-Challenge"] = challenge.id
        headers["X-RC-Key-ID"] = keyID
        headers["Authorization"] = "Bearer \(session.token)"
        return try await send(path: path, body: body, headers: headers)
    }

    private func challenge(purpose: String, keyID: String, token: String? = nil) async throws -> MembershipChallenge {
        do {
            var payload = ["purpose": purpose, "keyID": keyID]
            if let token { payload["sessionToken"] = token }
            let data = try await send(path: "/v1/membership/challenge", body: JSONSerialization.data(withJSONObject: payload))
            let value = try JSONDecoder().decode(MembershipChallenge.self, from: data)
            guard value.expiresAt > Date().timeIntervalSince1970 * 1_000 else { throw MembershipError.sessionExpired }
            return value
        } catch { throw MembershipDiagnosticFailure.wrapping(error, at: .challenge) }
    }

    private func send(path: String, body: Data, headers: [String: String] = [:]) async throws -> Data {
        let request = try Self.makeRequest(routing: routing, path: path, body: body, headers: headers)
        let data: Data, response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch {
            let stage: MembershipDiagnosticStage = path == "/v1/membership/challenge" ? .challengeNetwork
                : path == "/v1/membership/session" ? .sessionNetwork : .requestNetwork
            throw MembershipDiagnosticFailure.wrapping(error, at: stage)
        }
        guard let http = response as? HTTPURLResponse else { throw MembershipError.unavailable }
        guard (200...299).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? json?["code"] as? String ?? "unavailable"
            throw MembershipError.server(code, http.statusCode)
        }
        // The service's build floor rides on its session and status answers. Handed over
        // off the request path: the gate owns the comparison and the screen.
        if let minimum = Self.minimumSupportedBuild(in: data) {
            Task { @MainActor in AppUpdateGate.shared.record(minimumSupportedBuild: minimum) }
        }
        return data
    }

    /// `minimumSupportedBuild` from a membership answer, when it carries one: a whole
    /// number of builds, never negative. Anything else is "no answer", not 0.
    nonisolated static func minimumSupportedBuild(in data: Data) -> Int? {
        struct Envelope: Decodable { var minimumSupportedBuild: Int? }
        guard let value = (try? JSONDecoder().decode(Envelope.self, from: data))?.minimumSupportedBuild,
              value >= 0 else { return nil }
        return value
    }

    nonisolated static func makeRequest(routing: MembershipRouting, path: String, body: Data,
                                        headers: [String: String] = [:]) throws -> URLRequest {
        guard path.hasPrefix("/v1/membership/"), !path.contains(".."), !path.contains("?") else {
            throw MembershipError.unavailable
        }
        var request = URLRequest(url: routing.baseURL.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(routing.appleEnvironment.rawValue, forHTTPHeaderField: "X-RC-Apple-Environment")
        // Which build is asking, so the service can tell old installs apart (1.8.2+).
        request.setValue(AppBuildInfo.buildString, forHTTPHeaderField: "X-RC-App-Build")
        request.setValue(AppBuildInfo.version, forHTTPHeaderField: "X-RC-App-Version")
        return request
    }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}
