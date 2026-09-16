import XCTest

@MainActor final class ContributionDeviceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.xiaoguiwk.ReelSpan")
    override func setUp() { continueAfterFailure = false; app.launch() }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openHub() {
        let button = app.buttons["openContributions"]
        XCTAssertTrue(button.waitForExistence(timeout: 25)); button.tap()
        XCTAssertTrue(app.navigationBars["Contribute"].waitForExistence(timeout: 15))
    }
    func testMissingFilmSearchDisplaysFullMovieCardAndEditAction() {
        openHub()
        app.buttons["missing-place_no_time"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("Bullet")
        let edits = app.buttons.matching(identifier: "edit-Q1004410")
        XCTAssertTrue(edits.firstMatch.waitForExistence(timeout: 25))
        search.typeText("\n")
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            edits.allElementsBoundByIndex.contains(where: { $0.isHittable })
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 30), .completed)
        screenshot("12mini-contribution-search-cards")
        // The home screen remains behind the presented contribution sheet.
        // Choose its frontmost copy rather than the hidden home-card button.
        let edit = edits.allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(edit, "The contribution edit button must be reachable")
        edit?.tap()
        XCTAssertTrue(app.navigationBars["Suggest a correction"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["start-year"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["end-year"].firstMatch.exists)
        screenshot("12mini-correction-start-end-years")
    }
    func testNewFilmChecksExistingIdentifierAndShowsCorrectionCard() {
        openHub()
        app.buttons["addMissingFilm"].tap()
        let title = app.textFields["new-film-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap(); title.typeText("Bullet in the Head")
        let tmdb = app.textFields["new-film-tmdb"]
        tmdb.tap(); tmdb.typeText("11909")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["This film already exists. Use its edit button to correct story details."].waitForExistence(timeout: 25))
        screenshot("12mini-existing-film-duplicate-check")
        // Never send a production proposal as part of UI validation.
    }
}
