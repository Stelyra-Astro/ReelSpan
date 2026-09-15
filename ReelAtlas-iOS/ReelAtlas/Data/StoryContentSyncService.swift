import Foundation
import SQLite3

actor StoryContentSyncService {
    struct Manifest: Decodable {
        let version: Int
        let sourceVersion: String

        enum CodingKeys: String, CodingKey {
            case version
            case sourceVersion = "source_version"
        }
    }

    private let baseURL = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1")!
    private let publishableKey = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"
    private let pageSize = 1_000

    func ensureCurrentContent() async throws -> URL {
        let destination = try ContentRepository.cacheURL()
        do {
            let manifest = try await fetchManifest()
            if FileManager.default.fileExists(atPath: destination.path),
               ContentRepository.metadataVersion(at: destination) == manifest.sourceVersion {
                return destination
            }
            return try await rebuildCache(destination: destination, manifest: manifest)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination
            }
            throw error
        }
    }

    private func fetchManifest() async throws -> Manifest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("dataset_meta"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "dataset_name", value: "eq.reelspan_story_content"),
            URLQueryItem(name: "select", value: "version,source_version")
        ]
        let data = try await request(components.url!)
        guard let manifest = try JSONDecoder().decode([Manifest].self, from: data).first,
              !manifest.sourceVersion.isEmpty else {
            throw SQLiteError.open("ReelSpan content manifest is unavailable")
        }
        return manifest
    }

    private func rebuildCache(destination: URL, manifest: Manifest) async throws -> URL {
        let matchRows = try await rows(table: "story_movie_target_matches")
        guard let scope = ContentBootstrapScope(
            movieQIDs: matchRows.compactMap { $0["movie_qid"] as? String }
        ) else {
            throw SQLiteError.open("ReelSpan content has no published movie matches")
        }
        let movieFilter = URLQueryItem(name: "movie_qid", value: scope.postgRESTMovieFilter)
        let locationRows = try await rows(table: "story_movie_locations", filters: [movieFilter])
        let placeKeys = [
            "raw_place_qid", "historical_capital_qid", "modern_place_qid",
            "city_qid", "admin1_qid", "country_qid"
        ]
        let referencedPlaceQIDs = matchRows.compactMap { $0["target_qid"] as? String }
            + locationRows.flatMap { row in placeKeys.compactMap { row[$0] as? String } }
        guard let placeFilter = ContentBootstrapScope.postgRESTFilter(qids: referencedPlaceQIDs) else {
            throw SQLiteError.open("ReelSpan content has no published locations")
        }
        guard let schemaURL = Bundle.main.url(forResource: "schema", withExtension: "sql") else {
            throw SQLiteError.open("Content cache schema is missing")
        }
        let replacement = destination.deletingLastPathComponent()
            .appendingPathComponent("content-replacement.sqlite")
        try? FileManager.default.removeItem(at: replacement)
        let database = try SQLiteDatabase(url: replacement, readOnly: false)
        try database.execute(String(contentsOf: schemaURL, encoding: .utf8))
        try database.execute("BEGIN IMMEDIATE")
        do {
            try await importTargets(database)
            try await importMovies(database, scope: scope)
            try await importPlaces(database, placeFilter: placeFilter)
            try importTargetMatches(database, rows: matchRows)
            try importLocations(database, rows: locationRows)
            try await importPeriods(database, scope: scope)
            try database.execute(
                "INSERT OR REPLACE INTO metadata(key,value) VALUES " +
                "('source_format','supabase-story-content-v1')," +
                "('database_version','\(sqlQuoted(manifest.sourceVersion))')," +
                "('supabase_version','\(manifest.version)')"
            )
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
        return destination
    }

    private func importTargets(_ database: SQLiteDatabase) async throws {
        try await forEachRow(table: "story_targets") { row in
            try self.insert(database, """
            INSERT INTO targets(
              target_qid,target_kind,name_en,name_zh,labels_json,admin1_qid,
              admin1_name_en,country_qid,country_name_en,film_count,candidate_count
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(self.requiredString(row, "target_qid")),
                .text(self.requiredString(row, "target_kind")),
                .text(self.requiredString(row, "name_en")),
                .text(self.requiredString(row, "name_zh")),
                .text(try self.jsonString(row["labels"])),
                self.optionalText(row["admin1_qid"]),
                self.optionalText(row["admin1_name_en"]),
                .text(self.requiredString(row, "country_qid")),
                .text(self.requiredString(row, "country_name_en")),
                .int(self.requiredInt(row, "film_count")),
                .int(self.requiredInt(row, "candidate_count"))
            ])
        }
    }

    private func importMovies(_ database: SQLiteDatabase, scope: ContentBootstrapScope) async throws {
        try await forEachRow(
            table: "story_movies",
            filters: [URLQueryItem(name: "movie_qid", value: scope.postgRESTMovieFilter)]
        ) { row in
            let qid = self.requiredString(row, "movie_qid")
            try self.insert(database, """
            INSERT INTO movies(movie_qid,id,imdb_id,tmdb_movie_id)
            VALUES(?,?,?,?)
            """, [
                .text(qid), .int(self.requiredInt(row, "legacy_id")),
                self.optionalText(row["imdb_id"]), self.optionalInt(row["tmdb_id"])
            ])
        }
    }

    private func importPlaces(_ database: SQLiteDatabase, placeFilter: String) async throws {
        try await forEachRow(
            table: "story_places",
            filters: [URLQueryItem(name: "place_qid", value: placeFilter)]
        ) { row in
            try self.insert(database, """
            INSERT INTO places(
              place_qid,name_en,name_zh,labels_json,type_qids_json,p131_qids_json,
              location_qids_json,country_qids_json,present_day_qids_json,
              replaced_by_qids_json,followed_by_qids_json,coordinate,dissolved_date
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(self.requiredString(row, "place_qid")),
                .text(self.requiredString(row, "name_en")),
                .text(self.requiredString(row, "name_zh")),
                .text(try self.jsonString(row["labels"])),
                .text(try self.jsonString(row["type_qids"])),
                .text(try self.jsonString(row["p131_qids"])),
                .text(try self.jsonString(row["location_qids"])),
                .text(try self.jsonString(row["country_qids"])),
                .text(try self.jsonString(row["present_day_qids"])),
                .text(try self.jsonString(row["replaced_by_qids"])),
                .text(try self.jsonString(row["followed_by_qids"])),
                self.optionalText(row["coordinate"]),
                self.optionalText(row["dissolved_date"])
            ])
        }
    }

    private func importTargetMatches(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows {
            try self.insert(database, """
            INSERT INTO movie_target_matches(
              movie_qid,target_qid,target_kind,matched_raw_location_count,
              matched_raw_place_qids_json,best_confidence
            ) VALUES(?,?,?,?,?,?)
            """, [
                .text(self.requiredString(row, "movie_qid")),
                .text(self.requiredString(row, "target_qid")),
                .text(self.requiredString(row, "target_kind")),
                .int(self.requiredInt(row, "matched_raw_location_count")),
                .text(try self.jsonString(row["matched_raw_place_qids"])),
                .double(self.requiredDouble(row, "best_confidence"))
            ])
        }
    }

    private func importLocations(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows {
            try self.insert(database, """
            INSERT INTO movie_locations VALUES(
              ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            )
            """, [
                .int(self.requiredInt(row, "id")), self.optionalText(row["source_target_qid"]),
                .text(self.requiredString(row, "movie_qid")), self.optionalBool(row["is_target_match"]),
                .text(self.requiredString(row, "raw_place_qid")),
                .text(self.requiredString(row, "raw_place_name_en")),
                .text(self.requiredString(row, "raw_place_name_zh")),
                .text(try self.jsonString(row["raw_place_labels"])),
                self.optionalText(row["historical_capital_qid"]), self.optionalText(row["historical_capital_name_en"]),
                self.optionalText(row["modern_place_qid"]), self.optionalText(row["modern_place_name_en"]),
                self.optionalText(row["city_qid"]), self.optionalText(row["city_name_en"]), self.optionalText(row["city_name_zh"]),
                self.optionalText(row["admin1_qid"]), self.optionalText(row["admin1_name_en"]), self.optionalText(row["admin1_name_zh"]),
                self.optionalText(row["country_qid"]), self.optionalText(row["country_name_en"]), self.optionalText(row["country_name_zh"]),
                .text(self.requiredString(row, "normalization_method")), self.optionalText(row["normalization_path"]),
                .double(self.requiredDouble(row, "confidence")), .text(self.requiredString(row, "status")),
                self.optionalText(row["notes"])
            ])
        }
    }

    private func importPeriods(_ database: SQLiteDatabase, scope: ContentBootstrapScope) async throws {
        try await forEachRow(
            table: "story_movie_periods",
            filters: [URLQueryItem(name: "movie_qid", value: scope.postgRESTMovieFilter)]
        ) { row in
            try self.insert(database, """
            INSERT INTO movie_periods(
              movie_qid,period_qid,period_name_en,period_name_zh,period_labels_json,
              start_year,end_year,interval_method
            ) VALUES(?,?,?,?,?,?,?,?)
            """, [
                .text(self.requiredString(row, "movie_qid")),
                .text(self.requiredString(row, "period_qid")),
                .text(self.requiredString(row, "period_name_en")),
                .text(self.requiredString(row, "period_name_zh")),
                .text(try self.jsonString(row["period_labels"])),
                self.optionalInt(row["start_year"]), self.optionalInt(row["end_year"]),
                .text(self.requiredString(row, "interval_method"))
            ])
        }
    }

    private func forEachRow(
        table: String,
        filters: [URLQueryItem] = [],
        consume: ([String: Any]) throws -> Void
    ) async throws {
        let orderBy = [
            "story_targets": "target_qid.asc",
            "story_movies": "movie_qid.asc",
            "story_places": "place_qid.asc",
            "story_movie_target_matches": "movie_qid.asc,target_qid.asc",
            "story_movie_locations": "id.asc",
            "story_movie_periods": "movie_qid.asc,period_qid.asc"
        ][table]!
        var offset = 0
        while true {
            var components = URLComponents(
                url: baseURL.appendingPathComponent(table),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "is_deleted", value: "eq.false"),
                URLQueryItem(name: "order", value: orderBy),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(pageSize))
            ] + filters
            let data = try await request(components.url!)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw SQLiteError.step("Invalid response for \(table)")
            }
            for row in rows { try consume(row) }
            if rows.count < pageSize { return }
            offset += rows.count
        }
    }

    private func rows(
        table: String,
        filters: [URLQueryItem] = []
    ) async throws -> [[String: Any]] {
        var values: [[String: Any]] = []
        try await forEachRow(table: table, filters: filters) { values.append($0) }
        return values
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SQLiteError.step("Supabase content request failed")
        }
        return data
    }

    private func insert(_ database: SQLiteDatabase, _ sql: String, _ bindings: [SQLiteBindValue]) throws {
        let statement = try database.prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        _ = try database.step(statement)
    }

    private func requiredString(_ row: [String: Any], _ key: String) -> String {
        row[key] as? String ?? ""
    }

    private func requiredInt(_ row: [String: Any], _ key: String) -> Int {
        (row[key] as? NSNumber)?.intValue ?? 0
    }

    private func requiredDouble(_ row: [String: Any], _ key: String) -> Double {
        (row[key] as? NSNumber)?.doubleValue ?? 0
    }

    private func optionalText(_ value: Any?) -> SQLiteBindValue {
        value is NSNull || value == nil ? .null : .text(value as? String ?? "")
    }

    private func optionalInt(_ value: Any?) -> SQLiteBindValue {
        guard let number = value as? NSNumber else { return .null }
        return .int(number.intValue)
    }

    private func optionalBool(_ value: Any?) -> SQLiteBindValue {
        guard let number = value as? NSNumber else { return .null }
        return .int(number.boolValue ? 1 : 0)
    }

    private func jsonString(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func sqlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
