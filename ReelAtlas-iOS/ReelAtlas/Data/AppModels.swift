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
    let latitude: Double?
    let longitude: Double?

    init(rawPlaceQID: String, name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.rawPlaceQID = rawPlaceQID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum MovieLocationScope: Hashable, Sendable {
    case place(targetQID: String)
    case country(countryCode: String, countryQID: String)
}


/// Search and When/Where filters use stable Wikidata QIDs, not display names.
struct TimeConcept: Identifiable, Hashable, Sendable {
    var id: String { qid }
    let qid: String
    let category: String
    let name: String
    let startYear: Int?
    let endYear: Int?
}

struct ModernWherePlace: Identifiable, Hashable, Sendable {
    var id: String { qid }
    let qid: String
    let name: String
    let category: String
    var continent: String = ""
    var countryQID: String = ""
    var filmCount: Int = 0
    var englishName: String = ""
}

struct SearchSelectionMarker: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: SearchSelectionMarker, rhs: SearchSelectionMarker) -> Bool {
        lhs.id == rhs.id
    }
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
    var matchReason: String? = nil

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
            },
            matchReason: matchReason
        )
    }

    /// Movie search only exposes titles that already belong to ReelSpan's story database.
    static func searchResult(_ item: MovieSearchItem, local: MovieViewData) -> MovieViewData {
        MovieViewData(
            id: local.id, movieQID: local.movieQID, imdbID: local.imdbID, tmdbID: item.id,
            title: item.title, overview: item.overview, tagline: "", overviewSource: "", overviewSourceTitle: "",
            overviewSourceURL: "", overviewLicense: "", releaseDate: item.releaseDate,
            releaseYear: item.releaseDate.flatMap { Int($0.prefix(4)) }, runtimeMinutes: nil, sourceImage: nil,
            originalLanguage: "", rating: item.rating, voteCount: item.voteCount,
            rankingScore: RankingCalculator.reelSpanScore(rating: item.rating, votes: item.voteCount),
            smallPosterFilename: nil, largePosterURL: item.posterURL?.absoluteString, backdropURL: nil,
            director: nil, originCountries: [], isDocumentary: false, genres: [],
            timeRanges: local.timeRanges, locations: local.locations, cast: []
        )
    }

    func applying(ranking: MovieRanking) -> MovieViewData {
        MovieViewData(
            id: id, movieQID: movieQID, imdbID: imdbID, tmdbID: tmdbID,
            title: title, overview: overview, tagline: tagline,
            overviewSource: overviewSource, overviewSourceTitle: overviewSourceTitle,
            overviewSourceURL: overviewSourceURL, overviewLicense: overviewLicense,
            releaseDate: releaseDate, releaseYear: releaseYear, runtimeMinutes: runtimeMinutes,
            sourceImage: sourceImage, originalLanguage: originalLanguage,
            rating: ranking.rating, voteCount: ranking.voteCount, rankingScore: ranking.score,
            smallPosterFilename: smallPosterFilename, largePosterURL: largePosterURL, backdropURL: backdropURL,
            director: director, originCountries: originCountries, isDocumentary: isDocumentary, genres: genres,
            timeRanges: timeRanges, locations: locations, cast: cast
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
    let storyLocations: [StoryLocation]

    static let empty = MoviePage(movies: [], hasMore: false, storyLocations: [])
}
