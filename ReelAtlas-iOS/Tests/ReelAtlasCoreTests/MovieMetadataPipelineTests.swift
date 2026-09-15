import XCTest
@testable import ReelAtlasCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor ScriptedMovieTransport: MovieHTTPTransport {
    struct Stub: Sendable {
        let match: @Sendable (URLRequest) -> Bool
        let status: Int
        let data: Data
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let stub = stubs.first(where: { $0.match(request) }) else {
            throw URLError(.badServerResponse)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil
        )!
        return (stub.data, response)
    }

    func urls() -> [String] { requests.compactMap { $0.url?.absoluteString } }
}

final class MovieMetadataPipelineTests: XCTestCase {
    func testSupabaseDetailRequestUsesPublishableKeyAndPayloadOnly() throws {
        let request = try MovieMetadataRequest.supabaseDetail(tmdbID: 550).urlRequest
        XCTAssertEqual(request.url?.host, "injisguyqfxfwgnbtghe.supabase.co")
        XCTAssertEqual(request.url?.path, "/rest/v1/movies")
        XCTAssertTrue(request.url?.query?.contains("tmdb_id=eq.550") == true)
        XCTAssertTrue(request.url?.query?.contains("select=payload") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "apikey")?.hasPrefix("sb_publishable_") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testMetadataUsesSupabasePayloadWithoutCallingWorker() async throws {
        let payload = try JSONEncoder().encode(MovieMetadata.fixture(id: 550))
        let object = try JSONSerialization.jsonObject(with: payload)
        let supabase = try JSONSerialization.data(withJSONObject: [["payload": object]])
        let transport = ScriptedMovieTransport(stubs: [
            .init(match: { $0.url?.host?.contains("supabase.co") == true }, status: 200, data: supabase)
        ])
        let service = MovieMetadataService(transport: transport, cache: makeTemporaryCache())

        let value = try await service.metadata(tmdbID: 550)

        XCTAssertEqual(value.id, 550)
        let urls = await transport.urls()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].contains("supabase.co"))
    }

    func testMetadataFallsBackToWorkerWhenSupabaseHasNoRow() async throws {
        let worker = try JSONEncoder().encode(MovieMetadata.fixture(id: 550))
        let transport = ScriptedMovieTransport(stubs: [
            .init(match: { $0.url?.host?.contains("supabase.co") == true }, status: 200, data: Data("[]".utf8)),
            .init(match: { $0.url?.host == "tmdb.xiaoguiwk.top" }, status: 200, data: worker)
        ])
        let service = MovieMetadataService(transport: transport, cache: makeTemporaryCache())

        _ = try await service.metadata(tmdbID: 550)

        let urls = await transport.urls()
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].contains("supabase.co"))
        XCTAssertTrue(urls[1].contains("tmdb.xiaoguiwk.top/movie/550"))
    }

    func testMetadataFallsBackToWorkerWhenSupabaseRequestFails() async throws {
        let worker = try JSONEncoder().encode(MovieMetadata.fixture(id: 550))
        let transport = ScriptedMovieTransport(stubs: [
            .init(match: { $0.url?.host?.contains("supabase.co") == true }, status: 503, data: Data()),
            .init(match: { $0.url?.host == "tmdb.xiaoguiwk.top" }, status: 200, data: worker)
        ])
        let service = MovieMetadataService(transport: transport, cache: makeTemporaryCache())

        let value = try await service.metadata(tmdbID: 550)

        XCTAssertEqual(value.id, 550)
        let urls = await transport.urls()
        XCTAssertEqual(urls.count, 2)
    }

    func testDeviceCacheWinsBeforeSupabaseOrWorker() async throws {
        let cache = makeTemporaryCache()
        try cache.writeMetadata(.fixture(id: 550), tmdbID: 550)
        let transport = ScriptedMovieTransport(stubs: [])
        let service = MovieMetadataService(transport: transport, cache: cache)

        let value = try await service.metadata(tmdbID: 550)

        XCTAssertEqual(value.id, 550)
        let urls = await transport.urls()
        XCTAssertTrue(urls.isEmpty)
    }

    func testRankingRequestReadsOnlyRankingFieldsFromMoviesPayload() throws {
        let request = try MovieMetadataRequest.rankings(tmdbIDs: [603, 550, 603]).urlRequest
        XCTAssertEqual(request.url?.path, "/rest/v1/movies")
        XCTAssertTrue(request.url?.query?.contains("tmdb_id,rating:payload-%3Erating,vote_count:payload-%3EvoteCount") == true)
        XCTAssertTrue(request.url?.query?.contains("tmdb_id=in.(550,603)") == true)

        let highTiny = RankingCalculator.reelSpanScore(rating: 9.5, votes: 5)
        let strongPopular = RankingCalculator.reelSpanScore(rating: 8.2, votes: 100_000)
        XCTAssertGreaterThan(strongPopular, highTiny)
    }


    func testRankingPolicyOrdersRatedCandidatesBeforeMissingRankings() {
        let candidates = [
            MovieRankingCandidate(localID: 1, tmdbID: 101),
            MovieRankingCandidate(localID: 2, tmdbID: 102),
            MovieRankingCandidate(localID: 3, tmdbID: nil),
            MovieRankingCandidate(localID: 4, tmdbID: 104)
        ]
        let rankings = [
            MovieRanking(tmdbID: 101, rating: 9.4, voteCount: 8),
            MovieRanking(tmdbID: 102, rating: 8.1, voteCount: 80_000)
        ]

        let sorted = MovieRankingPolicy.sortedCandidates(candidates, rankings: rankings)

        XCTAssertEqual(sorted.map(\.localID), [2, 1, 3, 4])
    }

    func testSearchPolicyHidesMoviesMissingFromStoryDatabase() {
        let items = [
            MovieSearchItem(
                id: 603, title: "The Matrix", originalTitle: "The Matrix", overview: "",
                posterPath: nil, posterUrl: nil, releaseDate: "1999-03-31", rating: 8.2,
                voteCount: 30_000, popularity: 100
            ),
            MovieSearchItem(
                id: 604, title: "Unknown", originalTitle: "Unknown", overview: "",
                posterPath: nil, posterUrl: nil, releaseDate: nil, rating: 5,
                voteCount: 2, popularity: 1
            )
        ]

        let filtered = MovieSearchPolicy.knownStoryMovies(items, allowedTMDBIDs: [603])

        XCTAssertEqual(filtered.map(\.id), [603])
    }


    func testDetailDecoderAcceptsWorkerNullsForOptionalTextAndCastFields() throws {
        let json = Data(#"""
        {
          "id": 42,
          "title": "Example",
          "originalTitle": "Example",
          "overview": null,
          "tagline": null,
          "posterPath": null,
          "posterUrl": null,
          "backdropPath": null,
          "releaseDate": null,
          "runtime": null,
          "originalLanguage": null,
          "status": null,
          "genres": [],
          "rating": null,
          "voteCount": null,
          "popularity": null,
          "directors": [],
          "cast": [{
            "id": 7,
            "name": "Actor",
            "originalName": "Actor",
            "character": null,
            "profilePath": null,
            "order": null
          }]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(MovieMetadata.self, from: json)

        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.overview, "")
        XCTAssertEqual(decoded.tagline, "")
        XCTAssertEqual(decoded.originalLanguage, "")
        XCTAssertEqual(decoded.status, "")
        XCTAssertEqual(decoded.rating, 0)
        XCTAssertEqual(decoded.voteCount, 0)
        XCTAssertEqual(decoded.popularity, 0)
        XCTAssertEqual(decoded.cast.first?.character, "")
        XCTAssertEqual(decoded.cast.first?.order, 9_999)
    }

    func testRankingDecoderTreatsNullTMDBValuesAsZero() throws {
        let json = Data(#"""
        [{"tmdb_id": 42, "rating": null, "vote_count": null}]
        """#.utf8)

        let decoded = try JSONDecoder().decode([MovieRanking].self, from: json)

        XCTAssertEqual(decoded, [MovieRanking(tmdbID: 42, rating: 0, voteCount: 0)])
    }

    func testSearchDecoderAcceptsWorkerNullMetadata() throws {
        let json = Data(#"""
        {
          "page": 1,
          "totalPages": 1,
          "totalResults": 1,
          "results": [{
            "id": 42,
            "title": "Example",
            "originalTitle": null,
            "overview": null,
            "posterPath": null,
            "backdropPath": null,
            "releaseDate": null,
            "originalLanguage": null,
            "genreIds": [],
            "rating": null,
            "voteCount": null,
            "popularity": null
          }]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(MovieSearchPage.self, from: json)
        XCTAssertEqual(decoded.results.first?.originalTitle, "")
        XCTAssertEqual(decoded.results.first?.overview, "")
        XCTAssertEqual(decoded.results.first?.rating, 0)
        XCTAssertEqual(decoded.results.first?.voteCount, 0)
    }

}

private func makeTemporaryCache() -> MovieMetadataCache {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return MovieMetadataCache(root: root)
}
