import Foundation

enum ArtworkCachePolicy {
    static let rowDwellNanoseconds: UInt64 = 1_000_000_000
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumBytes: Int64 = 150 * 1_024 * 1_024
    static let maximumConcurrentVisibleRequests = 2
    static let posterSize = "w185"
}

struct TMDBImageMetadata: Codable, Equatable, Sendable {
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    var posterURL: URL? { imageURL(path: posterPath, size: ArtworkCachePolicy.posterSize) }
    var backdropURL: URL? { imageURL(path: backdropPath, size: "w1280") }

    private func imageURL(path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

struct TMDBMovieDetails: Codable, Equatable, Sendable {
    struct NamedValue: Codable, Equatable, Sendable {
        let id: Int?
        let name: String
        let code: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case code = "iso_3166_1"
        }
    }

    struct CastMember: Codable, Equatable, Sendable {
        let id: Int
        let name: String
        let character: String?
        let order: Int
        let profilePath: String?

        enum CodingKeys: String, CodingKey {
            case id, name, character, order
            case profilePath = "profile_path"
        }

        var profileURL: URL? { TMDBMovieDetails.imageURL(path: profilePath, size: "w185") }
    }

    struct CrewMember: Codable, Equatable, Sendable {
        let id: Int
        let name: String
        let job: String
    }

    struct Credits: Codable, Equatable, Sendable {
        let cast: [CastMember]
        let crew: [CrewMember]
    }

    let title: String
    let overview: String
    let tagline: String
    let releaseDate: String?
    let runtime: Int?
    let originalLanguage: String
    let voteAverage: Double
    let voteCount: Int
    let posterPath: String?
    let backdropPath: String?
    let genres: [NamedValue]
    let productionCountries: [NamedValue]
    let credits: Credits

    enum CodingKeys: String, CodingKey {
        case title, overview, tagline, runtime, genres, credits
        case releaseDate = "release_date"
        case originalLanguage = "original_language"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case productionCountries = "production_countries"
    }

    var directors: [String] { credits.crew.filter { $0.job == "Director" }.map(\.name) }
    var cast: [CastMember] { credits.cast }
    var posterURL: URL? { Self.imageURL(path: posterPath, size: ArtworkCachePolicy.posterSize) }
    var backdropURL: URL? { Self.imageURL(path: backdropPath, size: "w1280") }

    private static func imageURL(path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
