import Foundation
import SQLite3

// The production defaults are unused; the harness supplies a real temporary database/schema.
enum ContentRepository { static func cacheURL() throws -> URL { fatalError("Inject databaseURL") } }

actor FixtureCatalog {
    var version = "old"
    var tables: [String: [[String: Any]]] = [:]
    var bodyRows = 0
    var failBodies = false
    var corruptIndex = false
    var omitBody = false
    init() {
        for spec in CatalogSyncSchema.tables { tables[spec.remote] = [] }
        tables["story_movies"] = [Self.movie("Q1",1,100), Self.movie("Q2",2,200)]
        tables["story_movie_periods"] = [Self.period("Q1","Q100",1901,2000),Self.period("Q1","Q199",1950,1950)]
    }
    private static func movie(_ qid: String,_ id: Int,_ tmdb: Int) -> [String: Any] {
        ["movie_qid":qid,"legacy_id":id,"tmdb_id":tmdb,"imdb_id":NSNull()]
    }
    private static func period(_ movie: String,_ qid: String,_ start: Int,_ end: Int) -> [String: Any] {
        ["movie_qid":movie,"period_qid":qid,"period_name_en":"Period","period_name_zh":"时期","period_labels":[:],"start_year":start,"end_year":end,"interval_method":"test"]
    }
    func change() {
        version = "new"
        tables["story_movies"] = [Self.movie("Q1",1,101), Self.movie("Q3",3,300)]
        tables["story_movie_periods"] = [Self.period("Q1","Q101",1801,1900),Self.period("Q3","Q102",1701,1800)]
    }
    func changeVersionOnly() { version = "no-content-change" }
    func resetReads() { bodyRows = 0 }
    func setFailure(_ enabled: Bool) { failBodies = enabled }
    func setOmit(_ enabled: Bool) { omitBody = enabled }
    func relationshipOnly() { version = "relationships"; tables["story_movie_periods"] = [Self.period("Q1","Q100",1601,1700),Self.period("Q1","Q199",1950,1950)] }
    func addMovieWithNewTargetWithoutVersionBump() {
        tables["story_movies"]!.append(Self.movie("Q4",4,400))
        tables["story_targets"] = [["target_qid":"Q9","target_kind":"country","name_en":"New country","name_zh":"新国家",
            "labels":[:],"admin1_qid":NSNull(),"admin1_name_en":NSNull(),"country_qid":"Q9","country_name_en":"New country",
            "film_count":1,"candidate_count":1]]
        tables["story_movie_target_matches"] = [["movie_qid":"Q4","target_qid":"Q9","target_kind":"country",
            "matched_raw_location_count":1,"matched_raw_place_qids":[],"best_confidence":1.0]]
    }
    func respond(_ request: URLRequest) throws -> Data {
        let url = request.url!
        let name = url.lastPathComponent
        if name == "dataset_meta" {
            return try encode([["version":1,"source_version":version,"row_counts":["story_movies":tables["story_movies"]!.count]]])
        }
        if name == "reelspan_catalog_index" {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let spec = CatalogSyncSchema.tables.first { $0.remote == payload["p_table"] as? String }!
            let after = payload["p_after"] as? String ?? ""
            let limit = payload["p_limit"] as? Int ?? 5000
            let rows = tables[spec.remote]!.sorted { spec.rowKey($0) < spec.rowKey($1) }.filter { spec.rowKey($0) > after }.prefix(limit)
            return try encode(try rows.map { ["row_key":spec.rowKey($0),"fingerprint":try spec.fingerprint($0)] })
        }
        if failBodies { throw SQLiteError.step("fixture network failure") }
        var rows = tables[name] ?? []
        let query = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems ?? []
        for item in query {
            let value = item.value ?? ""
            if item.name == "or" {
                let groups = value.dropFirst().dropLast().components(separatedBy: "),and(")
                rows = rows.filter { row in
                    groups.contains { group in
                        let terms = group.replacingOccurrences(of: "and(", with: "").replacingOccurrences(of: ")", with: "").split(separator: ",")
                        return terms.allSatisfy { term in
                            let parts = term.components(separatedBy: ".eq.")
                            return parts.count == 2 && String(describing: row[parts[0]] ?? "") == parts[1]
                        }
                    }
                }
            } else if value.hasPrefix("gt.") {
                rows = rows.filter { ($0[item.name] as? Int ?? 0) > Int(value.dropFirst(3))! }
            } else if value.hasPrefix("in.(") {
                let keys = Set(value.dropFirst(4).dropLast().split(separator:",").map(String.init))
                rows = rows.filter { keys.contains(String(describing:$0[item.name] ?? "")) }
            } else if value.hasPrefix("eq.") && item.name != "is_deleted" {
                rows = rows.filter { String(describing:$0[item.name] ?? "") == String(value.dropFirst(3)) }
            }
        }
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "1000") ?? 1000
        rows = Array(rows.dropFirst(offset).prefix(limit))
        if omitBody { rows = [] }
        bodyRows += rows.count
        return try encode(rows)
    }
    private func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) }
}

@main struct SyncChecks {
    static func check(_ condition: @autoclosure () throws -> Bool,_ message: String) {
        do { if try !condition() { fatalError(message) } } catch { fatalError("\(message): \(error)") }
    }
    static func scalar(_ url: URL,_ sql: String) throws -> String {
        let db = try SQLiteDatabase(url:url,readOnly:true)
        let stmt = try db.prepare(sql); defer { sqlite3_finalize(stmt) }
        return try db.step(stmt) ? (db.text(stmt,0) ?? "") : ""
    }
    static func main() async throws {
        if CommandLine.arguments.count > 2 {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            for table in CatalogSyncSchema.tables {
                let data = try Data(contentsOf: root.appendingPathComponent(table.remote + "-index.json"))
                let rows = try JSONSerialization.jsonObject(with: data) as! [[String: String]]
                let fingerprints = Dictionary(uniqueKeysWithValues: rows.map { ($0["row_key"]!, $0["fingerprint"]!) })
                let bodies = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(table.remote + "-body.json"))) as! [[String: Any]]
                var checked = 0
                for row in bodies {
                    let key = table.rowKey(row)
                    if let expected = fingerprints[key] { check(try table.fingerprint(row) == expected, "PostgreSQL/Swift fingerprint mismatch: \(table.remote) \(key)"); checked += 1 }
                }
                check(checked > 0, "No parity samples for \(table.remote)")
                print("PARITY PASS \(table.remote): \(checked) records")
            }
        }
        let schema = try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("cache.sqlite")
        let remote = FixtureCatalog()
        func service() -> StoryContentSyncService {
            StoryContentSyncService(databaseURL:url,schemaSQL:schema,transport:{ request in try await remote.respond(request) })
        }
        check(try CatalogSyncSchema.canonical([NSNull(),"时期",1,1.0,true,["z":1,"a":[]]]) == "a6:n;s6:时期d1;d1;b1;o2:s1:aa0:s1:zd1;","canonical framing")
        _ = try await service().ensureCurrentContent()
        check(try scalar(url,"SELECT count(*) FROM movies") == "2","first initialization")
        try SQLiteDatabase(url:url,readOnly:false).execute("UPDATE movies SET tmdb_overview='keep details' WHERE movie_qid='Q1'")
        await remote.changeVersionOnly(); await remote.resetReads()
        let unchanged = service()
        _ = try await unchanged.ensureCurrentContent()
        check(try scalar(url,"SELECT count(*) FROM movies") == "2","version bump must keep cache available")
        await unchanged.synchronizeRemaining { _ in }
        let noChangeReads = await remote.bodyRows
        check(noChangeReads == 0,"version-only update must fetch ZERO body rows, got \(noChangeReads)")
        check(try scalar(url,"SELECT value FROM metadata WHERE key='database_version'") == "no-content-change","completed version")
        await remote.relationshipOnly(); await remote.resetReads()
        let rel = service(); _ = try await rel.ensureCurrentContent(); await rel.synchronizeRemaining { _ in }
        check(try scalar(url,"SELECT start_year FROM movie_periods WHERE movie_qid='Q1'") == "1601","independent relationship edit")
        let relReads = await remote.bodyRows; check(relReads == 1,"only one period body fetched")
        await remote.change(); await remote.setFailure(true)
        let failing = service(); _ = try await failing.ensureCurrentContent(); await failing.synchronizeRemaining { _ in }
        check(try scalar(url,"SELECT count(*) FROM movies") == "2","network failure keeps cache")
        check(try scalar(url,"SELECT value FROM metadata WHERE key='database_version'") == "relationships","failure must not advance completed version")
        await remote.setFailure(false); await remote.setOmit(true)
        let incomplete = service(); _ = try await incomplete.ensureCurrentContent(); await incomplete.synchronizeRemaining { _ in }
        check(try scalar(url,"SELECT count(*) FROM movies WHERE movie_qid='Q2'") == "1","missing response must not prune old rows")
        await remote.setOmit(false)
        let restarted = service(); _ = try await restarted.ensureCurrentContent(); await restarted.synchronizeRemaining { _ in }
        check(try scalar(url,"SELECT group_concat(movie_qid) FROM (SELECT movie_qid FROM movies ORDER BY movie_qid)") == "Q1,Q3","insert/delete reconcile")
        check(try scalar(url,"SELECT tmdb_movie_id FROM movies WHERE movie_qid='Q1'") == "101","changed movie updated")
        check(try scalar(url,"SELECT tmdb_overview FROM movies WHERE movie_qid='Q1'") == "keep details","upsert must preserve metadata")
        check(try scalar(url,"SELECT group_concat(period_qid) FROM (SELECT period_qid FROM movie_periods ORDER BY period_qid)") == "Q101,Q102","period insert/delete reconcile")
        check(try scalar(url,"SELECT value FROM metadata WHERE key='database_version'") == "new","restart completes diff")
        await remote.resetReads()
        let again = service(); _ = try await again.ensureCurrentContent(); await again.synchronizeRemaining { _ in }
        let againReads = await remote.bodyRows; check(againReads == 0,"completed repeat has zero body reads")
        try SQLiteDatabase(url:url,readOnly:false).execute("DROP TABLE time_concepts; UPDATE metadata SET value='supabase-story-content-v1' WHERE key='source_format'")
        await remote.resetReads()
        let migrated = service(); _ = try await migrated.ensureCurrentContent()
        check(try scalar(url,"SELECT count(*) FROM movies") == "2", "legacy cache migration preserves movies")
        await migrated.synchronizeRemaining { _ in }
        let migrationReads = await remote.bodyRows; check(migrationReads == 0, "legacy cache should not redownload matching movies")
        check(try scalar(url,"SELECT value FROM metadata WHERE key='source_format'") == "supabase-story-content-full-v2", "in-place schema migration")
        try SQLiteDatabase(url:url,readOnly:false).execute("UPDATE metadata SET value='0' WHERE key='sync_complete'; UPDATE metadata SET value='3' WHERE key='sync_cursor'")
        await remote.addMovieWithNewTargetWithoutVersionBump()
        let partial = service(); _ = try await partial.ensureCurrentContent(); await partial.synchronizeRemaining { _ in }
        check(try scalar(url,"SELECT count(*) FROM movies") == "3", "partial cache can add movie with new parent in same source version")
        check(try scalar(url,"SELECT target_qid FROM movie_target_matches WHERE movie_qid='Q4'") == "Q9", "new parent must precede new relationship")
        let partialError = await partial.lastSyncError; check(partialError == nil, "partial sync must not get stuck on FK failure")
        print("PASS: version-only zero body reads; relationship-only diff; insert/update/delete; preserved metadata; network failure; incomplete responses; restart; idempotence; legacy migration; partial cache + new parent")
    }
}
