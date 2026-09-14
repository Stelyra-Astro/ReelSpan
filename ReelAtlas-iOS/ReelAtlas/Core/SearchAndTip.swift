import Foundation
import Observation

@MainActor @Observable
public final class LatestMovieSearch {
    public private(set) var page: MovieSearchPage?
    public private(set) var error: MovieMetadataError?
    public private(set) var isPending = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let debounce: Duration

    public init(debounce: Duration = .milliseconds(250)) { self.debounce = debounce }
    deinit { task?.cancel() }

    public func update(_ value: String, fetch: @escaping @Sendable (String) async throws -> MovieSearchPage) {
        cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        let request = generation
        let delay = debounce
        isPending = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                let result = try await fetch(query)
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.page = result
                self.isPending = false
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.error = error as? MovieMetadataError ?? .invalidResponse
                self.isPending = false
            }
        }
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        page = nil
        error = nil
        isPending = false
    }
}

public enum TipRules {
    public static let productID = "com.reelatlas.tip"
    public static func isValidQuantity(_ value: Int) -> Bool { (1...10).contains(value) }
}

public enum TipState: Equatable, Sendable {
    case unavailable, loading, ready, purchasing, verified, pending, cancelled, unverified, failed(String)
    public var isBusy: Bool { self == .loading || self == .purchasing }
    public static func result(verified: Bool) -> Self { verified ? .verified : .unverified }
}
