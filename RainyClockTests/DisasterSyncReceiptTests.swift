import XCTest
@testable import RainyClock

@MainActor
final class DisasterSyncReceiptTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)
    private let token = String(repeating: "b", count: 64)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(offset: TimeInterval = 0, result: DisasterSyncReceipt.Result = .applied) -> DisasterSyncReceipt {
        DisasterSyncReceipt(revision: revision, checkedAt: date.addingTimeInterval(offset),
            appliedAt: date.addingTimeInterval(offset + 1), result: result)!
    }

    private func defaults() -> UserDefaults {
        let suite = "DisasterSyncReceiptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func manager(_ defaults: UserDefaults, _ stub: ReceiptTransportStub,
                         endpoint: URL = URL(string: "https://receipt.invalid")!) -> DisasterPushRegistration {
        DisasterPushRegistration(serviceURL: endpoint, defaults: defaults,
            supportsTemporaryClosures: true,
            transport: { try await stub.send($0) },
            identityProvider: { .init(installationId: "test-installation", credential: String(repeating: "c", count: 64)) })
    }

    func testReceiptValidationAndPrivacyShape() throws {
        for invalid in [nil, "", String(repeating: "g", count: 64), String(repeating: "a", count: 63), revision + "\n"] {
            XCTAssertNil(DisasterSyncReceipt(revision: invalid, checkedAt: date, appliedAt: date, result: .applied))
        }
        XCTAssertNotNil(DisasterSyncReceipt(revision: revision.uppercased(), checkedAt: date.addingTimeInterval(300), appliedAt: date, result: .applied))
        XCTAssertNil(DisasterSyncReceipt(revision: revision, checkedAt: date.addingTimeInterval(301), appliedAt: date, result: .applied))
        let value = receipt(result: .noAlarm)
        let encoded = try JSONEncoder().encode(value)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["revision", "checkedAt", "appliedAt", "result"])
        XCTAssertEqual(body["result"], "no_alarm")
        XCTAssertEqual(try JSONDecoder().decode(DisasterSyncReceipt.self, from: encoded), value)
        var invalid = body; invalid["result"] = "delivered"
        XCTAssertThrowsError(try JSONDecoder().decode(DisasterSyncReceipt.self, from: JSONEncoder().encode(invalid)))
    }

    func testLegacyFeedWithoutRevisionStillDecodes() throws {
        let data = Data(#"{"schemaVersion":1,"checkedAt":"2026-09-15T00:00:00Z","notices":[]}"#.utf8)
        var feed = try JSONDecoder().decode(DisasterFeed.self, from: data)
        XCTAssertNil(feed.revision)
        feed.revision = revision
        XCTAssertEqual(try JSONDecoder().decode(DisasterFeed.self, from: JSONEncoder().encode(feed)), feed)
    }

    func testRegistersBeforeReceiptAndUploadsOnlyContractFields() async throws {
        let stub = ReceiptTransportStub()
        let service = manager(defaults(), stub)
        await service.received(token: token)
        XCTAssertTrue(stub.requests.isEmpty)
        await service.report(receipt())
        XCTAssertEqual(stub.requests.map { $0.url!.path }, ["/v1/devices", "/v1/devices/sync-receipt"])
        let request = try XCTUnwrap(stub.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["installationId", "credential", "revision", "checkedAt", "appliedAt", "result"])
        XCTAssertEqual(body["revision"], revision)
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testFailurePersistsUntilNextActivationAndRestoresAfterColdLaunch() async {
        let store = defaults()
        let firstStub = ReceiptTransportStub(); firstStub.receiptStatuses = [500]
        let first = manager(store, firstStub)
        await first.received(token: token)
        await first.report(receipt())
        XCTAssertEqual(firstStub.requests.count, 2)
        XCTAssertNotNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        let nextStub = ReceiptTransportStub()
        let relaunched = manager(store, nextStub)
        XCTAssertTrue(nextStub.requests.isEmpty)
        await relaunched.update(enabled: true)
        XCTAssertEqual(nextStub.requests.map { $0.url!.path }, ["/v1/devices", "/v1/devices/sync-receipt"])
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
    }

    func testRegistrationFailureNeverUploadsReceiptAndRetriesAtNextOpportunity() async {
        let store = defaults()
        let stub = ReceiptTransportStub(); stub.registrationStatuses = [500, 200]
        let service = manager(store, stub)
        await service.received(token: token)
        await service.report(receipt())
        XCTAssertEqual(stub.requests.map { $0.url!.path }, ["/v1/devices"])
        XCTAssertNotNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        await service.update(enabled: true)
        XCTAssertEqual(stub.requests.map { $0.url!.path }, ["/v1/devices", "/v1/devices", "/v1/devices/sync-receipt"])
    }

    func testDisableDuringRegistrationClearsReceiptAndDeletesWithoutUploadingIt() async {
        let store = defaults()
        let stub = ReceiptTransportStub(); stub.holdNextPath = "/v1/devices"
        let service = manager(store, stub)
        await service.received(token: token)
        let report = Task { await service.report(receipt()) }
        await stub.waitForRequests(1)
        let disable = Task { await service.update(enabled: false) }
        await Task.yield()
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        stub.release()
        await report.value
        await disable.value
        XCTAssertEqual(stub.requests.map { $0.httpMethod! }, ["POST", "DELETE"])
        await service.report(receipt(offset: 10))
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertFalse(store.bool(forKey: "disasterPushEnabled"))
    }

    func testDisableDuringReceiptCancelsUploadAndStillDeletesRegistration() async {
        let store = defaults()
        let stub = ReceiptTransportStub(); stub.holdNextPath = "/v1/devices/sync-receipt"
        let service = manager(store, stub)
        await service.received(token: token)
        let report = Task { await service.report(receipt()) }
        await stub.waitForRequests(2)
        let disable = Task { await service.update(enabled: false) }
        await Task.yield()
        stub.release()
        await report.value
        await disable.value
        XCTAssertEqual(stub.cancelledRequests, 1)
        XCTAssertEqual(stub.requests.last?.httpMethod, "DELETE")
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        let relaunchedStub = ReceiptTransportStub()
        let relaunched = manager(store, relaunchedStub)
        await relaunched.report(receipt(offset: 20))
        XCTAssertTrue(relaunchedStub.requests.isEmpty)
    }

    func testOlderAcknowledgmentDoesNotDropNewerPendingReceipt() async throws {
        let store = defaults()
        let stub = ReceiptTransportStub(); stub.holdNextPath = "/v1/devices/sync-receipt"
        let service = manager(store, stub)
        await service.received(token: token)
        let original = Task { await service.report(receipt()) }
        await stub.waitForRequests(2)
        let newer = receipt(offset: 10)
        let nextReport = Task { await service.report(newer) }
        await Task.yield()
        let olderReport = Task { await service.report(receipt(offset: -10)) }
        stub.release()
        await original.value
        await nextReport.value
        await olderReport.value
        let sent = stub.requests.filter { $0.url?.path == "/v1/devices/sync-receipt" }
        XCTAssertEqual(sent.count, 2)
        let lastBody = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].httpBody!) as? [String: String])
        XCTAssertEqual(lastBody["checkedAt"], DisasterISO8601.string(newer.checkedAt))
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
    }

    func testRecordedFalseAcknowledgesAnd404ReregistersOnlyOnNextActivation() async {
        let store = defaults()
        let stub = ReceiptTransportStub(); stub.receiptStatuses = [404, 200]; stub.recorded = false
        let service = manager(store, stub)
        await service.received(token: token)
        await service.report(receipt())
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNotNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        await service.update(enabled: true)
        XCTAssertEqual(stub.requests.count, 4)
        XCTAssertEqual(stub.requests[2].url?.path, "/v1/devices")
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
    }

    func testInsecureEndpointNeverCallsTransport() async {
        let store = defaults()
        let stub = ReceiptTransportStub()
        let service = manager(store, stub, endpoint: URL(string: "http://receipt.invalid")!)
        await service.received(token: token)
        await service.report(receipt())
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertNotNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
    }

    func testDeferredReleaseRemovesOldRegistrationAndCannotUploadOrReenable() async throws {
        let store = defaults()
        store.set(true, forKey: "disasterPushEnabled")
        store.set(token, forKey: "disasterPushToken")
        store.set(try JSONEncoder().encode(receipt()), forKey: "disasterPendingSyncReceipt.v1")
        let stub = ReceiptTransportStub()
        var registrationChanges: [Bool] = []
        let service = DisasterPushRegistration(serviceURL: URL(string: "https://receipt.invalid")!, defaults: store,
            transport: { try await stub.send($0) },
            identityProvider: { .init(installationId: "test-installation", credential: String(repeating: "c", count: 64)) },
            registrationChanged: { registrationChanges.append($0) })
        await service.received(token: token)
        await service.report(receipt(offset: 10))
        XCTAssertTrue(stub.requests.isEmpty)
        await service.update(enabled: true)
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(registrationChanges, [false])
        XCTAssertFalse(store.bool(forKey: "disasterPushEnabled"))
        XCTAssertNil(store.data(forKey: "disasterPendingSyncReceipt.v1"))
        await service.received(token: token)
        await service.report(receipt(offset: 20))
        XCTAssertEqual(stub.requests.count, 1)
    }
}

@MainActor
private final class ReceiptTransportStub {
    var requests: [URLRequest] = []
    var registrationStatuses: [Int] = []
    var receiptStatuses: [Int] = []
    var holdNextPath: String?
    var recorded = true
    var cancelledRequests = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let isReceipt = request.url!.path == "/v1/devices/sync-receipt"
        let status: Int
        if request.httpMethod == "DELETE" { status = 204 }
        else if isReceipt { status = receiptStatuses.isEmpty ? 200 : receiptStatuses.removeFirst() }
        else { status = registrationStatuses.isEmpty ? 200 : registrationStatuses.removeFirst() }
        if request.url?.path == holdNextPath {
            holdNextPath = nil
            await withCheckedContinuation { continuation = $0 }
        }
        if Task.isCancelled { cancelledRequests += 1; throw CancellationError() }
        let data = Data("{\"recorded\":\(recorded)}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }

    func release() { continuation?.resume(); continuation = nil }

    func waitForRequests(_ count: Int) async {
        for _ in 0..<10_000 {
            if requests.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected fake transport request was not issued")
    }
}
