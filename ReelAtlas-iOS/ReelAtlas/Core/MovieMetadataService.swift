import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol MovieHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMovieHTTPTransport: MovieHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MovieMetadataError.invalidResponse
        }
        return (data, response)
    }
}

public enum MovieMetadataError: Error, Equatable, Sendable {
    case offline, timedOut, notFound, rateLimited, server(Int), invalidResponse, decoding
}

public actor MovieMetadataService {
    private struct Flight {
        let generation: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<MovieMetadata, Error>]
    }

    private struct SupabaseMovieRow: Decodable {
        let payload: MovieMetadata
    }

    private let transport: any MovieHTTPTransport
    private let cache: MovieMetadataCache
    private var flights: [Int: Flight] = [:]

    public init(
        transport: any MovieHTTPTransport = URLSessionMovieHTTPTransport(),
        cache: sending MovieMetadataCache = MovieMetadataCache()
    ) {
        self.transport = transport
        self.cache = cache
    }

    public func metadata(tmdbID: Int) async throws -> MovieMetadata {
        guard tmdbID > 0 else { throw MovieMetadataRequestError.invalidTMDBID }
        try Task.checkCancellation()
        if let cached = try? cache.readMetadata(tmdbID: tmdbID) { return cached }

        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flights[tmdbID] != nil {
                    flights[tmdbID]?.consumers[consumer] = continuation
                    return
                }
                let generation = UUID()
                let task = Task {
                    let result: Result<MovieMetadata, Error>
                    do {
                        let metadata = try await self.fetchSupabaseThenWorker(tmdbID: tmdbID)
                        guard metadata.id == tmdbID else { throw MovieMetadataError.invalidResponse }
                        try Task.checkCancellation()
                        try? self.cache.writeMetadata(metadata, tmdbID: tmdbID)
                        result = .success(metadata)
                    } catch {
                        result = .failure(error)
                    }
                    self.finish(tmdbID: tmdbID, generation: generation, result: result)
                }
                flights[tmdbID] = Flight(generation: generation, task: task, consumers: [consumer: continuation])
            }
        } onCancel: {
            Task { await self.cancel(tmdbID: tmdbID, consumer: consumer) }
        }
    }

    public func search(query: String, page: Int = 1) async throws -> MovieSearchPage {
        let request = try MovieMetadataRequest.search(query: query, page: page).urlRequest
        return try Self.decode(try await fetchWorker(request))
    }

    public func rankings(tmdbIDs: [Int]) async throws -> [MovieRanking] {
        let ids = Array(Set(tmdbIDs.filter { $0 > 0 })).sorted()
        guard !ids.isEmpty else { return [] }
        // PostgREST and proxies handle this comfortably for ReelSpan's <=300 candidates.
        let request = try MovieMetadataRequest.rankings(tmdbIDs: ids).urlRequest
        let (data, response) = try await raw(request)
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPStatus(response.statusCode)
        }
        return try Self.decode(data)
    }

    public func imageData(url: URL) async throws -> Data {
        try Task.checkCancellation()
        if let data = cache.cachedImage(for: url) { return data }
        let data = try await fetchWorker(URLRequest(url: url))
        try Task.checkCancellation()
        try? cache.writeImage(data, for: url)
        return data
    }

    public func clearCache() throws { try cache.clear() }
    public func trimCache() throws { try cache.trim() }
    public func cacheBytes() -> Int64 { cache.totalBytes() }

    private func fetchSupabaseThenWorker(tmdbID: Int) async throws -> MovieMetadata {
        let supabaseRequest = try MovieMetadataRequest.supabaseDetail(tmdbID: tmdbID).urlRequest
        do {
            let (data, response) = try await raw(supabaseRequest)
            if (200..<300).contains(response.statusCode),
               let row = try? Self.decode([SupabaseMovieRow].self, from: data).first,
               row.payload.id == tmdbID {
                return row.payload
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Supabase is the preferred cache, not a single point of failure.
        }

        let workerRequest = try MovieMetadataRequest.detail(tmdbID: tmdbID).urlRequest
        let metadata: MovieMetadata = try Self.decode(try await fetchWorker(workerRequest))
        return metadata
    }

    private func cancel(tmdbID: Int, consumer: UUID) {
        guard let continuation = flights[tmdbID]?.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if flights[tmdbID]?.consumers.isEmpty == true {
            flights.removeValue(forKey: tmdbID)?.task.cancel()
        }
    }

    private func finish(tmdbID: Int, generation: UUID, result: Result<MovieMetadata, Error>) {
        guard flights[tmdbID]?.generation == generation,
              let flight = flights.removeValue(forKey: tmdbID) else { return }
        for consumer in flight.consumers.values { consumer.resume(with: result) }
    }

    private func raw(_ originalRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = originalRequest
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let result = try await transport.data(for: request)
            try Task.checkCancellation()
            return result
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost: throw MovieMetadataError.offline
            case .timedOut: throw MovieMetadataError.timedOut
            default: throw MovieMetadataError.invalidResponse
            }
        }
    }

    private func fetchWorker(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await raw(request)
        guard (200..<300).contains(response.statusCode) else { throw mapHTTPStatus(response.statusCode) }
        return data
    }

    private func mapHTTPStatus(_ status: Int) -> MovieMetadataError {
        switch status {
        case 404: return .notFound
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .invalidResponse
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        try decode(T.self, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MovieMetadataError.decoding }
    }
}
