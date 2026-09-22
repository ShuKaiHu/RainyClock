import XCTest
@testable import RainyClock

@MainActor
final class MembershipLegacyPriceProbeTests: XCTestCase {
    private let monthly = MembershipLegacyPriceQuote(productID: "monthly", displayPrice: "$1.00", currencyCode: "USD")
    private let lifetime = MembershipLegacyPriceQuote(productID: "lifetime", displayPrice: "$10.00", currencyCode: "USD")

    func testSynchronousResponseIsSortedFilteredAndDeduplicated() async throws {
        let unexpected = MembershipLegacyPriceQuote(productID: "unexpected", displayPrice: "$2.00", currencyCode: "USD")
        let request = FakeRequest(resultOnStart: .success([monthly, unexpected, lifetime, monthly]))
        var requestedIDs: Set<String> = []
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { ids in
            requestedIDs = ids
            return request
        }
        let result = try await probe.load(productIDs: ["monthly", "lifetime"])
        XCTAssertEqual(requestedIDs, ["monthly", "lifetime"])
        XCTAssertEqual(result, [lifetime, monthly])
        XCTAssertEqual(request.startCount, 1)
        XCTAssertEqual(request.cancelCount, 1)
        XCTAssertNil(request.completion)
    }

    func testEmptyProductIDsDoNotStartARequest() async throws {
        var factoryCalls = 0
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in
            factoryCalls += 1
            return FakeRequest()
        }
        let result = try await probe.load(productIDs: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(factoryCalls, 0)
    }

    func testTimeoutCancelsAndReleasesCallback() async {
        let request = FakeRequest()
        let probe = MembershipLegacyPriceProbe(timeout: .milliseconds(20)) { _ in request }
        do {
            _ = try await probe.load(productIDs: ["monthly"])
            XCTFail("A missing delegate response must time out")
        } catch {
            XCTAssertEqual(error as? MembershipLegacyPriceProbeError, .timedOut)
        }
        XCTAssertEqual(request.startCount, 1)
        XCTAssertEqual(request.cancelCount, 1)
        XCTAssertNil(request.completion)
    }

    func testRequestFailureCancelsAndReleasesCallback() async {
        let request = FakeRequest(resultOnStart: .failure(MembershipLegacyPriceProbeError.requestFailed))
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in request }
        do {
            _ = try await probe.load(productIDs: ["monthly"])
            XCTFail("A failed SDK request must fail the diagnostic")
        } catch {
            XCTAssertEqual(error as? MembershipLegacyPriceProbeError, .requestFailed)
        }
        XCTAssertEqual(request.cancelCount, 1)
        XCTAssertNil(request.completion)
    }

    func testCancellationBeforeLoadDoesNotCreateRequest() async {
        var factoryCalls = 0
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in
            factoryCalls += 1
            return FakeRequest()
        }
        // Both creation and cancellation happen on MainActor before this task can run.
        let task = Task { try await probe.load(productIDs: ["monthly"]) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An already cancelled caller must not start StoreKit")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(factoryCalls, 0)
    }

    func testInFlightCancellationIgnoresLateDelegateResult() async {
        let request = FakeRequest()
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in request }
        let task = Task { try await probe.load(productIDs: ["monthly"]) }
        await request.waitForStart()
        let lateCallback = request.completion
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must finish without waiting for StoreKit")
        } catch { XCTAssertTrue(error is CancellationError) }
        lateCallback?(.success([monthly]))
        XCTAssertEqual(request.cancelCount, 1)
        XCTAssertNil(request.completion)
    }

    func testDuplicateCompletionOnlyFinishesOnce() async throws {
        let request = FakeRequest()
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in request }
        let task = Task { try await probe.load(productIDs: ["monthly"]) }
        await request.waitForStart()
        let callback = request.completion
        callback?(.success([monthly]))
        callback?(.failure(MembershipLegacyPriceProbeError.requestFailed))
        let result = try await task.value
        XCTAssertEqual(result, [monthly])
        XCTAssertEqual(request.cancelCount, 1)
    }

    func testConcurrentLoadsHaveIndependentCancellationAndResults() async throws {
        let first = FakeRequest()
        let second = FakeRequest()
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { ids in
            ids.contains("monthly") ? first : second
        }
        let firstTask = Task { try await probe.load(productIDs: ["monthly"]) }
        let secondTask = Task { try await probe.load(productIDs: ["lifetime"]) }
        await first.waitForStart()
        await second.waitForStart()
        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("Only the first caller cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(second.cancelCount, 0)
        second.send(.success([lifetime]))
        let result = try await secondTask.value
        XCTAssertEqual(result, [lifetime])
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 1)
    }

    func testOperationRetainsRequestUntilCompletionAndThenReleasesIt() async throws {
        weak var activeRequest: FakeRequest?
        let probe = MembershipLegacyPriceProbe(timeout: .seconds(2)) { _ in
            let request = FakeRequest(resultOnStart: .success([self.monthly]))
            activeRequest = request
            return request
        }
        let result = try await probe.load(productIDs: ["monthly"])
        XCTAssertEqual(result, [monthly])
        XCTAssertNil(activeRequest)
    }

    func testFormatterUsesAppleProductLocaleAndUnconvertedPrice() throws {
        let price = NSDecimalNumber(string: "12.50")
        for (localeID, currency) in [("en_US", "USD"), ("zh_TW", "TWD")] {
            let locale = Locale(identifier: localeID)
            let quote = try MembershipLegacyPriceQuote.formatted(productID: "monthly", price: price, locale: locale)
            let expected = NumberFormatter()
            expected.numberStyle = .currency
            expected.locale = locale
            XCTAssertEqual(quote.currencyCode, currency)
            XCTAssertEqual(quote.displayPrice, expected.string(from: price))
        }
    }

    func testFormatterRejectsMissingCurrencyAndInvalidPrice() {
        let us = Locale(identifier: "en_US")
        let missingCurrency = Locale(identifier: "en")
        XCTAssertNil(missingCurrency.currency)
        for (id, price, locale) in [
            ("", NSDecimalNumber.one, us),
            ("monthly", NSDecimalNumber.notANumber, us),
            ("monthly", NSDecimalNumber(string: "-1"), us),
            ("monthly", NSDecimalNumber.one, missingCurrency)
        ] {
            XCTAssertThrowsError(try MembershipLegacyPriceQuote.formatted(productID: id, price: price, locale: locale)) {
                XCTAssertEqual($0 as? MembershipLegacyPriceProbeError, .invalidResponse)
            }
        }
    }

    @MainActor
    private final class FakeRequest: MembershipLegacyPriceRequest {
        var startCount = 0
        var cancelCount = 0
        var completion: (@MainActor (Result<[MembershipLegacyPriceQuote], any Error>) -> Void)?
        private let resultOnStart: Result<[MembershipLegacyPriceQuote], any Error>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        init(resultOnStart: Result<[MembershipLegacyPriceQuote], any Error>? = nil) {
            self.resultOnStart = resultOnStart
        }

        func start(completion: @escaping @MainActor (Result<[MembershipLegacyPriceQuote], any Error>) -> Void) {
            startCount += 1
            self.completion = completion
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
            if let resultOnStart { completion(resultOnStart) }
        }

        func waitForStart() async {
            guard startCount == 0 else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func send(_ result: Result<[MembershipLegacyPriceQuote], any Error>) {
            completion?(result)
        }

        func cancel() {
            cancelCount += 1
            completion = nil
        }
    }
}
