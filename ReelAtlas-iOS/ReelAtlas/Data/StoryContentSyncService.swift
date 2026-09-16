import Foundation
import SQLite3

/// Initial 250 films are committed before the UI is released; remaining pages are resumable.
actor StoryContentSyncService {
    struct Manifest: Decodable {
        let version: Int
        let sourceVersion: String
        let rowCounts: [String: Int]
        enum CodingKeys: String, CodingKey {
            case version, rowCounts = "row_counts", sourceVersion = "source_version"
        }
    }

    struct SyncProgress: Sendable {
        let downloaded: Int
        let total: Int
        let isComplete: Bool
    }

    private let baseURL = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1")!
    private let publishableKey = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"
    private let pageSize = 1_000
    private let batchSize = 250
    private let formatVersion = "full-catalog-v2"

    func ensureCurrentContent() async throws -> URL {
        let destination = try ContentRepository.cacheURL()
        do {
            let manifest = try await fetchManifest()
            let expected = manifest.sourceVersion + ":" + formatVersion
            if FileManager.default.fileExists(atPath: destination.path),
               Self.value(at: destination, key: "sync_target_version") == expected {
                return destination  // Complete or interrupted: synchronizeRemaining() handles the cursor.
            }
            try await rebuildFirstBatch(destination: destination, manifest: manifest)
            return destination
        } catch {
            // Do not destroy a usable published snapshot on a transient network error.
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            throw error
        }
    }

    func progress() throws -> SyncProgress {
        let url = try ContentRepository.cacheURL()
        let total = Int(Self.value(at: url, key: "sync_total") ?? "") ?? 0
        let downloaded = Int(Self.value(at: url, key: "sync_downloaded") ?? "") ?? 0
        return SyncProgress(downloaded: downloaded, total: total,
                            isComplete: Self.value(at: url, key: "sync_complete") == "1")
    }

    /// Called after the initial view appears; iOS may suspend it in the background, so checkpoint each page.
    func synchronizeRemaining(onBatch: @escaping @Sendable (SyncProgress) async -> Void) async {
        guard let manifest = try? await fetchManifest(),
              let url = try? ContentRepository.cacheURL(),
              Self.value(at: url, key: "sync_target_version") == manifest.sourceVersion + ":" + formatVersion,
              Self.value(at: url, key: "sync_complete") != "1" else { return }
        var cursor = Int(Self.value(at: url, key: "sync_cursor") ?? "") ?? 0
        let total = manifest.rowCounts["story_movies"] ?? 0
        while !Task.isCancelled {
            do {
                let batch = try await fetchMovieBatch(after: cursor)
                let last = batch.last.flatMap { ($0["legacy_id"] as? NSNumber)?.intValue } ?? cursor
                let completed = batch.count < batchSize
                try await importBatch(at: url, movies: batch, cursor: last,
                                      total: total, target: manifest.sourceVersion + ":" + formatVersion,
                                      version: manifest.sourceVersion, complete: completed)
                cursor = last
                let state = try progress()
                await onBatch(state)
                if completed { return }
            } catch {
                // Retain the last committed cursor and continue next foreground launch.
                return
            }
        }
    }

    private func fetchManifest() async throws -> Manifest {
        var components = URLComponents(url: baseURL.appendingPathComponent("dataset_meta"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "dataset_name", value: "eq.reelspan_story_content"),
                                 URLQueryItem(name: "select", value: "version,source_version,row_counts")]
        let data = try await request(components.url!)
        guard let manifest = try JSONDecoder().decode([Manifest].self, from: data).first,
              !manifest.sourceVersion.isEmpty else {
            throw SQLiteError.open("Published content manifest is unavailable")
        }
        return manifest
    }

    private func fetchMovieBatch(after cursor: Int) async throws -> [[String: Any]] {
        var components = URLComponents(url: baseURL.appendingPathComponent("story_movies"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "*"),
                                 URLQueryItem(name: "is_deleted", value: "eq.false"),
                                 URLQueryItem(name: "legacy_id", value: "gt.\(cursor)"),
                                 URLQueryItem(name: "order", value: "legacy_id.asc"),
                                 URLQueryItem(name: "limit", value: String(batchSize))]
        guard let result = try JSONSerialization.jsonObject(with: try await request(components.url!)) as? [[String: Any]] else {
            throw SQLiteError.step("Invalid movie page")
        }
        return result
    }

    private func rebuildFirstBatch(destination: URL, manifest: Manifest) async throws {
        guard let schemaURL = Bundle.main.url(forResource: "schema", withExtension: "sql") else {
            throw SQLiteError.open("Content cache schema is missing")
        }
        let replacement = destination.deletingLastPathComponent().appendingPathComponent("content-replacement.sqlite")
        try? FileManager.default.removeItem(at: replacement)
        do {
            // Keep replacement private until the complete first batch is committed.
            do {
                let db = try SQLiteDatabase(url: replacement, readOnly: false)
                try db.execute(String(contentsOf: schemaURL, encoding: .utf8))
                try db.execute("BEGIN IMMEDIATE")
                do {
                    try await importTargets(db)
                    try await importPlaces(db)
                    try await importTimeConcepts(db)
                    try db.execute("COMMIT")
                } catch {
                    try? db.execute("ROLLBACK")
                    throw error
                }
            }
            let first = try await fetchMovieBatch(after: 0)
            guard !first.isEmpty else { throw SQLiteError.open("Published catalog has no films") }
            let cursor = (first.last?["legacy_id"] as? NSNumber)?.intValue ?? 0
            try await importBatch(at: replacement, movies: first, cursor: cursor,
                                  total: manifest.rowCounts["story_movies"] ?? 0,
                                  target: manifest.sourceVersion + ":" + formatVersion,
                                  version: manifest.sourceVersion, complete: first.count < batchSize)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
            } else {
                try FileManager.default.moveItem(at: replacement, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw error
        }
    }

    private func importBatch(at url: URL, movies: [[String: Any]], cursor: Int,
                             total: Int, target: String, version: String, complete: Bool) async throws {
        let qids = movies.compactMap { $0["movie_qid"] as? String }
        let filter = "in.(\(qids.joined(separator: ",")))"
        let locations = qids.isEmpty ? [] : try await rows(table: "story_movie_locations",
                      filters: [URLQueryItem(name: "movie_qid", value: filter)])
        let periods = qids.isEmpty ? [] : try await rows(table: "story_movie_periods",
                      filters: [URLQueryItem(name: "movie_qid", value: filter)])
        let matches = qids.isEmpty ? [] : try await rows(table: "story_movie_target_matches",
                      filters: [URLQueryItem(name: "movie_qid", value: filter)])
        let db = try SQLiteDatabase(url: url, readOnly: false)
        try db.execute("BEGIN IMMEDIATE")
        do {
            try importMovies(db, rows: movies)
            try importLocations(db, rows: locations)
            try importPeriods(db, rows: periods)
            try importTargetMatches(db, rows: matches)
            let nextCount = try movieCount(db)
            for (key, value) in ["sync_target_version": target, "sync_cursor": String(cursor),
                                 "sync_downloaded": String(nextCount), "sync_total": String(total),
                                 "sync_complete": complete ? "1" : "0",
                                 "database_version": complete ? version : "Syncing \(version)",
                                 "source_format": "supabase-story-content-full-v2"] {
                try insert(db,"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",[.text(key),.text(value)])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func movieCount(_ db: SQLiteDatabase) throws -> Int {
        let stmt = try db.prepare("SELECT count(*) FROM movies")
        defer { sqlite3_finalize(stmt) }
        return try db.step(stmt) ? db.int(stmt,0) : 0
    }

    private static func value(at url: URL, key: String) -> String? {
        guard let db = try? SQLiteDatabase(url: url, readOnly: true),
              let stmt = try? db.prepare("SELECT value FROM metadata WHERE key=?", bindings: [.text(key)]) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard (try? db.step(stmt)) == true else { return nil }
        return db.text(stmt,0)
    }

    private func importTimeConcepts(_ database: SQLiteDatabase) async throws {
        try await forEachRow(table: "story_time_concepts") { row in
            try self.insert(database, """
                INSERT INTO time_concepts(concept_qid,category,name_en,name_zh,labels_json,start_year,end_year)
                VALUES(?,?,?,?,?,?,?)
                """, [
                    .text(self.requiredString(row,"concept_qid")),
                    .text(self.requiredString(row,"category")),
                    .text(self.requiredString(row,"name_en")),
                    .text(self.requiredString(row,"name_zh")),
                    .text(try self.jsonString(row["labels"])),
                    self.optionalInt(row["start_year"]),self.optionalInt(row["end_year"])
                ])
        }
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

    private func importMovies(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows {
            let qid = self.requiredString(row, "movie_qid")
            try self.insert(database, """
            INSERT INTO movies(
              movie_qid,id,title_en,title_zh,labels_json,director_qids_json,
              directors_json,origin_country_qids_json,origin_countries_json,
              genre_qids_json,genres_json,original_language_qids_json,
              original_languages_json,imdb_id,tmdb_movie_id,period_qids_json
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(qid), .int(self.requiredInt(row, "legacy_id")),
                .text(qid), .text(qid), .text("{}"), .text("[]"), .text("[]"),
                .text("[]"), .text("[]"), .text("[]"), .text("[]"),
                .text("[]"), .text("[]"), self.optionalText(row["imdb_id"]),
                self.optionalInt(row["tmdb_id"]), .text("[]")
            ])
        }
    }

    private func importPlaces(_ database: SQLiteDatabase) async throws {
        try await forEachRow(table: "story_places") { row in
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

    private func importPeriods(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows {
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
            "story_movie_periods": "movie_qid.asc,period_qid.asc",
            "story_time_concepts": "concept_qid.asc"
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
