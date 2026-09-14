import Foundation

public enum MovieMetadataRequestError: Error, Equatable, Sendable {
    case invalidTMDBID
    case blankQuery
    case invalidPage
}

public enum MovieMetadataRequest: Sendable {
    public static let baseURL = URL(string: "https://reelspan-tmdb.xiaoguiwk.workers.dev")!

    case detail(tmdbID: Int)
    case search(query: String, page: Int)

    public var urlRequest: URLRequest {
        get throws {
            switch self {
            case let .detail(tmdbID):
                guard tmdbID > 0 else { throw MovieMetadataRequestError.invalidTMDBID }
                return try Self.request(path: "/movie/\(tmdbID)", queryItems: [])
            case let .search(query, page):
                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedQuery.isEmpty else { throw MovieMetadataRequestError.blankQuery }
                guard page >= 1 else { throw MovieMetadataRequestError.invalidPage }
                return try Self.request(
                    path: "/search/movie",
                    queryItems: [
                        URLQueryItem(name: "query", value: trimmedQuery),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                )
            }
        }
    }

    private static func request(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems + [URLQueryItem(name: "language", value: "en-US")]
        guard let url = components?.url else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }
}
