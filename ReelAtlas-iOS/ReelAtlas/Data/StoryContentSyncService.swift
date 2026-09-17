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
    private let databaseURL: URL?
    private let schemaSQL: String?
    private let transport: (@Sendable (URLRequest) async throws -> Data)?
    private var isSynchronizing = false
    private(set) var lastSyncError: String?

    init(databaseURL: URL? = nil, schemaSQL: String? = nil,
         transport: (@Sendable (URLRequest) async throws -> Data)? = nil) {
        self.databaseURL = databaseURL; self.schemaSQL = schemaSQL; self.transport = transport
    }

    private func cacheURL() throws -> URL { try databaseURL ?? ContentRepository.cacheURL() }

    private func cacheSchema() throws -> String {
        if let schemaSQL { return schemaSQL }
        guard let url = Bundle.main.url(forResource: "schema", withExtension: "sql") else {
            throw SQLiteError.open("Content cache schema is missing")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func isCompatible(_ url: URL) -> Bool {
        guard Self.value(at: url, key: "source_format") == "supabase-story-content-full-v2",
              let db = try? SQLiteDatabase(url: url, readOnly: true) else { return false }
        return CatalogSyncSchema.tables.allSatisfy { table in
            guard let stmt = try? db.prepare("SELECT \(table.fields.map(\.local).joined(separator: ",")) FROM \(table.local) LIMIT 0") else { return false }
            sqlite3_finalize(stmt); return true
        }
    }

    func ensureCurrentContent() async throws -> URL {
        let destination = try cacheURL()
        // A usable on-device cache never waits for the network or gets replaced at launch.
        if FileManager.default.fileExists(atPath: destination.path) {
            do { try migrateExistingCache(at: destination) }
            catch { lastSyncError = error.localizedDescription }
            return destination
        }
        let manifest = try await fetchManifest()
        try await rebuildFirstBatch(destination: destination, manifest: manifest)
        return destination
    }

    private func migrateExistingCache(at url: URL) throws {
        let db = try SQLiteDatabase(url: url, readOnly: false)
        // Check the known existing story schema before making any change to an older file.
        for table in CatalogSyncSchema.tables where table.local != "time_concepts" {
            let stmt = try db.prepare("SELECT \(table.fields.map(\.local).joined(separator: ",")) FROM \(table.local) LIMIT 0")
            sqlite3_finalize(stmt)
        }
        let metadata = try db.prepare("SELECT key,value FROM metadata LIMIT 0")
        sqlite3_finalize(metadata)
        let priorFormat = Self.value(at: url, key: "source_format")
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS time_concepts (
                  concept_qid TEXT PRIMARY KEY, category TEXT NOT NULL, name_en TEXT NOT NULL,
                  name_zh TEXT NOT NULL, labels_json TEXT NOT NULL CHECK(json_valid(labels_json)),
                  start_year INTEGER, end_year INTEGER);
                CREATE INDEX IF NOT EXISTS idx_time_concepts_category ON time_concepts(category,name_en);
                """)
            // Legacy matched-film caches can join the full catalog by adding only missing rows.
            if priorFormat != "supabase-story-content-full-v2" {
                try insert(db,"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",[.text("source_format"),.text("supabase-story-content-full-v2")])
                try insert(db,"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",[.text("sync_complete"),.text("0")])
            }
            for key in ["sync_downloaded","sync_total"] {
                try insert(db,"INSERT OR IGNORE INTO metadata(key,value) VALUES (?,?)",[.text(key),.text(String(try movieCount(db)))])
            }
            for table in CatalogSyncSchema.tables {
                let stmt = try db.prepare("SELECT \(table.fields.map(\.local).joined(separator: ",")) FROM \(table.local) LIMIT 0")
                sqlite3_finalize(stmt)
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }

    func progress() throws -> SyncProgress {
        let url = try cacheURL()
        let total = Int(Self.value(at: url, key: "sync_total") ?? "") ?? 0
        let downloaded = Int(Self.value(at: url, key: "sync_downloaded") ?? "") ?? 0
        return SyncProgress(downloaded: downloaded, total: total,
                            isComplete: Self.value(at: url, key: "sync_complete") == "1")
    }

    /// Called after the initial view appears; iOS may suspend it in the background, so checkpoint each page.
    func synchronizeRemaining(onBatch: @escaping @Sendable (SyncProgress) async -> Void) async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        lastSyncError = nil
        defer { isSynchronizing = false }
        do {
            let manifest = try await fetchManifest()
            let url = try cacheURL()
            guard isCompatible(url) else { throw SQLiteError.open("Compatible story cache is unavailable") }
            // Diff all committed rows, including interrupted initial downloads. Parent-table
            // changes must be applied before new movies/relationships, even without a version bump.
            try Task.checkCancellation()
            // Always reconcile: content edits and removals can occur without a version bump.
            try await reconcile(at: url, manifest: manifest, onBatch: onBatch)
        } catch {
            // Completed metadata stays at the previous version until the entire diff is verified.
            lastSyncError = error.localizedDescription
            NSLog("[ReelSpan] Background content reconciliation failed: %@", String(describing: error))
        }
    }

    private struct IndexEntry: Decodable {
        let row_key: String
        let fingerprint: String
    }

    private func remoteIndex(_ table: CatalogSyncSchema.Table) async throws -> [String: String] {
        var index: [String: String] = [:]
        var after = ""
        let indexPageSize = table.local == "movies" ? 5000 : 1000
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: baseURL.appendingPathComponent("rpc/reelspan_catalog_index"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["p_table": table.remote, "p_after": after, "p_limit": indexPageSize])
            let page = try JSONDecoder().decode([IndexEntry].self, from: try await perform(req))
            for entry in page {
                guard entry.row_key.utf8.lexicographicallyPrecedes(after.utf8) == false,
                      entry.row_key != after, index[entry.row_key] == nil else {
                    throw SQLiteError.step("Invalid catalog index order")
                }
                index[entry.row_key] = entry.fingerprint
            }
            if page.count < indexPageSize { return index }
            guard let last = page.last else { return index }
            after = last.row_key
        }
    }

    private func reconcile(at url: URL, manifest: Manifest,
                           onBatch: @escaping @Sendable (SyncProgress) async -> Void) async throws {
        // Obtain all indexes before writes so failures cannot be mistaken for an empty catalog.
        var indexes: [String: [String: String]] = [:]
        for table in CatalogSyncSchema.tables { indexes[table.local] = try await remoteIndex(table) }
        guard !(indexes["movies"] ?? [:]).isEmpty else { throw SQLiteError.step("Published catalog is empty") }
        let db = try SQLiteDatabase(url: url, readOnly: false)
        try db.execute("PRAGMA foreign_keys=ON")
        for table in CatalogSyncSchema.tables {
            let remote = indexes[table.local]!
            let local = try table.localIndex(db)
            let changed = remote.keys.filter { remote[$0] != local[$0] }.sorted()
            // Bound request URLs and response memory. Composite keys are matched exactly after fetching.
            let bodyBatchSize = table.keys.count == 1 ? 100 : 30
            for offset in stride(from: 0, to: changed.count, by: bodyBatchSize) {
                try Task.checkCancellation()
                let keys = Array(changed.dropFirst(offset).prefix(bodyBatchSize))
                let keyFields = table.keys.map { key in table.fields.first { $0.local == key }!.remote }
                let filters: [URLQueryItem]
                if keyFields.count == 1 {
                    filters = [URLQueryItem(name: keyFields[0], value: "in.(\(keys.joined(separator: ",")))")]
                } else {
                    let terms = keys.map { key in
                        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        return "and(" + zip(keyFields,parts).map { "\($0.0).eq.\($0.1)" }.joined(separator: ",") + ")"
                    }
                    filters = [URLQueryItem(name: "or", value: "(" + terms.joined(separator: ",") + ")")]
                }
                let bodies = try await rows(table: table.remote, filters: filters)
                let requested = Set(keys)
                var matched: [String: [String: Any]] = [:]
                for row in bodies {
                    let key = table.rowKey(row)
                    if requested.contains(key) {
                        guard try table.fingerprint(row) == remote[key] else {
                            throw SQLiteError.step("Catalog changed while downloading; retry later")
                        }
                        matched[key] = row
                    }
                }
                guard matched.count == requested.count else { throw SQLiteError.step("Incomplete catalog response; keeping existing rows") }
                try db.execute("BEGIN IMMEDIATE")
                do {
                    for key in keys { try upsert(table, row: matched[key]!, db: db) }
                    try db.execute("COMMIT")
                } catch { try? db.execute("ROLLBACK"); throw error }
                if table.local == "movies", Self.value(at: url, key: "sync_complete") != "1" {
                    await onBatch(SyncProgress(downloaded: try movieCount(db), total: indexes["movies"]!.count, isComplete: false))
                }
            }
        }
        // Verify a second metadata pass before pruning and publishing the completed local version.
        for table in CatalogSyncSchema.tables {
            guard try await remoteIndex(table) == indexes[table.local] else {
                throw SQLiteError.step("Catalog changed during synchronization; existing data retained")
            }
        }
        let latest = try await fetchManifest()
        guard latest.sourceVersion == manifest.sourceVersion else { throw SQLiteError.step("A newer catalog was published; retry later") }
        try db.execute("BEGIN IMMEDIATE")
        do {
            for table in CatalogSyncSchema.tables.reversed() {
                let local = try table.localIndex(db)
                for key in local.keys where indexes[table.local]![key] == nil {
                    let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    let whereSQL = table.keys.map { "\($0)=?" }.joined(separator: " AND ")
                    try insert(db, "DELETE FROM \(table.local) WHERE \(whereSQL)", parts.map(SQLiteBindValue.text))
                }
            }
            // Parent cascades must not silently remove a still-published relationship.
            for table in CatalogSyncSchema.tables {
                guard try table.localIndex(db) == indexes[table.local] else {
                    throw SQLiteError.step("Catalog relationships failed verification")
                }
            }
            let count = try movieCount(db)
            for (key,value) in ["sync_target_version": manifest.sourceVersion + ":" + formatVersion,
                                "sync_complete": "1", "sync_total": String(count), "sync_downloaded": String(count),
                                "database_version": manifest.sourceVersion] {
                try insert(db,"INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)",[.text(key),.text(value)])
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        await onBatch(try progress())
    }

    private func upsert(_ table: CatalogSyncSchema.Table, row: [String: Any], db: SQLiteDatabase) throws {
        let columns = table.fields.map(\.local)
        var bindings: [SQLiteBindValue] = try table.fields.map { field in
            let value = row[field.remote]
            switch field.kind {
            case .text: return optionalText(value)
            case .int: return optionalInt(value)
            case .double: return value == nil || value is NSNull ? .null : .double(requiredDouble(row, field.remote))
            case .bool: return optionalBool(value)
            case .json: return .text(try jsonString(value))
            }
        }
        var insertColumns = columns
        // Movie enrichment is a separate cache concern. On an existing movie only story IDs change.
        if table.local == "movies" {
            let defaults: [String: String] = ["title_en": requiredString(row,"movie_qid"), "title_zh": requiredString(row,"movie_qid"),
                "labels_json": "{}", "director_qids_json": "[]", "directors_json": "[]", "origin_country_qids_json": "[]",
                "origin_countries_json": "[]", "genre_qids_json": "[]", "genres_json": "[]", "original_language_qids_json": "[]",
                "original_languages_json": "[]", "period_qids_json": "[]"]
            for key in defaults.keys.sorted() { insertColumns.append(key); bindings.append(.text(defaults[key]!)) }
        }
        let updates = columns.filter { !table.keys.contains($0) }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql = "INSERT INTO \(table.local)(\(insertColumns.joined(separator: ","))) VALUES (\(insertColumns.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(table.keys.joined(separator: ","))) DO UPDATE SET \(updates)"
        try insert(db,sql,bindings)
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
        let schema = try cacheSchema()
        let replacement = destination.deletingLastPathComponent().appendingPathComponent("content-replacement.sqlite")
        try? FileManager.default.removeItem(at: replacement)
        do {
            // Keep replacement private until the complete first batch is committed.
            do {
                let db = try SQLiteDatabase(url: replacement, readOnly: false)
                try db.execute(schema)
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
            // Initialization is for a missing cache only; never replace an existing database.
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw SQLiteError.open("Existing content cache retained")
            }
            try FileManager.default.moveItem(at: replacement, to: destination)
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
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("BEGIN IMMEDIATE")
        do {
            for row in movies { try upsert(CatalogSyncSchema.tables.first { $0.local == "movies" }!, row: row, db: db) }
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
            try self.upsert(CatalogSyncSchema.tables.first { $0.local == "time_concepts" }!, row: row, db: database)
        }
    }

    private func importTargets(_ database: SQLiteDatabase) async throws {
        try await forEachRow(table: "story_targets") { row in
            try self.upsert(CatalogSyncSchema.tables.first { $0.local == "targets" }!, row: row, db: database)
        }
    }

    private func importMovies(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows { try upsert(CatalogSyncSchema.tables.first { $0.local == "movies" }!, row: row, db: database) }
    }

    private func importPlaces(_ database: SQLiteDatabase) async throws {
        try await forEachRow(table: "story_places") { row in
            try self.upsert(CatalogSyncSchema.tables.first { $0.local == "places" }!, row: row, db: database)
        }
    }

    private func importTargetMatches(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows { try upsert(CatalogSyncSchema.tables.first { $0.local == "movie_target_matches" }!, row: row, db: database) }
    }

    private func importLocations(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows { try upsert(CatalogSyncSchema.tables.first { $0.local == "movie_locations" }!, row: row, db: database) }
    }

    private func importPeriods(_ database: SQLiteDatabase, rows: [[String: Any]]) throws {
        for row in rows { try upsert(CatalogSyncSchema.tables.first { $0.local == "movie_periods" }!, row: row, db: database) }
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

    private func request(_ url: URL) async throws -> Data { try await perform(URLRequest(url: url)) }

    private func perform(_ original: URLRequest) async throws -> Data {
        var request = original
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 20
        if let transport { return try await transport(request) }
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SQLiteError.step("Invalid Supabase response")
                }
                guard (200...299).contains(http.statusCode) else {
                    // The old generic error concealed the actual status (401/404/429/5xx).
                    // Log only the PostgREST error code and endpoint, never response bodies or keys.
                    let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String ?? "unknown"
                    NSLog("[ReelSpan] Supabase HTTP %ld PostgREST=%@ path=%@", http.statusCode, code,
                          request.url?.path ?? "unknown")
                    if attempt < 2 && [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                        try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                        continue
                    }
                    throw SQLiteError.step("Supabase HTTP \(http.statusCode) (\(code))")
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("[ReelSpan] Supabase sync failed path=%@ error=%@",
                      request.url?.path ?? "unknown", String(describing: error))
                if attempt < 2, error is URLError {
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                    continue
                }
                throw error
            }
        }
        throw SQLiteError.step("Supabase sync retry exhausted")
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
