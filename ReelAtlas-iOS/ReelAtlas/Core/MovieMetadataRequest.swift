import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MovieMetadataRequestError: Error, Equatable, Sendable {
    case invalidTMDBID
    case blankQuery
    case invalidPage
    case emptyTMDBIDs
}

public enum MovieBackendConfiguration {
    public static let workerBaseURL = URL(string: "https://tmdb.xiaoguiwk.top")!
    public static let supabaseRESTBaseURL = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1")!
    public static let supabasePublishableKey = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"
}

public enum MovieMetadataRequest: Sendable {
    case detail(tmdbID: Int)
    case search(query: String, page: Int)
    case supabaseDetail(tmdbID: Int)
    case rankings(tmdbIDs: [Int])

    public var urlRequest: URLRequest {
        get throws {
            switch self {
            case let .detail(tmdbID):
                guard tmdbID > 0 else { throw MovieMetadataRequestError.invalidTMDBID }
                return try Self.workerRequest(path: "/movie/\(tmdbID)", queryItems: [])

            case let .search(query, page):
                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedQuery.isEmpty else { throw MovieMetadataRequestError.blankQuery }
                guard page >= 1 else { throw MovieMetadataRequestError.invalidPage }
                return try Self.workerRequest(
                    path: "/search/movie",
                    queryItems: [
                        URLQueryItem(name: "query", value: trimmedQuery),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                )

            case let .supabaseDetail(tmdbID):
                guard tmdbID > 0 else { throw MovieMetadataRequestError.invalidTMDBID }
                return try Self.supabaseRequest(
                    path: "/movies",
                    queryItems: [
                        URLQueryItem(name: "tmdb_id", value: "eq.\(tmdbID)"),
                        URLQueryItem(name: "select", value: "payload"),
                        URLQueryItem(name: "limit", value: "1")
                    ]
                )

            case let .rankings(tmdbIDs):
                let ids = Array(Set(tmdbIDs.filter { $0 > 0 })).sorted()
                guard !ids.isEmpty else { throw MovieMetadataRequestError.emptyTMDBIDs }
                return try Self.supabaseRequest(
                    path: "/movies",
                    queryItems: [
                        URLQueryItem(
                            name: "select",
                            value: "tmdb_id,rating:payload->rating,vote_count:payload->voteCount"
                        ),
                        URLQueryItem(name: "tmdb_id", value: "in.(\(ids.map(String.init).joined(separator: ",")))"),
                        URLQueryItem(name: "order", value: "tmdb_id.asc")
                    ]
                )
            }
        }
    }

    private static func workerRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents(url: MovieBackendConfiguration.workerBaseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems + [URLQueryItem(name: "language", value: "en-US")]
        guard let url = components?.url else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }

    private static func supabaseRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents(url: MovieBackendConfiguration.supabaseRESTBaseURL, resolvingAgainstBaseURL: false)
        components?.path += path
        components?.queryItems = queryItems
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(MovieBackendConfiguration.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
