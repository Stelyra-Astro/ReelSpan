import Foundation
import SQLite3

/// Exact counts of distinct films present in the permanent, on-device story catalog.
/// This is deliberately independent of page size, posters, TMDB metadata and the network.
enum LocalFilmCountScope: Sendable {
    case place(String)
    case country(String)
}

struct LocalFilmCountStore {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL, readOnly: true)
    }

    func exactCount(startYear: Int, endYear: Int, includeUnknown: Bool,
                    scope: LocalFilmCountScope?, favoriteIDs: Set<Int>? = nil) throws -> Int {
        if let favoriteIDs, favoriteIDs.isEmpty { return 0 }
        let locationClause: String
        var bindings: [SQLiteBindValue] = [.int(endYear), .int(startYear), .int(includeUnknown ? 1 : 0)]
        switch scope {
        case .place(let qid):
            locationClause = """
                AND (EXISTS (SELECT 1 FROM movie_target_matches mtm
                             WHERE mtm.movie_qid=m.movie_qid AND mtm.target_qid=?)
                     OR EXISTS (SELECT 1 FROM movie_locations ml
                                WHERE ml.movie_qid=m.movie_qid AND ? IN (
                                  ml.raw_place_qid, ml.historical_capital_qid,
                                  ml.modern_place_qid, ml.city_qid, ml.admin1_qid, ml.country_qid)))
                """
            bindings += [.text(qid), .text(qid)]
        case .country(let qid):
            locationClause = """
                AND EXISTS (SELECT 1 FROM movie_locations ml
                            WHERE ml.movie_qid=m.movie_qid AND ml.country_qid=?)
                """
            bindings.append(.text(qid))
        case nil:
            locationClause = ""
        }
        var favoritesClause = ""
        if let favoriteIDs {
            favoritesClause = " AND m.id IN (\(Array(repeating: "?", count: favoriteIDs.count).joined(separator: ",")))"
            bindings += favoriteIDs.sorted().map(SQLiteBindValue.int)
        }
        let sql = """
            SELECT COUNT(*) FROM movies m
            WHERE (EXISTS (SELECT 1 FROM movie_periods mp
                           WHERE mp.movie_qid=m.movie_qid AND mp.start_year<=? AND mp.end_year>=?)
                   OR (?=1 AND NOT EXISTS (SELECT 1 FROM movie_periods mp
                        WHERE mp.movie_qid=m.movie_qid AND mp.start_year IS NOT NULL AND mp.end_year IS NOT NULL)))
            \(locationClause)\(favoritesClause)
            """
        let statement = try database.prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard try database.step(statement) else { throw SQLiteError.step("Local film count not returned") }
        return database.int(statement, 0)
    }
}
