import XCTest
@testable import ReelAtlasCore

final class ContributionDuplicateTests: XCTestCase {
    func testIdentifierMatchBlocksEvenWhenTitlesDiffer() {
        XCTAssertTrue(ContributionDuplicatePolicy.isExisting(title:"New title",tmdbID:"100",imdbID:"",candidateTitle:"Old title",candidateTMDBID:100,candidateIMDbID:nil))
        XCTAssertTrue(ContributionDuplicatePolicy.isExisting(title:"New title",tmdbID:"",imdbID:" TT1234567 ",candidateTitle:"Old title",candidateTMDBID:nil,candidateIMDbID:"tt1234567"))
    }
    func testTitleOnlyChecksTrimmedCaseInsensitiveExactTitle() {
        XCTAssertTrue(ContributionDuplicatePolicy.isExisting(title:"  The Matrix ",tmdbID:"",imdbID:"",candidateTitle:"THE MATRIX",candidateTMDBID:100,candidateIMDbID:nil))
        XCTAssertFalse(ContributionDuplicatePolicy.isExisting(title:"Matrix",tmdbID:"",imdbID:"",candidateTitle:"The Matrix",candidateTMDBID:100,candidateIMDbID:nil))
    }
    func testDistinctIdentifierAllowsRemakeWithSameTitle() {
        XCTAssertFalse(ContributionDuplicatePolicy.isExisting(title:"The Thing",tmdbID:"200",imdbID:"",candidateTitle:"The Thing",candidateTMDBID:100,candidateIMDbID:nil))
    }
    func testTimeRangeRequiresBothEndsAndAscendingYears() {
        XCTAssertNil(ContributionTimeRange(start: "1900", end: "").entry)
        XCTAssertNil(ContributionTimeRange(start: "1950", end: "1900").entry)
        XCTAssertNil(ContributionTimeRange(start: "invalid", end: "2000").entry)
        XCTAssertEqual(ContributionTimeRange(start: "1900", end: "1950").entry, "1900–1950")
        XCTAssertEqual(ContributionTimeRange(start: "1900", end: "1900").entry, "1900")
        XCTAssertEqual(ContributionTimeRange(start: "-200", end: "-100").entry, "-200–-100")
    }

}
