import Foundation
import StoreKit

struct MembershipLegacyPriceQuote: Equatable, Sendable {
    let productID: String
    let displayPrice: String
    let currencyCode: String

    /// Formatting is tied to Apple's product locale, never the phone's language
    /// or location. An incomplete response must not manufacture a currency.
    static func formatted(productID: String, price: NSDecimalNumber, locale: Locale) throws -> Self {
        guard !productID.isEmpty, !price.decimalValue.isNaN,
              price.compare(NSDecimalNumber.zero) != .orderedAscending,
              let currency = locale.currency?.identifier, !currency.isEmpty else {
            throw MembershipLegacyPriceProbeError.invalidResponse
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        guard let display = formatter.string(from: price), !display.isEmpty else {
            throw MembershipLegacyPriceProbeError.invalidResponse
        }
        return Self(productID: productID, displayPrice: display, currencyCode: currency)
    }
}

enum MembershipLegacyPriceProbeError: Error, Equatable {
    case timedOut
    case requestFailed
    case invalidResponse
}

/// A request-only boundary for lifecycle tests. No payment queue or transaction
/// API belongs in this probe, and these results never grant membership rights.
@MainActor
protocol MembershipLegacyPriceRequest: AnyObject {
    func start(completion: @escaping @MainActor (Result<[MembershipLegacyPriceQuote], any Error>) -> Void)
    func cancel()
}

/// Diagnostic only: SK1 is deprecated and may return the same incorrect metadata
/// as SK2 in TestFlight. Reading this API does not bypass that system limitation.
@MainActor
final class MembershipLegacyPriceProbe {
    private let timeout: Duration
    private let requestFactory: @MainActor (Set<String>) -> any MembershipLegacyPriceRequest

    init() {
        timeout = .seconds(10)
        requestFactory = { MembershipStoreKitPriceRequest(productIDs: $0) }
    }

    init(timeout: Duration,
         requestFactory: @escaping @MainActor (Set<String>) -> any MembershipLegacyPriceRequest) {
        self.timeout = timeout
        self.requestFactory = requestFactory
    }

    func load(productIDs: Set<String>) async throws -> [MembershipLegacyPriceQuote] {
        try Task.checkCancellation()
        guard !productIDs.isEmpty else { return [] }
        let operation = MembershipLegacyPriceOperation(request: requestFactory(productIDs), timeout: timeout)
        let quotes = try await operation.value()
        try Task.checkCancellation()
        // Report only the requested product IDs and a deterministic, unique list.
        var seen = Set<String>()
        return quotes.filter { productIDs.contains($0.productID) && seen.insert($0.productID).inserted }
            .sorted { $0.productID < $1.productID }
    }
}

@MainActor
private final class MembershipLegacyPriceOperation {
    private let request: any MembershipLegacyPriceRequest
    private let timeout: Duration
    private var continuation: CheckedContinuation<[MembershipLegacyPriceQuote], any Error>?
    private var timer: Task<Void, Never>?
    private var finished = false

    init(request: any MembershipLegacyPriceRequest, timeout: Duration) {
        self.request = request
        self.timeout = timeout
    }

    func value() async throws -> [MembershipLegacyPriceQuote] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may be delivered before this continuation starts.
                guard !finished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(.failure(MembershipLegacyPriceProbeError.timedOut))
                }
                request.start { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<[MembershipLegacyPriceQuote], any Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        // Clear the delegate before cancelling: a late SDK callback cannot resume
        // a completed continuation or interfere with another independent request.
        request.cancel()
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}

@MainActor
private final class MembershipStoreKitPriceRequest: NSObject, MembershipLegacyPriceRequest, SKProductsRequestDelegate {
    private let productIDs: Set<String>
    private var request: SKProductsRequest?
    private var completion: (@MainActor (Result<[MembershipLegacyPriceQuote], any Error>) -> Void)?

    init(productIDs: Set<String>) { self.productIDs = productIDs }

    func start(completion: @escaping @MainActor (Result<[MembershipLegacyPriceQuote], any Error>) -> Void) {
        guard request == nil else {
            completion(.failure(MembershipLegacyPriceProbeError.requestFailed))
            return
        }
        self.completion = completion
        let request = SKProductsRequest(productIdentifiers: productIDs)
        self.request = request // SKRequest requires a strong reference until completion.
        request.delegate = self
        request.start()
    }

    func cancel() {
        completion = nil
        request?.delegate = nil
        request?.cancel()
        request = nil
    }

    nonisolated func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        let identity = ObjectIdentifier(request)
        let result: Result<[MembershipLegacyPriceQuote], any Error>
        do {
            result = .success(try response.products.map { product in
                try MembershipLegacyPriceQuote.formatted(productID: product.productIdentifier,
                                                         price: product.price, locale: product.priceLocale)
            })
        } catch {
            result = .failure(MembershipLegacyPriceProbeError.invalidResponse)
        }
        // Convert SDK objects into immutable values before crossing actor boundaries.
        Task { @MainActor [weak self] in self?.receive(result, from: identity) }
    }

    nonisolated func request(_ request: SKRequest, didFailWithError error: any Error) {
        let identity = ObjectIdentifier(request)
        // A diagnostic query never exposes Apple's raw message or userInfo.
        Task { @MainActor [weak self] in
            self?.receive(.failure(MembershipLegacyPriceProbeError.requestFailed), from: identity)
        }
    }

    private func receive(_ result: Result<[MembershipLegacyPriceQuote], any Error>, from identity: ObjectIdentifier) {
        guard let request, ObjectIdentifier(request) == identity else { return }
        completion?(result)
    }
}
