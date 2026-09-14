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

    func enriching(with details: TMDBMovieDetails) -> MovieViewData {
        MovieViewData(
            id: id, movieQID: movieQID, imdbID: imdbID, tmdbID: tmdbID,
            title: details.title.isEmpty ? title : details.title,
            overview: details.overview.isEmpty ? overview : details.overview,
            tagline: details.tagline.isEmpty ? tagline : details.tagline,
            overviewSource: overviewSource, overviewSourceTitle: overviewSourceTitle,
            overviewSourceURL: overviewSourceURL, overviewLicense: overviewLicense,
            releaseDate: details.releaseDate ?? releaseDate,
            releaseYear: Int(details.releaseDate?.prefix(4) ?? "") ?? releaseYear,
            runtimeMinutes: details.runtime ?? runtimeMinutes,
            sourceImage: sourceImage,
            originalLanguage: details.originalLanguage.isEmpty ? originalLanguage : details.originalLanguage,
            rating: details.voteAverage, voteCount: details.voteCount, rankingScore: rankingScore,
            smallPosterFilename: smallPosterFilename,
            largePosterURL: details.posterURL?.absoluteString,
            backdropURL: details.backdropURL?.absoluteString,
            director: details.directors.isEmpty ? director : details.directors.joined(separator: " · "),
            originCountries: details.productionCountries.isEmpty ? originCountries : details.productionCountries.map(\.name),
            isDocumentary: details.genres.contains { $0.name.localizedCaseInsensitiveContains("documentary") },
            genres: details.genres.isEmpty ? genres : details.genres.map(\.name),
            timeRanges: timeRanges, locations: locations,
            cast: details.cast.prefix(20).map {
                MovieCastMember(
                    name: $0.name, character: $0.character,
                    profileURL: $0.profileURL?.absoluteString, sortOrder: $0.order
                )
            }
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

struct MovieSearchResult {
    let movies: [MovieViewData]
    let requestedLocation: LocationRecord
    let matchedLocation: LocationRecord
    let fallbackDepth: Int

    var didFallback: Bool { fallbackDepth > 0 }
}
