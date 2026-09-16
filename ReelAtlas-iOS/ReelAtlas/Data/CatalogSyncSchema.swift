import Foundation
import CryptoKit
import SQLite3

/// Only fields actually stored by the story cache participate in the content diff.
/// Remote timestamps and unrelated metadata cannot invalidate every local movie.
enum CatalogSyncSchema {
    enum Kind { case text, int, double, json, bool }
    struct Field {
        let local: String
        let remote: String
        let kind: Kind
        init(_ local: String, _ remote: String, _ kind: Kind) {
            self.local = local; self.remote = remote; self.kind = kind
        }
    }
    struct Table {
        let local: String
        let remote: String
        let keys: [String]
        let fields: [Field]
        var keyExpression: String { keys.map { "CAST(\($0) AS TEXT)" }.joined(separator: " || '|' || ") }
        func rowKey(_ row: [String: Any]) -> String {
            keys.map { key in
                let field = fields.first { $0.local == key }!
                return row[field.remote].map { String(describing: $0) } ?? ""
            }.joined(separator: "|")
        }
        func fingerprint(_ row: [String: Any]) throws -> String {
            let values: [Any] = fields.map { field in
                let value = row[field.remote] ?? NSNull()
                if field.kind == .bool, let number = value as? NSNumber { return number.boolValue ? 1 : 0 }
                return value
            }
            return try CatalogSyncSchema.fingerprint(values)
        }
        func localIndex(_ db: SQLiteDatabase) throws -> [String: String] {
            let columns = fields.map(\.local).joined(separator: ",")
            let stmt = try db.prepare("SELECT \(keyExpression),\(columns) FROM \(local)")
            defer { sqlite3_finalize(stmt) }
            var index: [String: String] = [:]
            while try db.step(stmt) {
                var values: [Any] = []
                for (offset, field) in fields.enumerated() {
                    let column = Int32(offset + 1)
                    if sqlite3_column_type(stmt, column) == SQLITE_NULL { values.append(NSNull()); continue }
                    switch field.kind {
                    case .text: values.append(db.text(stmt, column) ?? "")
                    case .int, .bool: values.append(db.int(stmt, column))
                    case .double: values.append(db.double(stmt, column))
                    case .json:
                        let text = db.text(stmt, column) ?? "null"
                        values.append(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
                    }
                }
                index[db.text(stmt, 0) ?? ""] = try CatalogSyncSchema.fingerprint(values)
            }
            return index
        }
    }

    // Parent tables precede relationships; removals are reconciled in reverse order.
    static let tables: [Table] = [
        Table(local: "targets", remote: "story_targets", keys: ["target_qid"], fields: [
            Field("target_qid", "target_qid", .text),
            Field("target_kind", "target_kind", .text),
            Field("name_en", "name_en", .text),
            Field("name_zh", "name_zh", .text),
            Field("labels_json", "labels", .json),
            Field("admin1_qid", "admin1_qid", .text),
            Field("admin1_name_en", "admin1_name_en", .text),
            Field("country_qid", "country_qid", .text),
            Field("country_name_en", "country_name_en", .text),
            Field("film_count", "film_count", .int),
            Field("candidate_count", "candidate_count", .int)
        ]),
        Table(local: "places", remote: "story_places", keys: ["place_qid"], fields: [
            Field("place_qid", "place_qid", .text),
            Field("name_en", "name_en", .text),
            Field("name_zh", "name_zh", .text),
            Field("labels_json", "labels", .json),
            Field("type_qids_json", "type_qids", .json),
            Field("p131_qids_json", "p131_qids", .json),
            Field("location_qids_json", "location_qids", .json),
            Field("country_qids_json", "country_qids", .json),
            Field("present_day_qids_json", "present_day_qids", .json),
            Field("replaced_by_qids_json", "replaced_by_qids", .json),
            Field("followed_by_qids_json", "followed_by_qids", .json),
            Field("coordinate", "coordinate", .text),
            Field("dissolved_date", "dissolved_date", .text)
        ]),
        Table(local: "time_concepts", remote: "story_time_concepts", keys: ["concept_qid"], fields: [
            Field("concept_qid", "concept_qid", .text),
            Field("category", "category", .text),
            Field("name_en", "name_en", .text),
            Field("name_zh", "name_zh", .text),
            Field("labels_json", "labels", .json),
            Field("start_year", "start_year", .int),
            Field("end_year", "end_year", .int)
        ]),
        Table(local: "movies", remote: "story_movies", keys: ["movie_qid"], fields: [
            Field("movie_qid", "movie_qid", .text),
            Field("id", "legacy_id", .int),
            Field("imdb_id", "imdb_id", .text),
            Field("tmdb_movie_id", "tmdb_id", .int)
        ]),
        Table(local: "movie_locations", remote: "story_movie_locations", keys: ["id"], fields: [
            Field("id", "id", .int),
            Field("source_target_qid", "source_target_qid", .text),
            Field("movie_qid", "movie_qid", .text),
            Field("is_target_match", "is_target_match", .bool),
            Field("raw_place_qid", "raw_place_qid", .text),
            Field("raw_place_name_en", "raw_place_name_en", .text),
            Field("raw_place_name_zh", "raw_place_name_zh", .text),
            Field("raw_place_labels_json", "raw_place_labels", .json),
            Field("historical_capital_qid", "historical_capital_qid", .text),
            Field("historical_capital_name_en", "historical_capital_name_en", .text),
            Field("modern_place_qid", "modern_place_qid", .text),
            Field("modern_place_name_en", "modern_place_name_en", .text),
            Field("city_qid", "city_qid", .text),
            Field("city_name_en", "city_name_en", .text),
            Field("city_name_zh", "city_name_zh", .text),
            Field("admin1_qid", "admin1_qid", .text),
            Field("admin1_name_en", "admin1_name_en", .text),
            Field("admin1_name_zh", "admin1_name_zh", .text),
            Field("country_qid", "country_qid", .text),
            Field("country_name_en", "country_name_en", .text),
            Field("country_name_zh", "country_name_zh", .text),
            Field("normalization_method", "normalization_method", .text),
            Field("normalization_path", "normalization_path", .text),
            Field("confidence", "confidence", .double),
            Field("status", "status", .text),
            Field("notes", "notes", .text)
        ]),
        Table(local: "movie_periods", remote: "story_movie_periods", keys: ["movie_qid", "period_qid"], fields: [
            Field("movie_qid", "movie_qid", .text),
            Field("period_qid", "period_qid", .text),
            Field("period_name_en", "period_name_en", .text),
            Field("period_name_zh", "period_name_zh", .text),
            Field("period_labels_json", "period_labels", .json),
            Field("start_year", "start_year", .int),
            Field("end_year", "end_year", .int),
            Field("interval_method", "interval_method", .text)
        ]),
        Table(local: "movie_target_matches", remote: "story_movie_target_matches", keys: ["movie_qid", "target_qid"], fields: [
            Field("movie_qid", "movie_qid", .text),
            Field("target_qid", "target_qid", .text),
            Field("target_kind", "target_kind", .text),
            Field("matched_raw_location_count", "matched_raw_location_count", .int),
            Field("matched_raw_place_qids_json", "matched_raw_place_qids", .json),
            Field("best_confidence", "best_confidence", .double)
        ])
    ]

    static func fingerprint(_ value: Any) throws -> String {
        let text = try canonical(value)
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Language-independent framing shared with the read-only PostgreSQL RPC.
    /// JSON whitespace/key order and equivalent numeric spellings are irrelevant.
    static func canonical(_ value: Any) throws -> String {
        if value is NSNull { return "n;" }
        if let value = value as? String { return "s\(value.utf8.count):\(value)" }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "b1;" : "b0;" }
            guard let decimal = Decimal(string: value.stringValue, locale: Locale(identifier: "en_US_POSIX")) else {
                throw SQLiteError.step("Invalid catalog number")
            }
            return "d\(NSDecimalNumber(decimal: decimal).stringValue);"
        }
        if let values = value as? [Any] { return "a\(values.count):" + (try values.map(canonical).joined()) }
        if let values = value as? [String: Any] {
            let keys = values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "o\(keys.count):" + (try keys.map { try canonical($0) + canonical(values[$0]!) }.joined())
        }
        throw SQLiteError.step("Unsupported catalog fingerprint value")
    }
}
