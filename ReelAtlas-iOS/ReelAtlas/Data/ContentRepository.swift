import Foundation
import SQLite3

final class ContentRepository {
    private let db: SQLiteDatabase

    convenience init() throws {
        try self.init(databaseURL: Self.cacheURL())
    }

    init(databaseURL: URL) throws {
        db = try SQLiteDatabase(url: databaseURL, readOnly: true)
    }

    static func cacheURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ReelAtlas", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("content.sqlite")
    }

    static func metadataVersion(at url: URL) -> String? {
        guard let database = try? SQLiteDatabase(url: url, readOnly: true),
              let statement = try? database.prepare("SELECT value FROM metadata WHERE key='database_version' LIMIT 1") else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard (try? database.step(statement)) == true else { return nil }
        return database.text(statement, 0)
    }

    func databaseVersion() -> String {
        guard let statement = try? db.prepare("SELECT value FROM metadata WHERE key='database_version' LIMIT 1") else {
            return "Unknown"
        }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return "Unknown" }
        return db.text(statement, 0) ?? "Unknown"
    }

    func timeConcepts(preferredLanguage: String) -> [TimeConcept] {
        let sql = "SELECT concept_qid,category,name_en,name_zh,labels_json,start_year,end_year FROM time_concepts WHERE start_year IS NOT NULL AND end_year IS NOT NULL ORDER BY name_en"
        guard let stmt = try? db.prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var concepts: [TimeConcept] = []
        while (try? db.step(stmt)) == true {
            let nameEN = db.text(stmt, 2) ?? ""
            let nameZH = db.text(stmt, 3) ?? nameEN
            let localized = CSVContentDecoder.localizedLabel(
                json: db.text(stmt, 4) ?? "{}", preferredLanguage: preferredLanguage)
            let name = localized ?? (preferredLanguage.hasPrefix("zh") ? nameZH : nameEN)
            concepts.append(TimeConcept(
                qid: db.text(stmt, 0) ?? "", category: db.text(stmt, 1) ?? "era", name: name,
                startYear: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : db.int(stmt, 5),
                endYear: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : db.int(stmt, 6)))
        }
        return concepts
    }

    func location(id: Int, preferredLanguage: String) -> LocationRecord? {
        if id < 0 {
            let sql = """
            SELECT -p.rowid,p.place_qid,p.name_en,p.name_zh,p.labels_json,'place',p.coordinate
            FROM places p WHERE p.rowid=? LIMIT 1
            """
            guard let statement = try? db.prepare(sql, bindings: [.int(-id)]) else { return nil }
            defer { sqlite3_finalize(statement) }
            guard (try? db.step(statement)) == true else { return nil }
            return readLocation(statement, preferredLanguage: preferredLanguage)
        }
        let sql = """
        SELECT t.rowid,t.target_qid,t.name_en,t.name_zh,t.labels_json,t.target_kind,p.coordinate
        FROM targets t
        LEFT JOIN places p ON p.place_qid=t.target_qid
        WHERE t.rowid=? LIMIT 1
        """
        guard let statement = try? db.prepare(sql, bindings: [.int(id)]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return nil }
        return readLocation(statement, preferredLanguage: preferredLanguage)
    }

    func bestLocationMatch(candidateNames: [String], preferredLanguage: String) -> LocationRecord? {
        for candidate in candidateNames where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sql = """
            SELECT t.rowid,t.target_qid,t.name_en,t.name_zh,t.labels_json,t.target_kind,p.coordinate
            FROM targets t
            LEFT JOIN places p ON p.place_qid=t.target_qid
            WHERE lower(t.name_en)=lower(?) OR lower(t.name_zh)=lower(?)
               OR EXISTS (SELECT 1 FROM json_each(t.labels_json) WHERE lower(value)=lower(?))
            ORDER BY t.target_kind='country', t.name_en
            LIMIT 1
            """
            guard let statement = try? db.prepare(
                sql,
                bindings: [.text(candidate), .text(candidate), .text(candidate)]
            ) else { continue }
            defer { sqlite3_finalize(statement) }
            if (try? db.step(statement)) == true {
                return readLocation(statement, preferredLanguage: preferredLanguage)
            }

            let placeSQL = """
            SELECT -p.rowid,p.place_qid,p.name_en,p.name_zh,p.labels_json,'place',p.coordinate
            FROM places p
            WHERE lower(p.name_en)=lower(?) OR lower(p.name_zh)=lower(?)
               OR EXISTS (SELECT 1 FROM json_each(p.labels_json) WHERE lower(value)=lower(?))
            ORDER BY p.coordinate IS NULL, p.name_en
            LIMIT 1
            """
            guard let placeStatement = try? db.prepare(
                placeSQL,
                bindings: [.text(candidate), .text(candidate), .text(candidate)]
            ) else { continue }
            defer { sqlite3_finalize(placeStatement) }
            if (try? db.step(placeStatement)) == true {
                return readLocation(placeStatement, preferredLanguage: preferredLanguage)
            }
        }
        return nil
    }

    func bestCountryMatch(candidateNames: [String], preferredLanguage: String) -> LocationRecord? {
        for candidate in candidateNames where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let targetSQL = """
            SELECT t.rowid,t.target_qid,t.name_en,t.name_zh,t.labels_json,t.target_kind,p.coordinate
            FROM targets t
            LEFT JOIN places p ON p.place_qid=t.target_qid
            WHERE t.target_kind='country' AND (
                lower(t.name_en)=lower(?) OR lower(t.name_zh)=lower(?)
                OR EXISTS (SELECT 1 FROM json_each(t.labels_json) WHERE lower(value)=lower(?))
            )
            LIMIT 1
            """
            if let statement = try? db.prepare(
                targetSQL,
                bindings: [.text(candidate), .text(candidate), .text(candidate)]
            ) {
                defer { sqlite3_finalize(statement) }
                if (try? db.step(statement)) == true {
                    return readLocation(statement, preferredLanguage: preferredLanguage)
                }
            }

            let placeSQL = """
            SELECT -p.rowid,p.place_qid,p.name_en,p.name_zh,p.labels_json,'country',p.coordinate
            FROM movie_locations ml
            JOIN places p ON p.place_qid=ml.country_qid
            WHERE lower(ml.country_name_en)=lower(?) OR lower(ml.country_name_zh)=lower(?)
               OR lower(p.name_en)=lower(?) OR lower(p.name_zh)=lower(?)
               OR EXISTS (SELECT 1 FROM json_each(p.labels_json) WHERE lower(value)=lower(?))
            GROUP BY p.rowid,p.place_qid,p.name_en,p.name_zh,p.labels_json,p.coordinate
            LIMIT 1
            """
            if let statement = try? db.prepare(
                placeSQL,
                bindings: Array(repeating: .text(candidate), count: 5)
            ) {
                defer { sqlite3_finalize(statement) }
                if (try? db.step(statement)) == true {
                    return readLocation(statement, preferredLanguage: preferredLanguage)
                }
            }
        }
        return nil
    }

    func nearestMovieLocation(
        latitude: Double,
        longitude: Double,
        preferredLanguage: String
    ) -> LocationRecord? {
        let sql = """
        SELECT -p.rowid,p.place_qid,p.name_en,p.name_zh,p.labels_json,'place',p.coordinate
        FROM places p
        WHERE p.coordinate IS NOT NULL
          AND p.place_qid IN (
              SELECT raw_place_qid FROM movie_locations
              UNION SELECT historical_capital_qid FROM movie_locations
              UNION SELECT modern_place_qid FROM movie_locations
              UNION SELECT city_qid FROM movie_locations
              UNION SELECT admin1_qid FROM movie_locations
              UNION SELECT country_qid FROM movie_locations
          )
        """
        guard let statement = try? db.prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        var nearest: (record: LocationRecord, distance: Double)?
        while (try? db.step(statement)) == true {
            guard let coordinate = Self.parsePoint(db.text(statement, 6)) else { continue }
            let distance = Self.distanceKilometers(
                latitude1: latitude,
                longitude1: longitude,
                latitude2: coordinate.latitude,
                longitude2: coordinate.longitude
            )
            if nearest == nil || distance < nearest!.distance {
                nearest = (readLocation(statement, preferredLanguage: preferredLanguage), distance)
            }
        }
        return nearest?.record
    }

    func administrativeLocationMatches(
        query: String,
        preferredLanguage: String,
        limit: Int = 8
    ) -> [LocationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sql = """
        SELECT t.rowid,t.target_qid,t.name_en,t.name_zh,t.labels_json,t.target_kind,p.coordinate
        FROM targets t
        LEFT JOIN places p ON p.place_qid=t.target_qid
        """
        guard let statement = try? db.prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var ranked: [(record: LocationRecord, rank: Int)] = []
        while (try? db.step(statement)) == true {
            let record = readLocation(statement, preferredLanguage: preferredLanguage)
            let names = [db.text(statement, 2), db.text(statement, 3), record.name].compactMap { $0 }
                + CSVContentDecoder.labelValues(json: db.text(statement, 4) ?? "{}")
            guard let rank = AdministrativePlaceNameMatcher.rank(query: trimmed, names: names) else { continue }
            ranked.append((record, rank))
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.record.name.localizedCaseInsensitiveCompare(rhs.record.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.record)
    }

    func movieSearchMatches(
        query: String,
        preferredLanguage: String,
        limit: Int = 8
    ) -> [MovieViewData] {
        // Movie metadata is intentionally absent from the bundled database.
        // User-entered movie searches are handled by MovieMetadataService.
        []
    }

    func candidateMovies(
        startYear: Int,
        endYear: Int,
        scope: MovieLocationScope?,
        preferredLanguage: String,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>,
        maximum: Int = -1
    ) -> [MovieViewData] {
        guard maximum != 0 else { return [] }
        return movieIDs(
            startYear: startYear,
            endYear: endYear,
            scope: scope,
            favoritesOnly: favoritesOnly,
            favoriteIDs: favoriteIDs,
            limit: maximum,
            offset: 0
        )
        .compactMap { movie(id: $0, preferredLanguage: preferredLanguage) }
    }

    func searchPage(
        startYear: Int,
        endYear: Int,
        targetQID: String,
        preferredLanguage: String,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>,
        offset: Int,
        limit: Int = MoviePaginationPolicy.resultPageSize
    ) -> MoviePage {
        guard limit > 0, offset >= 0 else { return .empty }
        let ids = movieIDs(
            startYear: startYear,
            endYear: endYear,
            scope: .place(targetQID: targetQID),
            favoritesOnly: favoritesOnly,
            favoriteIDs: favoriteIDs,
            limit: limit + 1,
            offset: offset
        )
        let pageIDs = Array(ids.prefix(limit))
        return MoviePage(
            movies: pageIDs.compactMap { movie(id: $0, preferredLanguage: preferredLanguage) },
            hasMore: ids.count > limit,
            storyLocations: []
        )
    }

    func allMovies(preferredLanguage: String) -> [MovieViewData] {
        guard let statement = try? db.prepare(
            "SELECT id FROM movies ORDER BY id"
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [MovieViewData] = []
        while (try? db.step(statement)) == true {
            if let movie = movie(id: db.int(statement, 0), preferredLanguage: preferredLanguage) {
                result.append(movie)
            }
        }
        return result
    }

    func movies(ids: Set<Int>, preferredLanguage: String) -> [MovieViewData] {
        ids.compactMap { movie(id: $0, preferredLanguage: preferredLanguage) }
            .sorted { $0.id < $1.id }
    }

    func movieQIDs(ids: Set<Int>) -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        guard let statement = try? db.prepare(
            "SELECT movie_qid FROM movies WHERE id IN (\(placeholders)) ORDER BY movie_qid",
            bindings: ids.sorted().map(SQLiteBindValue.int)
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while (try? db.step(statement)) == true {
            if let value = db.text(statement, 0) { values.append(value) }
        }
        return values
    }

    func movieIDs(qids: [String]) -> Set<Int> {
        guard !qids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: qids.count).joined(separator: ",")
        guard let statement = try? db.prepare(
            "SELECT id FROM movies WHERE movie_qid IN (\(placeholders))",
            bindings: qids.map(SQLiteBindValue.text)
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values = Set<Int>()
        while (try? db.step(statement)) == true { values.insert(db.int(statement, 0)) }
        return values
    }

    func movie(id: Int, preferredLanguage: String) -> MovieViewData? {
        let sql = """
        SELECT movie_qid,tmdb_movie_id,imdb_id
        FROM movies WHERE id=? LIMIT 1
        """
        guard let statement = try? db.prepare(sql, bindings: [.int(id)]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return nil }

        let movieQID = db.text(statement, 0) ?? ""
        let tmdbID = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : db.int(statement, 1)

        return MovieViewData(
            id: id,
            movieQID: movieQID,
            imdbID: db.text(statement, 2),
            tmdbID: tmdbID,
            title: movieQID,
            overview: "",
            tagline: "",
            overviewSource: "",
            overviewSourceTitle: "",
            overviewSourceURL: "",
            overviewLicense: "",
            releaseDate: nil,
            releaseYear: nil,
            runtimeMinutes: nil,
            sourceImage: nil,
            originalLanguage: "",
            rating: 0,
            voteCount: 0,
            rankingScore: 0,
            smallPosterFilename: nil,
            largePosterURL: nil,
            backdropURL: nil,
            director: nil,
            originCountries: [],
            isDocumentary: false,
            genres: [],
            timeRanges: timeRanges(movieQID: movieQID),
            locations: locations(movieQID: movieQID, preferredLanguage: preferredLanguage),
            cast: []
        )
    }

    func movie(tmdbID: Int, preferredLanguage: String) -> MovieViewData? {
        guard tmdbID > 0,
              let statement = try? db.prepare(
                "SELECT id FROM movies WHERE tmdb_movie_id=? ORDER BY id LIMIT 1",
                bindings: [.int(tmdbID)]
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return nil }
        return movie(id: db.int(statement, 0), preferredLanguage: preferredLanguage)
    }

    private func movieIDs(
        startYear: Int,
        endYear: Int,
        scope: MovieLocationScope?,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>,
        limit: Int,
        offset: Int
    ) -> [Int] {
        if favoritesOnly && favoriteIDs.isEmpty { return [] }
        let orderedFavorites = favoriteIDs.sorted()
        let favoriteClause = favoritesOnly
            ? "AND m.id IN (\(Array(repeating: "?", count: orderedFavorites.count).joined(separator: ",")))"
            : ""
        let locationClause: String
        let locationBindings: [SQLiteBindValue]
        switch scope {
        case .some(.place(let targetQID)):
            locationClause = """
            (
                EXISTS (
                    SELECT 1 FROM movie_target_matches mtm
                    WHERE mtm.movie_qid=m.movie_qid AND mtm.target_qid=?
                )
                OR EXISTS (
                    SELECT 1 FROM movie_locations ml
                    WHERE ml.movie_qid=m.movie_qid AND ? IN (
                        ml.raw_place_qid, ml.historical_capital_qid, ml.modern_place_qid,
                        ml.city_qid, ml.admin1_qid, ml.country_qid
                    )
                )
            )
            """
            locationBindings = [.text(targetQID), .text(targetQID)]
        case .some(.country(_, let countryQID)):
            locationClause = """
            EXISTS (
                SELECT 1 FROM movie_locations ml
                WHERE ml.movie_qid=m.movie_qid AND ml.country_qid=?
            )
            """
            locationBindings = [.text(countryQID)]
        case .none:
            locationClause = "1=1"
            locationBindings = []
        }
        let sql = """
        SELECT DISTINCT m.id
        FROM movies m
        WHERE (
            EXISTS (
                SELECT 1 FROM movie_periods mp
                WHERE mp.movie_qid=m.movie_qid AND mp.start_year<=? AND mp.end_year>=?
            )
            OR (?=1 AND NOT EXISTS (
                SELECT 1 FROM movie_periods mp
                WHERE mp.movie_qid=m.movie_qid AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL
            ))
        ) AND \(locationClause)
        \(favoriteClause)
        ORDER BY m.id
        LIMIT ? OFFSET ?
        """
        var bindings: [SQLiteBindValue] = [
            .int(endYear), .int(startYear),
            .int(StoryTimeAvailabilityMatcher.includesUnknown(startYear: startYear, endYear: endYear) ? 1 : 0)
        ]
        bindings.append(contentsOf: locationBindings)
        if favoritesOnly { bindings.append(contentsOf: orderedFavorites.map(SQLiteBindValue.int)) }
        bindings.append(.int(limit))
        bindings.append(.int(offset))
        guard let statement = try? db.prepare(
            sql,
            bindings: bindings
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while (try? db.step(statement)) == true { ids.append(db.int(statement, 0)) }
        return ids
    }

    private func timeRanges(movieQID: String) -> [StoryTimeRange] {
        let sql = """
        SELECT start_year,end_year,period_qid,interval_method
        FROM movie_periods
        WHERE movie_qid=? AND start_year IS NOT NULL AND end_year IS NOT NULL
        ORDER BY start_year,end_year,period_qid
        """
        guard let statement = try? db.prepare(sql, bindings: [.text(movieQID)]) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [StoryTimeRange] = []
        while (try? db.step(statement)) == true {
            values.append(StoryTimeRange(
                startYear: db.int(statement, 0),
                endYear: db.int(statement, 1),
                sourcePeriodQID: db.text(statement, 2),
                normalizationType: db.text(statement, 3),
                confidence: 1
            ))
        }
        return values
    }

    private func locations(movieQID: String, preferredLanguage: String) -> [StoryLocation] {
        let sql = """
        SELECT ml.raw_place_qid,ml.raw_place_labels_json,ml.raw_place_name_en,ml.raw_place_name_zh,p.coordinate
        FROM movie_locations ml
        LEFT JOIN places p ON p.place_qid=ml.raw_place_qid
        WHERE ml.movie_qid=?
        GROUP BY raw_place_qid,raw_place_labels_json,raw_place_name_en,raw_place_name_zh
        ORDER BY MAX(is_target_match) DESC,raw_place_name_en COLLATE NOCASE
        """
        guard let statement = try? db.prepare(sql, bindings: [.text(movieQID)]) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [StoryLocation] = []
        while (try? db.step(statement)) == true {
            let qid = db.text(statement, 0) ?? ""
            let labels = db.text(statement, 1) ?? "{}"
            let nameEN = db.text(statement, 2) ?? qid
            let nameZH = db.text(statement, 3) ?? nameEN
            let name = CSVContentDecoder.localizedLabel(json: labels, preferredLanguage: preferredLanguage)
                ?? (LanguageResolver.normalizedCode(preferredLanguage) == "zh-Hans" ? nameZH : nameEN)
            let coordinate = Self.parsePoint(db.text(statement, 4))
            values.append(StoryLocation(
                rawPlaceQID: qid,
                name: name,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            ))
        }
        return values
    }

    private func readLocation(_ statement: OpaquePointer, preferredLanguage: String) -> LocationRecord {
        let nameEN = db.text(statement, 2) ?? ""
        let nameZH = db.text(statement, 3) ?? nameEN
        let labels = db.text(statement, 4) ?? "{}"
        let name = CSVContentDecoder.localizedLabel(json: labels, preferredLanguage: preferredLanguage)
            ?? (LanguageResolver.normalizedCode(preferredLanguage) == "zh-Hans" ? nameZH : nameEN)
        let coordinate = Self.parsePoint(db.text(statement, 6))
        return LocationRecord(
            id: db.int(statement, 0),
            targetQID: db.text(statement, 1) ?? "",
            name: name,
            type: db.text(statement, 5) ?? "",
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            parentID: nil
        )
    }

    private static func parsePoint(_ value: String?) -> (longitude: Double, latitude: Double)? {
        guard let value,
              value.hasPrefix("POINT("),
              value.hasSuffix(")") else { return nil }
        let contents = value.dropFirst(6).dropLast()
        let parts = contents.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let longitude = Double(parts[0]),
              let latitude = Double(parts[1]) else { return nil }
        return (longitude, latitude)
    }

    private static func distanceKilometers(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (latitude2 - latitude1) * radians
        let deltaLongitude = (longitude2 - longitude1) * radians
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1 * radians) * cos(latitude2 * radians)
            * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 6_371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
