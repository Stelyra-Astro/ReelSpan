import Foundation
import SQLite3

final class ContentRepository {
    private let db: SQLiteDatabase

    init() throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ReelAtlas", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let destination = support.appendingPathComponent("content.sqlite")
        guard let seed = Bundle.main.url(forResource: "content_seed", withExtension: "sqlite") else {
            throw SQLiteError.open("Bundled content_seed.sqlite is missing")
        }

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: seed, to: destination)
        } else {
            let bundledVersion = Self.metadataVersion(at: seed)
            let installedVersion = Self.metadataVersion(at: destination)
            if bundledVersion != nil, bundledVersion != installedVersion {
                let replacement = support.appendingPathComponent("content-replacement.sqlite")
                try? fileManager.removeItem(at: replacement)
                try fileManager.copyItem(at: seed, to: replacement)
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: replacement, to: destination)
            }
        }
        db = try SQLiteDatabase(url: destination, readOnly: true)
    }

    private static func metadataVersion(at url: URL) -> String? {
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let sql = """
        SELECT m.id,m.title_en,m.title_zh,m.labels_json,m.movie_qid,
               m.director_qids_json,m.directors_json,
               m.origin_country_qids_json,m.origin_countries_json,
               m.genre_qids_json,m.genres_json,
               m.original_language_qids_json,m.original_languages_json,
               COALESCE(m.imdb_id,''),COALESCE(CAST(m.tmdb_movie_id AS TEXT),''),
               COALESCE((
                   SELECT group_concat(
                       ml.raw_place_qid || ' ' || ml.raw_place_name_en || ' ' || ml.raw_place_name_zh || ' ' ||
                       ml.raw_place_labels_json || ' ' || COALESCE(ml.historical_capital_qid,'') || ' ' ||
                       COALESCE(ml.historical_capital_name_en,'') || ' ' || COALESCE(ml.modern_place_qid,'') || ' ' ||
                       COALESCE(ml.modern_place_name_en,'') || ' ' || COALESCE(ml.city_qid,'') || ' ' ||
                       COALESCE(ml.city_name_en,'') || ' ' || COALESCE(ml.city_name_zh,'') || ' ' ||
                       COALESCE(ml.admin1_qid,'') || ' ' || COALESCE(ml.admin1_name_en,'') || ' ' ||
                       COALESCE(ml.admin1_name_zh,'') || ' ' || COALESCE(ml.country_qid,'') || ' ' ||
                       COALESCE(ml.country_name_en,'') || ' ' || COALESCE(ml.country_name_zh,''), ' '
                   ) FROM movie_locations ml WHERE ml.movie_qid=m.movie_qid
               ),''),
               COALESCE((
                   SELECT group_concat(
                       mp.period_qid || ' ' || mp.period_name_en || ' ' || mp.period_name_zh || ' ' || mp.period_labels_json,
                       ' '
                   ) FROM movie_periods mp WHERE mp.movie_qid=m.movie_qid
               ),'')
        FROM movies m
        """
        guard let statement = try? db.prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var ranked: [(id: Int, rank: Int, title: String)] = []
        while (try? db.step(statement)) == true {
            guard !Task.isCancelled else { return [] }
            let fields = (1...16).compactMap { db.text(statement, Int32($0)) }
            guard let rank = SearchTextMatcher.rank(query: trimmed, fields: fields) else { continue }
            ranked.append((db.int(statement, 0), rank, db.text(statement, 1) ?? ""))
        }
        return ranked
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
            .compactMap { movie(id: $0.id, preferredLanguage: preferredLanguage) }
    }

    func search(
        startYear: Int,
        endYear: Int,
        requestedLocation: LocationRecord,
        preferredLanguage: String,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>
    ) -> MovieSearchResult {
        let ids = movieIDs(startYear: startYear, endYear: endYear, targetQID: requestedLocation.targetQID)
        let filtered = favoritesOnly ? ids.filter { favoriteIDs.contains($0) } : ids
        let movies = filtered.compactMap { movie(id: $0, preferredLanguage: preferredLanguage) }
        return MovieSearchResult(
            movies: movies,
            requestedLocation: requestedLocation,
            matchedLocation: requestedLocation,
            fallbackDepth: 0
        )
    }

    func movie(tmdbID: Int, preferredLanguage: String) -> MovieViewData? {
        guard let statement = try? db.prepare("SELECT id FROM movies WHERE tmdb_id=? LIMIT 1", bindings: [.int(tmdbID)]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return nil }
        return movie(id: db.int(statement, 0), preferredLanguage: preferredLanguage)
    }

    func allMovies(preferredLanguage: String) -> [MovieViewData] {
        guard let statement = try? db.prepare(
            "SELECT id FROM movies ORDER BY release_year IS NULL, release_year DESC, title_en COLLATE NOCASE"
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
            .sorted {
                if $0.releaseYear != $1.releaseYear {
                    return ($0.releaseYear ?? Int.min) > ($1.releaseYear ?? Int.min)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
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
        SELECT movie_qid,tmdb_movie_id,release_date,release_year,runtime,labels_json,title_en,title_zh,
               directors_json,origin_countries_json,genres_json,original_languages_json,image,
               tmdb_overview,tmdb_tagline,overview_en,overview_source,overview_source_title,
               overview_source_url,overview_license,imdb_id
        FROM movies WHERE id=? LIMIT 1
        """
        guard let statement = try? db.prepare(sql, bindings: [.int(id)]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? db.step(statement)) == true else { return nil }

        let movieQID = db.text(statement, 0) ?? ""
        let tmdbID = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : db.int(statement, 1)
        let releaseDate = db.text(statement, 2)
        let releaseYear = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : db.int(statement, 3)
        let runtime = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : Int(db.double(statement, 4).rounded())
        let labelsJSON = db.text(statement, 5) ?? "{}"
        let titleEN = db.text(statement, 6) ?? movieQID
        let titleZH = db.text(statement, 7) ?? titleEN
        let title = CSVContentDecoder.localizedLabel(
            json: labelsJSON,
            preferredLanguage: preferredLanguage
        ) ?? (LanguageResolver.normalizedCode(preferredLanguage) == "zh-Hans" ? titleZH : titleEN)
        let directors = CSVContentDecoder.namedEntities(json: db.text(statement, 8) ?? "[]")
        let countries = CSVContentDecoder.namedEntities(json: db.text(statement, 9) ?? "[]")
        let genres = CSVContentDecoder.namedEntities(json: db.text(statement, 10) ?? "[]")
        let languages = CSVContentDecoder.namedEntities(json: db.text(statement, 11) ?? "[]")

        return MovieViewData(
            id: id,
            movieQID: movieQID,
            imdbID: db.text(statement, 20),
            tmdbID: tmdbID,
            title: title,
            overview: {
                let supplied = db.text(statement, 15) ?? ""
                return supplied.isEmpty ? (db.text(statement, 13) ?? "") : supplied
            }(),
            tagline: db.text(statement, 14) ?? "",
            overviewSource: db.text(statement, 16) ?? "",
            overviewSourceTitle: db.text(statement, 17) ?? "",
            overviewSourceURL: db.text(statement, 18) ?? "",
            overviewLicense: db.text(statement, 19) ?? "",
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            runtimeMinutes: runtime,
            sourceImage: db.text(statement, 12),
            originalLanguage: languages.first?.name ?? "—",
            rating: 0,
            voteCount: 0,
            rankingScore: 0,
            smallPosterFilename: nil,
            largePosterURL: nil,
            backdropURL: nil,
            director: directors.isEmpty ? nil : directors.map(\.name).joined(separator: " · "),
            originCountries: countries.map(\.name),
            isDocumentary: genres.contains { $0.name.localizedCaseInsensitiveContains("documentary") },
            genres: genres.map(\.name),
            timeRanges: timeRanges(movieQID: movieQID),
            locations: locations(movieQID: movieQID, preferredLanguage: preferredLanguage),
            cast: []
        )
    }

    private func movieIDs(startYear: Int, endYear: Int, targetQID: String) -> [Int] {
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
        ) AND (
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
        ORDER BY m.release_year IS NULL, m.release_year DESC, m.title_en COLLATE NOCASE
        LIMIT 300
        """
        guard let statement = try? db.prepare(
            sql,
            bindings: [
                .int(endYear), .int(startYear),
                .int(StoryTimeAvailabilityMatcher.includesUnknown(startYear: startYear, endYear: endYear) ? 1 : 0),
                .text(targetQID), .text(targetQID)
            ]
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
        SELECT raw_place_qid,raw_place_labels_json,raw_place_name_en,raw_place_name_zh
        FROM movie_locations
        WHERE movie_qid=?
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
            values.append(StoryLocation(rawPlaceQID: qid, name: name))
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

actor MovieSearchWorker {
    private let content = try? ContentRepository()

    func suggestions(query: String, preferredLanguage: String) -> [MovieViewData] {
        guard !Task.isCancelled else { return [] }
        return content?.movieSearchMatches(
            query: query,
            preferredLanguage: preferredLanguage
        ) ?? []
    }
}
