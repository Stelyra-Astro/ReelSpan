import Foundation
import CoreLocation

struct LocationRecord: Identifiable, Hashable {
    let id: Int
    let targetQID: String
    let name: String
    let type: String
    let latitude: Double?
    let longitude: Double?
    let parentID: Int?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MovieCastMember: Identifiable, Hashable, Sendable {
    var id: String { "\(name)-\(sortOrder)" }
    let name: String
    let character: String?
    let profileURL: String?
    let sortOrder: Int
}

struct StoryLocation: Identifiable, Hashable, Sendable {
    var id: String { rawPlaceQID }
    let rawPlaceQID: String
    let name: String
}

struct MovieViewData: Identifiable, Hashable, Sendable {
    let id: Int
    let movieQID: String
    let imdbID: String?
    let tmdbID: Int?
    let title: String
    let overview: String
    let tagline: String
    let overviewSource: String
    let overviewSourceTitle: String
    let overviewSourceURL: String
    let overviewLicense: String
    let releaseDate: String?
    let releaseYear: Int?
    let runtimeMinutes: Int?
    let sourceImage: String?
    let originalLanguage: String
    let rating: Double
    let voteCount: Int
    let rankingScore: Double
    let smallPosterFilename: String?
    let largePosterURL: String?
    let backdropURL: String?
    let director: String?
    let originCountries: [String]
    let isDocumentary: Bool
    let genres: [String]
    let timeRanges: [StoryTimeRange]
    let locations: [StoryLocation]
    let cast: [MovieCastMember]

    func enriching(with details: MovieMetadata) -> MovieViewData {
        MovieViewData(
            id: id, movieQID: movieQID, imdbID: imdbID, tmdbID: tmdbID,
            title: details.title.isEmpty ? title : details.title,
            overview: details.overview,
            tagline: details.tagline,
            overviewSource: "", overviewSourceTitle: "",
            overviewSourceURL: "", overviewLicense: "",
            releaseDate: details.releaseDate,
            releaseYear: Int(details.releaseDate?.prefix(4) ?? ""),
            runtimeMinutes: details.runtime,
            sourceImage: nil,
            originalLanguage: details.originalLanguage,
            rating: details.rating, voteCount: details.voteCount, rankingScore: rankingScore,
            smallPosterFilename: nil,
            largePosterURL: details.posterURL?.absoluteString,
            backdropURL: MovieMetadataImageURLs.backdrop(path: details.backdropPath)?.absoluteString,
            director: details.directors.isEmpty ? nil : details.directors.map(\.name).joined(separator: " · "),
            originCountries: [],
            isDocumentary: details.genres.contains { $0.name.localizedCaseInsensitiveContains("documentary") },
            genres: details.genres.map(\.name),
            timeRanges: timeRanges, locations: locations,
            cast: details.cast.prefix(20).map {
                MovieCastMember(
                    name: $0.name, character: $0.character,
                    profileURL: $0.profileURL?.absoluteString, sortOrder: $0.order
                )
            }
        )
    }

    /// Search-only movies use a temporary negative identity and cannot be favorited.
    static func searchResult(_ item: MovieSearchItem, local: MovieViewData?) -> MovieViewData {
        MovieViewData(
            id: local?.id ?? -item.id, movieQID: local?.movieQID ?? "", imdbID: local?.imdbID, tmdbID: item.id,
            title: item.title, overview: item.overview, tagline: "", overviewSource: "", overviewSourceTitle: "",
            overviewSourceURL: "", overviewLicense: "", releaseDate: item.releaseDate,
            releaseYear: item.releaseDate.flatMap { Int($0.prefix(4)) }, runtimeMinutes: nil, sourceImage: nil,
            originalLanguage: "", rating: item.rating, voteCount: item.voteCount, rankingScore: local?.rankingScore ?? 0,
            smallPosterFilename: nil, largePosterURL: item.posterURL?.absoluteString, backdropURL: nil,
            director: nil, originCountries: [], isDocumentary: false, genres: [],
            timeRanges: local?.timeRanges ?? [], locations: local?.locations ?? [], cast: []
        )
    }

    var voteCountText: String {
        if voteCount >= 1_000_000 { return String(format: "%.1fM", Double(voteCount) / 1_000_000) }
        if voteCount >= 1_000 { return String(format: "%.1fk", Double(voteCount) / 1_000) }
        return "\(voteCount)"
    }

    var releaseYearText: String {
        releaseYear.map(L10n.year) ?? "—"
    }

    var imdbURL: URL {
        IMDbDestination.url(imdbID: imdbID, title: title)
    }

    var storyTimeText: String {
        timeRanges.map { range in
            if range.startYear == range.endYear { return L10n.year(range.startYear) }
            return "\(L10n.year(range.startYear))–\(L10n.year(range.endYear))"
        }.joined(separator: " / ")
    }

    var storyLocationText: String {
        guard !locations.isEmpty else { return "" }
        if locations.count <= 2 { return locations.map(\.name).joined(separator: " · ") }
        return "\(locations[0].name) · \(locations[1].name) +\(locations.count - 2)"
    }
}

struct MoviePage: Sendable {
    let movies: [MovieViewData]
    let hasMore: Bool

    static let empty = MoviePage(movies: [], hasMore: false)
}
