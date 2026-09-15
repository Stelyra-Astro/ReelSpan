import Foundation
import Combine

/// Owns list permits. Detail consumers suspend admission, but leave running work intact.
@MainActor
public final class MovieRequestScheduler {
    private struct Waiting {
        let token: UUID
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private let maximumListRequests: Int
    private var active: [UUID: Int] = [:]
    private var waiting: [Waiting] = []
    private var details = 0

    public init(maximumListRequests: Int = 2) {
        self.maximumListRequests = max(1, maximumListRequests)
    }

    public func beginDetail() {
        details += 1
        let cancelled = waiting
        waiting.removeAll()
        for item in cancelled { item.continuation.resume(throwing: CancellationError()) }
    }

    public func endDetail() {
        details = max(0, details - 1)
        drain()
    }

    public var isDetailActive: Bool { details > 0 }

    public func isRunning(id: Int) -> Bool { active.values.contains(id) }

    public func acquireList(id: Int, token: UUID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiting(token: token, id: id, continuation: continuation))
                drain()
            }
            do { try Task.checkCancellation() }
            catch { releaseList(token: token); throw error }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.token == token }) else { return }
                self.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    public func releaseList(token: UUID) {
        active.removeValue(forKey: token)
        drain()
    }

    private func drain() {
        while details == 0 && active.count < maximumListRequests && !waiting.isEmpty {
            let next = waiting.removeFirst()
            active[next.token] = next.id
            next.continuation.resume()
        }
    }
}

public enum MovieMetadataState: Equatable, Sendable {
    case idle, loading, loaded(MovieMetadata), failed(MovieMetadataError)

    public var metadata: MovieMetadata? {
        if case let .loaded(value) = self { return value }
        return nil
    }
}

@MainActor
public final class MovieMetadataStore: ObservableObject {
    public let service: MovieMetadataService
    @Published private var states: [Int: MovieMetadataState] = [:]
    private let scheduler: MovieRequestScheduler
    private let rowDwell: Duration
    private var visible: [Int: Int] = [:]
    private var details: [Int: Int] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var generations: [Int: UUID] = [:]

    public init(service: MovieMetadataService = MovieMetadataService(), rowDwell: Duration = .seconds(1)) {
        self.service = service
        self.rowDwell = rowDwell
        self.scheduler = MovieRequestScheduler()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    public func metadataState(for tmdbID: Int) -> MovieMetadataState { states[tmdbID] ?? .idle }

    /// Each begin call represents a consumer and must have a corresponding end call.
    public func beginVisible(_ tmdbID: Int) {
        guard tmdbID > 0 else { return }
        visible[tmdbID, default: 0] += 1
        start(tmdbID, detail: false)
    }

    public func endVisible(_ tmdbID: Int) {
        decrement(&visible, id: tmdbID)
        cancelIfUnused(tmdbID)
    }

    public func beginDetail(_ tmdbID: Int) {
        guard tmdbID > 0 else { return }
        details[tmdbID, default: 0] += 1
        scheduler.beginDetail()
        // Dwell and queued work are invalidated synchronously before detail starts.
        for id in Array(tasks.keys) where details[id] == nil && !scheduler.isRunning(id: id) {
            cancel(id)
        }
        if tasks[tmdbID] != nil && !scheduler.isRunning(id: tmdbID) && details[tmdbID] == 1 {
            cancel(tmdbID)
        }
        start(tmdbID, detail: true)
    }

    public func endDetail(_ tmdbID: Int) {
        guard details[tmdbID] != nil else { return }
        decrement(&details, id: tmdbID)
        scheduler.endDetail()
        cancelIfUnused(tmdbID)
        if !scheduler.isDetailActive {
            for id in visible.keys { start(id, detail: false) }
        }
    }

    public func search(query: String, page: Int = 1) async throws -> MovieSearchPage {
        try await service.search(query: query, page: page)
    }

    private func start(_ id: Int, detail: Bool) {
        guard tasks[id] == nil, states[id]?.metadata == nil,
              detail || !scheduler.isDetailActive else { return }
        let generation = UUID()
        generations[id] = generation
        states[id] = .loading
        let service = service
        let scheduler = scheduler
        let dwell = rowDwell
        tasks[id] = Task(priority: detail ? .userInitiated : .utility) { [weak self] in
            var hasPermit = false
            defer { if hasPermit { scheduler.releaseList(token: generation) } }
            let result: MovieMetadataState
            do {
                if !detail {
                    try await Task.sleep(for: dwell)
                    try await scheduler.acquireList(id: id, token: generation)
                    hasPermit = true
                }
                let metadata = try await service.metadata(tmdbID: id)
                try Task.checkCancellation()
                result = .loaded(metadata)
            } catch is CancellationError {
                result = .idle
            } catch {
                result = .failed(error as? MovieMetadataError ?? .invalidResponse)
            }
            guard let self, self.generations[id] == generation else { return }
            self.states[id] = result
            self.tasks[id] = nil
            self.generations[id] = nil
        }
    }

    private func cancelIfUnused(_ id: Int) {
        if visible[id] == nil && details[id] == nil { cancel(id) }
    }

    private func cancel(_ id: Int) {
        generations[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        if states[id]?.metadata == nil { states[id] = .idle }
    }

    private func decrement(_ counts: inout [Int: Int], id: Int) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
    }
}
