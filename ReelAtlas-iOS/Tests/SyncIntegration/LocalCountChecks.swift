import Foundation

@main
struct LocalCountChecks {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(url: url, readOnly: false)
        try db.execute("""
            CREATE TABLE movies(movie_qid TEXT PRIMARY KEY,id INTEGER UNIQUE);
            CREATE TABLE movie_periods(movie_qid TEXT,start_year INTEGER,end_year INTEGER);
            CREATE TABLE movie_locations(movie_qid TEXT,country_qid TEXT,raw_place_qid TEXT,
                historical_capital_qid TEXT,modern_place_qid TEXT,city_qid TEXT,admin1_qid TEXT);
            CREATE TABLE movie_target_matches(movie_qid TEXT,target_qid TEXT);
            INSERT INTO movies VALUES('Q1',1),('Q2',2),('Q3',3),('Q4',4),('Q5',5);
            INSERT INTO movie_periods VALUES('Q1',1950,1960),('Q2',1980,1985),('Q3',1955,1965),('Q4',2000,2005);
            INSERT INTO movie_locations VALUES
                ('Q1','QC','PA',NULL,NULL,'CITY',NULL),
                ('Q1','QC','PB',NULL,NULL,'CITY',NULL),
                ('Q2','QC','PB',NULL,NULL,'CITY',NULL),
                ('Q3','OTHER','PC',NULL,NULL,'ELSE',NULL),
                ('Q4','QC','PD',NULL,NULL,'CITY',NULL),
                ('Q5','QC','PE',NULL,NULL,'CITY',NULL);
            INSERT INTO movie_target_matches VALUES('Q1','REGION'),('Q1','REGION'),('Q3','REGION');
            """)
        let store = try LocalFilmCountStore(databaseURL: url)
        func expect(_ actual: Int, _ expected: Int, _ caseName: String) {
            precondition(actual == expected, "\(caseName): got \(actual), expected \(expected)")
        }
        expect(try store.exactCount(startYear: -10_000, endYear: 10_000, includeUnknown: true,
                                    scope: .country("QC")), 4, "unique local country movies")
        expect(try store.exactCount(startYear: 1950, endYear: 1960, includeUnknown: false,
                                    scope: .country("QC")), 1, "year range and country")
        expect(try store.exactCount(startYear: 1950, endYear: 1960, includeUnknown: true,
                                    scope: .place("REGION")), 2, "target match plus direct location, no duplicate")
        expect(try store.exactCount(startYear: 1950, endYear: 1960, includeUnknown: true,
                                    scope: .country("QC"), favoriteIDs: [1, 5]), 2, "favorite filter")
        expect(try store.exactCount(startYear: -10_000, endYear: 10_000, includeUnknown: true,
                                    scope: nil, favoriteIDs: []), 0, "empty favorites")
        print("Local count integration: 5 cases passed")
    }
}
