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
