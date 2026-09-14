import XCTest
@testable import ReelAtlasCore

final class SearchAndTipTests: XCTestCase {
    @MainActor
    func testRepeatedQueryCannotPublishEarlierGeneration() async throws {
        let search = LatestMovieSearch(debounce: .zero)
        let probe = SearchProbe()
        search.update("ab") { _ in
            await probe.markStarted()
            do { try await Task.sleep(for: .milliseconds(70)) }
            catch { await probe.markCancelled() }
            return MovieSearchPage(page: 1, results: [], totalPages: 1, totalResults: 99)
        }
        while !(await probe.started) { await Task.yield() }
        search.update("abc") { _ in MovieSearchPage(page: 1, results: [], totalPages: 1, totalResults: 2) }
        search.update("ab") { _ in MovieSearchPage(page: 1, results: [], totalPages: 1, totalResults: 3) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(search.page?.totalResults, 3)
        let wasCancelled = await probe.cancelled
        XCTAssertTrue(wasCancelled)
        search.cancel()
        XCTAssertNil(search.page)
        XCTAssertFalse(search.isPending)
    }

    func testTipQuantitiesAndVerificationStates() {
        XCTAssertFalse(TipRules.isValidQuantity(0))
        XCTAssertFalse(TipRules.isValidQuantity(11))
        XCTAssertTrue(TipRules.isValidQuantity(1))
        XCTAssertTrue(TipRules.isValidQuantity(10))
        XCTAssertEqual(TipState.result(verified: true), .verified)
        XCTAssertEqual(TipState.result(verified: false), .unverified)
        XCTAssertTrue(TipState.purchasing.isBusy)
        XCTAssertFalse(TipState.pending.isBusy)
    }

    func testInvalidPrimaryPosterFallsBack() {
        XCTAssertEqual(MovieMetadataImageURLs.poster(primary: "", path: "/poster.jpg")?.lastPathComponent, "poster.jpg")
        XCTAssertEqual(MovieMetadataImageURLs.poster(primary: "https://example.com/550.jpg", path: "/poster.jpg")?.host, "example.com")
        XCTAssertNil(MovieMetadataImageURLs.profile(path: nil))
    }
}

private actor SearchProbe {
    var started = false
    var cancelled = false
    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
}
