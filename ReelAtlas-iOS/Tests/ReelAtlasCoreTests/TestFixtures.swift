@testable import ReelAtlasCore

extension MoviePerson {
    static func fixture(id: Int = 1, name: String = "Director") -> Self {
        .init(id: id, name: name, originalName: name, profilePath: nil)
    }
}

extension MovieMetadata {
    static func fixture(id: Int = 550, directors: [MoviePerson] = [.fixture()]) -> Self {
        .init(
            id: id, title: "Fight Club", originalTitle: "Fight Club",
            overview: "Overview", tagline: "Tagline", posterPath: "/poster.jpg",
            posterUrl: "https://cdn.example/posters/550.jpg", backdropPath: nil,
            releaseDate: "1999-10-15", runtime: 139, originalLanguage: "en",
            status: "Released", genres: [.init(id: 18, name: "Drama")],
            rating: 8.4, voteCount: 10, popularity: 3,
            directors: directors, cast: []
        )
    }
}
