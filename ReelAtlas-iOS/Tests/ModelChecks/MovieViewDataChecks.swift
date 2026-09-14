import Foundation

// Non-UI regression check compiled against the actual app model (see ui-search-tip-report.md).
@main
struct MovieViewDataChecks {
    static func main() {
        let original = MovieViewData(
            id: 42, movieQID: "Q42", imdbID: "tt1234", tmdbID: 550,
            title: "Q42", overview: "", tagline: "", overviewSource: "", overviewSourceTitle: "",
            overviewSourceURL: "", overviewLicense: "", releaseDate: nil, releaseYear: nil,
            runtimeMinutes: nil, sourceImage: nil, originalLanguage: "", rating: 0, voteCount: 0,
            rankingScore: 1, smallPosterFilename: nil, largePosterURL: nil, backdropURL: nil,
            director: nil, originCountries: [], isDocumentary: false, genres: [],
            timeRanges: [StoryTimeRange(startYear: 1941, endYear: 1942)],
            locations: [StoryLocation(rawPlaceQID: "Q60", name: "New York")], cast: []
        )
        let metadata = MovieMetadata(
            id: 550, title: "Movie", originalTitle: "Original", overview: "Overview", tagline: "Tagline",
            posterPath: "/fallback.jpg", posterUrl: "https://example.com/550.jpg", backdropPath: nil,
            releaseDate: "1999-10-15", runtime: 139, originalLanguage: "en", status: "Released",
            genres: [NamedMovieValue(id: 18, name: "Drama")], rating: 8.4, voteCount: 100, popularity: 1,
            directors: [MoviePerson(id: 1, name: "A", originalName: "A", profilePath: nil),
                        MoviePerson(id: 2, name: "B", originalName: "B", profilePath: nil)],
            cast: [MovieCast(id: 3, name: "Actor", originalName: "Actor", character: "Lead", profilePath: nil, order: 0)]
        )
        let enriched = original.enriching(with: metadata)
        precondition(enriched.id == original.id && enriched.tmdbID == 550 && enriched.movieQID == "Q42")
        precondition(enriched.timeRanges == original.timeRanges && enriched.locations == original.locations)
        precondition(enriched.title == "Movie" && enriched.overview == "Overview" && enriched.runtimeMinutes == 139)
        precondition(enriched.director == "A · B" && enriched.cast.first?.character == "Lead")
        precondition(enriched.cast.first?.profileURL == nil)
        precondition(enriched.largePosterURL == "https://example.com/550.jpg")
        precondition(enriched.imdbURL.absoluteString == "https://www.imdb.com/title/tt1234/")
        let item = MovieSearchItem(id: 550, title: "Movie", originalTitle: "Original", overview: "", posterPath: nil,
                                  posterUrl: nil, releaseDate: nil, rating: 0, voteCount: 0, popularity: 0)
        let matched = MovieViewData.searchResult(item, local: original)
        precondition(matched.id == original.id && matched.locations == original.locations)
        let remote = MovieViewData.searchResult(item, local: nil)
        precondition(remote.id == -550 && remote.timeRanges.isEmpty && remote.locations.isEmpty)
        print("MovieViewData enrichment and search identity checks passed")
    }
}
