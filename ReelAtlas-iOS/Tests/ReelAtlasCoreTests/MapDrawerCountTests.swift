import XCTest
@testable import ReelAtlasCore

final class MapDrawerCountTests: XCTestCase {
    func testDismissedDrawerFullyHidesAndPillReopensIt() {
        var drawer = ResultsDrawerState()
        drawer.showResults()
        XCTAssertEqual(drawer.level, .medium)
        drawer.userDismissed()
        XCTAssertEqual(drawer.level, .hidden)
        drawer.searchFinished()
        XCTAssertEqual(drawer.level, .hidden)
        drawer.showResults()
        XCTAssertEqual(drawer.level, .medium)
        drawer.mapNavigationStarted()
        XCTAssertEqual(drawer.level, .hidden)
    }

    func testPullingDownFromExpandedDrawerFullyDismissesIt() {
        var drawer = ResultsDrawerState()
        drawer.showResults()
        drawer.userMoved(to: .full)
        drawer.userMoved(to: .medium) // iOS reports the smaller detent during a downward drag.
        XCTAssertEqual(drawer.level, .hidden)
        drawer.showResults()
        XCTAssertEqual(drawer.level, .medium)
    }

    func testMapResultLabelNeverConflatesLoadedPageSizeWithTotal() {
        XCTAssertEqual(MapResultsLabel.text(place: "Afghanistan", exactCount: 127), "Afghanistan · 127 films")
        XCTAssertEqual(MapResultsLabel.text(place: "Afghanistan", exactCount: nil), "Afghanistan · Films")
        XCTAssertEqual(MapResultsLabel.text(place: "Afghanistan", exactCount: 0), "Afghanistan · 0 films")
        XCTAssertEqual(MapResultsLabel.text(place: "Afghanistan", exactCount: 12, isPartial: true),
                       "Afghanistan · 12 saved films")
    }
}
