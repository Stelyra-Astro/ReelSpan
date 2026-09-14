import Foundation

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
        let request = try MovieMetadataRequest.detail(tmdbID: tmdbID).urlRequest
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
                        let data = try await self.fetch(request)
                        let metadata: MovieMetadata = try Self.decode(data)
                        guard metadata.id == tmdbID else { throw MovieMetadataError.invalidResponse }
                        try Task.checkCancellation()
                        // Cache failures must not discard a successful network result.
                        try? self.cache.writeMetadata(metadata, tmdbID: tmdbID)
                        result = .success(metadata)
                    } catch { result = .failure(error) }
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
        return try Self.decode(try await fetch(request))
    }

    public func imageData(url: URL) async throws -> Data {
        try Task.checkCancellation()
        if let data = cache.cachedImage(for: url) { return data }
        let data = try await fetch(URLRequest(url: url))
        try Task.checkCancellation()
        try? cache.writeImage(data, for: url)
        return data
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

    private func fetch(_ originalRequest: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        var request = originalRequest
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200..<300: return data
            case 404: throw MovieMetadataError.notFound
            case 429: throw MovieMetadataError.rateLimited
            case 500...599: throw MovieMetadataError.server(response.statusCode)
            default: throw MovieMetadataError.invalidResponse
            }
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost: throw MovieMetadataError.offline
            case .timedOut: throw MovieMetadataError.timedOut
            default: throw MovieMetadataError.invalidResponse
            }
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MovieMetadataError.decoding }
    }
}
