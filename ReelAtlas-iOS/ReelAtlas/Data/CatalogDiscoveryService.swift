import Foundation

/// Reads the full published Supabase catalog, independent of the phone's SQLite sync cursor.
actor CatalogDiscoveryService {
    struct Request: Codable, Sendable {
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
        let isStale: Bool
    }

    struct Genre: Codable { let name: String? }
    struct Period: Codable {
        let start: Int?
        let end: Int?
        let qid: String?
    }
    struct Place: Codable {
        let qid: String
        let name: String
        let name_zh: String?
        let latitude: Double?
        let longitude: Double?
    }
    struct Film: Codable {
        let movie_qid: String
        let legacy_id: Int
        let tmdb_id: Int?
        let imdb_id: String?
        let title: String
        let original_title: String?
        let overview: String
        let release_date: String?
        let genres: [Genre]
        let match_reason: String
        let time_ranges: [Period]
        let story_locations: [Place]
        let poster_url: String?
        let runtime_minutes: Int?
        let rating: Double?
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

    private struct WhereCatalogRow: Codable {
        let place_qid: String
        let name_en: String
        let name_zh: String
        let category: String
        let continent: String
        let country_qid: String
        let film_count: Int
    }
    private struct WhereSnapshot: Codable {
        let revision: Int
        let places: [WhereCatalogRow]
    }
    private struct CountryLink: Decodable {
        let movie_qid: String
        let country_qid: String
    }

    private var whereSnapshot: WhereSnapshot?
    private var lastWhereCheck = Date.distantPast
    private struct CachedPage: Codable {
        let key: String
        let rows: [Film]
        let savedAt: Date
    }
    private var pageCache: [String: CachedPage] = [:]
    private var hasLoadedPageCache = false
    private var offlineUntil = Date.distantPast

    func resetRetryCooldown() {
        offlineUntil = .distantPast
    }

    private func pageCacheURL() throws -> URL {
        // Caches/ can be evicted by iOS. A last-known-good browse snapshot is
        // application data and must survive an offline launch and app upgrade.
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReelAtlas", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("reelspan-discovery-pages-v1.json")
    }

    private func legacyPageCacheURL() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("reelspan-discovery-pages-v1.json")
    }

    private func cacheKey(_ request: Request, language: String) throws -> String {
        // The complete request is part of the key: an offline filter must never show
        // unrelated results from a previous place, period, sort order, or page.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        return language + ":" + encoded.base64EncodedString()
    }

    private func readCachedPage(key: String) -> CachedPage? {
        if !hasLoadedPageCache {
            hasLoadedPageCache = true
            let urls = [try? pageCacheURL(), try? legacyPageCacheURL()].compactMap { $0 }
            for url in urls {
                if let data = try? Data(contentsOf: url),
                   let pages = try? JSONDecoder().decode([CachedPage].self, from: data) {
                    for page in pages where pageCache[page.key] == nil {
                        pageCache[page.key] = page
                    }
                }
            }
            // Migrate the old Caches/ snapshot without deleting the source.
            if let url = try? pageCacheURL(), !pageCache.isEmpty,
               let data = try? JSONEncoder().encode(Array(pageCache.values)) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return pageCache[key]
    }

    private func writeCachedPage(key: String, rows: [Film]) {
        _ = readCachedPage(key: key)
        pageCache[key] = CachedPage(key: key, rows: rows, savedAt: Date())
        // Every viewed page is an offline snapshot. Do not expire it or drop older
        // filters/pages merely because the user browses elsewhere.
        if let url = try? pageCacheURL(),
           let data = try? JSONEncoder().encode(Array(pageCache.values)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func whereCacheURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReelAtlas", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("reelspan-where-catalog-v1.json")
    }

    private func legacyWhereCacheURL() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("reelspan-where-catalog-v1.json")
    }

    private func present(_ rows: [WhereCatalogRow], language: String) -> [ModernWherePlace] {
        rows.map { row in
            ModernWherePlace(qid: row.place_qid,
                             name: language.hasPrefix("zh") && !row.name_zh.isEmpty ? row.name_zh : row.name_en,
                             category: row.category, continent: row.continent,
                             countryQID: row.country_qid, filmCount: row.film_count, englishName: row.name_en)
        }
    }

    /// Return on-device choices immediately. The caller may separately refresh the revision.
    func cachedWhereCatalog(language: String) -> [ModernWherePlace] {
        if whereSnapshot == nil {
            let durable = try? whereCacheURL()
            let urls = [durable, try? legacyWhereCacheURL()].compactMap { $0 }
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(WhereSnapshot.self, from: data) else { continue }
                whereSnapshot = snapshot
                // Upgrade legacy Caches/ data without discarding its original file.
                if url != durable, let durable { try? data.write(to: durable, options: .atomic) }
                break
            }
        }
        return present(whereSnapshot?.places ?? [], language: language)
    }

    func refreshWhereCatalog(language: String) async throws -> [ModernWherePlace] {
        _ = cachedWhereCatalog(language: language)
        guard whereSnapshot == nil || Date().timeIntervalSince(lastWhereCheck) > 300 else {
            return present(whereSnapshot?.places ?? [], language: language)
        }
        let revisionData = try await post("reelspan_where_revision", payload: [:])
        let revision = try JSONDecoder().decode(Int.self, from: revisionData)
        if let snapshot = whereSnapshot, snapshot.revision == revision {
            lastWhereCheck = Date()
            return present(snapshot.places, language: language)
        }
        var all: [WhereCatalogRow] = []
        var offset = 0
        while true {
            var components = URLComponents(url: baseURL.appendingPathComponent("reelspan_where_catalog"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "select", value: "place_qid,name_en,name_zh,category,continent,country_qid,film_count"),
                                     URLQueryItem(name: "order", value: "continent.asc,category.asc,name_en.asc"),
                                     URLQueryItem(name: "limit", value: "1000"),
                                     URLQueryItem(name: "offset", value: String(offset))]
            let page = try JSONDecoder().decode([WhereCatalogRow].self, from: try await get(components.url!))
            all.append(contentsOf: page)
            if page.count < 1000 { break }
            offset += page.count
        }
        guard !all.isEmpty else { throw SQLiteError.step("Where catalog has not been published") }
        let next = WhereSnapshot(revision: revision, places: all)
        if let url = try? whereCacheURL(), let data = try? JSONEncoder().encode(next) {
            try? data.write(to: url, options: .atomic)
        }
        whereSnapshot = next
        lastWhereCheck = Date()
        return present(all, language: language)
    }

    /// A batched lookup used only while 'Group by place' is visible.
    func movieCountryLinks(movieQIDs: [String]) async throws -> [String: [String]] {
        guard !movieQIDs.isEmpty else { return [:] }
        var components = URLComponents(url: baseURL.appendingPathComponent("story_movie_locations"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "movie_qid,country_qid"),
                                 URLQueryItem(name: "movie_qid", value: "in.(\(movieQIDs.joined(separator: ",")))"),
                                 URLQueryItem(name: "country_qid", value: "not.is.null"),
                                 URLQueryItem(name: "is_deleted", value: "eq.false"),
                                 URLQueryItem(name: "limit", value: "1000")]
        let rows = try JSONDecoder().decode([CountryLink].self, from: try await get(components.url!))
        let groups = Dictionary(grouping: rows, by: \.movie_qid)
        return groups.mapValues { Array(Set($0.map(\.country_qid))) }
    }

    private let baseURL = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1")!
    private let publishableKey = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"

    /// Cache-first by default: a slow RPC must never delay an exact disk hit.
    /// The caller requests a fresh copy separately after showing cached rows.
    func cachedPage(_ parameters: Request, language: String) throws -> Page? {
        let key = try cacheKey(parameters, language: language)
        guard let saved = readCachedPage(key: key) else { return nil }
        let maxRows = min(max(parameters.limit, 1), 49)
        return Page(movies: saved.rows.prefix(maxRows).map { Self.movieData($0, language: language) },
                    hasMore: saved.rows.count > maxRows, isStale: true)
    }

    func page(_ parameters: Request, language: String, refresh: Bool = false) async throws -> Page {
        let maxRows = min(max(parameters.limit, 1), 49)
        let key = try cacheKey(parameters, language: language)
        if !refresh, let saved = try cachedPage(parameters, language: language) { return saved }
        if Date() < offlineUntil, let saved = readCachedPage(key: key) {
            return Page(movies: saved.rows.prefix(maxRows).map { Self.movieData($0, language: language) },
                        hasMore: saved.rows.count > maxRows, isStale: true)
        }
        if Date() < offlineUntil { throw SQLiteError.step("Catalog refresh is cooling down") }
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
        do {
            let rows = try JSONDecoder().decode([Film].self, from: try await post("reelatlas_discover", payload: payload))
            writeCachedPage(key: key, rows: rows)
            offlineUntil = .distantPast
            return Page(movies: rows.prefix(maxRows).map { Self.movieData($0, language: language) },
                        hasMore: rows.count > maxRows, isStale: false)
        } catch {
            offlineUntil = Date().addingTimeInterval(30)
            NSLog("[ReelSpan] Catalog page refresh failed: %@", String(describing: error))
            if let saved = readCachedPage(key: key) {
                return Page(movies: saved.rows.prefix(maxRows).map { Self.movieData($0, language: language) },
                            hasMore: saved.rows.count > maxRows, isStale: true)
            }
            throw error
        }
    }

    static func movieData(_ row: Film, language: String) -> MovieViewData {
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
                runtimeMinutes: row.runtime_minutes, sourceImage: nil, originalLanguage: "", rating: row.rating ?? 0,
                voteCount: 0, rankingScore: 0, smallPosterFilename: nil,
                largePosterURL: row.poster_url, backdropURL: nil, director: nil, originCountries: [],
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
                }, cast: [], matchReason: row.match_reason, catalogOriginalTitle: row.original_title
            )
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
        var request = request
        request.timeoutInterval = 15
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SQLiteError.step("Invalid catalog response")
                }
                guard (200...299).contains(http.statusCode) else {
                    let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String ?? "unknown"
                    NSLog("[ReelSpan] Catalog HTTP %ld PostgREST=%@ path=%@", http.statusCode, code,
                          request.url?.path ?? "unknown")
                    // Postgres statement_timeout (57014) will not recover from
                    // three immediate retries of the identical heavy query.
                    if attempt < 2 && code != "57014" && [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                        try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                        continue
                    }
                    throw SQLiteError.step("Catalog HTTP \(http.statusCode) (\(code))")
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("[ReelSpan] Catalog request failed path=%@ error=%@",
                      request.url?.path ?? "unknown", String(describing: error))
                if attempt < 2, error is URLError {
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                    continue
                }
                throw error
            }
        }
        throw SQLiteError.step("Catalog request retry exhausted")
    }
}
