import Foundation

public struct NamedMovieValue: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MoviePerson: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let originalName: String
    public let profilePath: String?

    public init(id: Int, name: String, originalName: String, profilePath: String?) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.profilePath = profilePath
    }

    public var profileURL: URL? {
        MovieMetadataImageURLs.profile(path: profilePath)
    }
}

public struct MovieCast: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let originalName: String
    public let character: String
    public let profilePath: String?
    public let order: Int

    public init(
        id: Int,
        name: String,
        originalName: String,
        character: String,
        profilePath: String?,
        order: Int
    ) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.character = character
        self.profilePath = profilePath
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, originalName, character, profilePath, order
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName) ?? name
        character = try container.decodeIfPresent(String.self, forKey: .character) ?? ""
        profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 9_999
    }

    public var profileURL: URL? {
        MovieMetadataImageURLs.profile(path: profilePath)
    }
}

public struct MovieMetadata: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let originalTitle: String
    public let overview: String
    public let tagline: String
    public let posterPath: String?
    public let posterUrl: String?
    public let backdropPath: String?
    public let releaseDate: String?
    public let runtime: Int?
    public let originalLanguage: String
    public let status: String
    public let genres: [NamedMovieValue]
    public let rating: Double
    public let voteCount: Int
    public let popularity: Double
    public let directors: [MoviePerson]
    public let cast: [MovieCast]

    public init(
        id: Int,
        title: String,
        originalTitle: String,
        overview: String,
        tagline: String,
        posterPath: String?,
        posterUrl: String?,
        backdropPath: String?,
        releaseDate: String?,
        runtime: Int?,
        originalLanguage: String,
        status: String,
        genres: [NamedMovieValue],
        rating: Double,
        voteCount: Int,
        popularity: Double,
        directors: [MoviePerson],
        cast: [MovieCast]
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.tagline = tagline
        self.posterPath = posterPath
        self.posterUrl = posterUrl
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.runtime = runtime
        self.originalLanguage = originalLanguage
        self.status = status
        self.genres = genres
        self.rating = rating
        self.voteCount = voteCount
        self.popularity = popularity
        self.directors = directors
        self.cast = cast
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, overview, tagline, posterPath, posterUrl, backdropPath
        case releaseDate, runtime, originalLanguage, status, genres, rating, voteCount, popularity
        case directors, cast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle) ?? ""
        overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        runtime = try container.decodeIfPresent(Int.self, forKey: .runtime)
        originalLanguage = try container.decodeIfPresent(String.self, forKey: .originalLanguage) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        genres = try container.decodeIfPresent([NamedMovieValue].self, forKey: .genres) ?? []
        rating = try container.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity) ?? 0
        directors = try container.decodeIfPresent([MoviePerson].self, forKey: .directors) ?? []
        cast = try container.decodeIfPresent([MovieCast].self, forKey: .cast) ?? []
    }

    public var posterURL: URL? {
        MovieMetadataImageURLs.poster(primary: posterUrl, path: posterPath)
    }

    public var thumbnailPosterURL: URL? {
        MovieMetadataImageURLs.searchPoster(primary: posterUrl, path: posterPath)
    }
}

public struct MovieSearchPage: Codable, Equatable, Sendable {
    public let page: Int
    public let results: [MovieSearchItem]
    public let totalPages: Int
    public let totalResults: Int

    public init(page: Int, results: [MovieSearchItem], totalPages: Int, totalResults: Int) {
        self.page = page
        self.results = results
        self.totalPages = totalPages
        self.totalResults = totalResults
    }
}

public struct MovieSearchItem: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let originalTitle: String
    public let overview: String
    public let posterPath: String?
    public let posterUrl: String?
    public let releaseDate: String?
    public let rating: Double
    public let voteCount: Int
    public let popularity: Double

    public init(
        id: Int,
        title: String,
        originalTitle: String,
        overview: String,
        posterPath: String?,
        posterUrl: String?,
        releaseDate: String?,
        rating: Double,
        voteCount: Int,
        popularity: Double
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterPath = posterPath
        self.posterUrl = posterUrl
        self.releaseDate = releaseDate
        self.rating = rating
        self.voteCount = voteCount
        self.popularity = popularity
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, overview, posterPath, posterUrl, releaseDate
        case rating, voteCount, popularity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle) ?? ""
        overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity) ?? 0
    }

    public var posterURL: URL? {
        MovieMetadataImageURLs.searchPoster(primary: posterUrl, path: posterPath)
    }
}

public enum MovieMetadataImageURLs {
    private static let baseURL = URL(string: "https://image.tmdb.org/t/p")!

    public static func poster(primary: String?, path: String?) -> URL? {
        primaryOrFallback(primary: primary, path: path, size: "w342")
    }

    public static func searchPoster(primary: String?, path: String?) -> URL? {
        primaryOrFallback(primary: primary, path: path, size: "w185")
    }

    public static func profile(path: String?) -> URL? {
        fallbackURL(path: path, size: "w185")
    }

    public static func backdrop(path: String?) -> URL? {
        fallbackURL(path: path, size: "w780")
    }

    private static func primaryURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func primaryOrFallback(primary: String?, path: String?, size: String) -> URL? {
        if let url = primaryURL(primary) { return url }
        return fallbackURL(path: path, size: size)
    }

    private static func fallbackURL(path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return baseURL
            .appendingPathComponent(size)
            .appendingPathComponent(String(path.dropFirst()))
    }
}


public struct MovieRanking: Codable, Equatable, Sendable {
    public let tmdbID: Int
    public let rating: Double
    public let voteCount: Int

    enum CodingKeys: String, CodingKey {
        case tmdbID = "tmdb_id"
        case rating
        case voteCount = "vote_count"
    }

    public init(tmdbID: Int, rating: Double, voteCount: Int) {
        self.tmdbID = tmdbID
        self.rating = rating
        self.voteCount = voteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = try container.decode(Int.self, forKey: .tmdbID)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
    }

    public var score: Double {
        RankingCalculator.reelSpanScore(rating: rating, votes: voteCount)
    }
}
