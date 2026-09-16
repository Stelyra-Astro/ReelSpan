import Foundation

/// Reads the full published Supabase catalog, independent of the phone's SQLite sync cursor.
actor CatalogDiscoveryService {
    struct Request: Sendable {
        var query: String = ""
        var startYear: Int?
        var endYear: Int?
        var conceptQID: String?
        var placeQID: String?
        var countryQID: String?
        var genre: String?
        var sort: String = "recommended"
        var offset: Int = 0
        var limit: Int = MoviePaginationPolicy.resultPageSize
    }

    struct Page: Sendable {
        let movies: [MovieViewData]
        let hasMore: Bool
    }

    private struct Genre: Decodable { let name: String? }
    private struct Period: Decodable {
        let start: Int?
        let end: Int?
        let qid: String?
    }
    private struct Place: Decodable {
        let qid: String
        let name: String
        let name_zh: String?
        let latitude: Double?
        let longitude: Double?
    }
    private struct Film: Decodable {
        let movie_qid: String
        let legacy_id: Int
        let tmdb_id: Int?
        let imdb_id: String?
        let title: String
        let overview: String
        let release_date: String?
        let genres: [Genre]
        let match_reason: String
        let time_ranges: [Period]
        let story_locations: [Place]
    }
    private struct Concept: Decodable {
        let concept_qid: String
        let category: String
        let name_en: String
        let name_zh: String
        let start_year: Int?
        let end_year: Int?
    }
    private struct WherePlace: Decodable {
        let place_qid: String
        let name_en: String
        let name_zh: String
        let category: String
    }

    private let baseURL = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1")!
    private let publishableKey = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"

    func page(_ parameters: Request, language: String) async throws -> Page {
        let maxRows = min(max(parameters.limit, 1), 49)
        let payload: [String: Any] = [
            "p_query": parameters.query,
            "p_start_year": parameters.startYear as Any? ?? NSNull(),
            "p_end_year": parameters.endYear as Any? ?? NSNull(),
            "p_concept_qid": parameters.conceptQID as Any? ?? NSNull(),
            "p_place_qid": parameters.placeQID as Any? ?? NSNull(),
            "p_country_qid": parameters.countryQID as Any? ?? NSNull(),
            "p_genre": parameters.genre as Any? ?? NSNull(),
            "p_sort": parameters.sort,
            "p_limit": maxRows + 1,
            "p_offset": max(0, parameters.offset)
        ]
        let rows = try JSONDecoder().decode([Film].self, from: try await post("reelatlas_discover", payload: payload))
        let movies: [MovieViewData] = rows.prefix(maxRows).map { row in
            MovieViewData(
                id: row.legacy_id,
                movieQID: row.movie_qid,
                imdbID: row.imdb_id,
                tmdbID: row.tmdb_id,
                title: row.title,
                overview: row.overview,
                tagline: "",
                overviewSource: "", overviewSourceTitle: "", overviewSourceURL: "", overviewLicense: "",
                releaseDate: row.release_date,
                releaseYear: row.release_date.flatMap { Int($0.prefix(4)) },
                runtimeMinutes: nil, sourceImage: nil, originalLanguage: "", rating: 0,
                voteCount: 0, rankingScore: 0, smallPosterFilename: nil,
                largePosterURL: nil, backdropURL: nil, director: nil, originCountries: [],
                isDocumentary: row.genres.contains { $0.name?.localizedCaseInsensitiveContains("documentary") == true },
                genres: row.genres.compactMap(\.name),
                timeRanges: row.time_ranges.compactMap { time in
                    guard let start = time.start, let end = time.end else { return nil }
                    return StoryTimeRange(startYear: start, endYear: end,
                                          sourcePeriodQID: time.qid, normalizationType: "catalog")
                },
                locations: row.story_locations.map {
                    StoryLocation(rawPlaceQID: $0.qid,
                                  name: language.hasPrefix("zh") ? ($0.name_zh ?? $0.name) : $0.name,
                                  latitude: $0.latitude, longitude: $0.longitude)
                }, cast: [], matchReason: row.match_reason
            )
        }
        return Page(movies: movies, hasMore: rows.count > maxRows)
    }

    func concepts(language: String) async throws -> [TimeConcept] {
        var components = URLComponents(url: baseURL.appendingPathComponent("story_time_concepts"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "select", value: "concept_qid,category,name_en,name_zh,start_year,end_year"),
            URLQueryItem(name: "is_deleted", value: "eq.false"),
            URLQueryItem(name: "start_year", value: "not.is.null"),
            URLQueryItem(name: "end_year", value: "not.is.null"),
            URLQueryItem(name: "order", value: "name_en.asc"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        let rows = try JSONDecoder().decode([Concept].self, from: try await get(components.url!))
        return rows.map {
            TimeConcept(qid: $0.concept_qid, category: $0.category,
                        name: language.hasPrefix("zh") && !$0.name_zh.isEmpty ? $0.name_zh : $0.name_en,
                        startYear: $0.start_year, endYear: $0.end_year)
        }
    }

    func modernPlaces(query: String, language: String) async throws -> [ModernWherePlace] {
        let data = try await post("reelatlas_where_places", payload: ["p_query": String(query.prefix(80)), "p_limit": 60])
        let rows = try JSONDecoder().decode([WherePlace].self, from: data)
        return rows.map {
            ModernWherePlace(qid: $0.place_qid,
                             name: language.hasPrefix("zh") && !$0.name_zh.isEmpty ? $0.name_zh : $0.name_en,
                             category: $0.category)
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        return try await perform(request)
    }

    private func post(_ function: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("rpc").appendingPathComponent(function))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SQLiteError.step("Film catalog is temporarily unavailable")
        }
        return data
    }
}
