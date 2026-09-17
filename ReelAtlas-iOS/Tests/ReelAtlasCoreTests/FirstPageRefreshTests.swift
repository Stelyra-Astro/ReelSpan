import XCTest
@testable import ReelAtlasCore

final class FirstPageRefreshTests: XCTestCase {
    func testOnlineRefreshRestoresPaginationAfterSavedSubset() {
        XCTAssertTrue(MoviePaginationPolicy.hasMoreAfterFirstPageRefresh(
            loadedCount: 20, pageSize: 20, currentHasMore: false, refreshedHasMore: true))
    }

    func testRefreshingFirstPagePreservesLoadedTailPagination() {
        XCTAssertFalse(MoviePaginationPolicy.hasMoreAfterFirstPageRefresh(
            loadedCount: 40, pageSize: 20, currentHasMore: false, refreshedHasMore: true))
        XCTAssertTrue(MoviePaginationPolicy.hasMoreAfterFirstPageRefresh(
            loadedCount: 40, pageSize: 20, currentHasMore: true, refreshedHasMore: false))
    }
}
