import XCTest

final class PredictionSettingsSearchUITests: XCTestCase {
    func testPredictionQueriesOpenBothControlsWithoutChangingSettings() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        defer { app.terminate() }
        for query in ["先読み", "予測", "積極性"] {
            app.launch()
            let root = app.buttons["settings-preview"]
            XCTAssertTrue(root.waitForExistence(timeout: 45), "App initialization must finish before querying")
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(query)
            XCTAssertEqual(search.value as? String, query, "Search input fixture must contain the actual query")
            let destination = app.buttons["settings-destination-conversion"]
            let found = destination.waitForExistence(timeout: 5)
            XCTAssertTrue(found, "Prediction query must find conversion settings: " + query)
            if found {
                destination.tap()
                let lookahead = app.buttons["prediction-lookahead"].firstMatch
                XCTAssertTrue(lookahead.waitForExistence(timeout: 10)); reveal(lookahead, in: app)
                let aggression = app.segmentedControls["prediction-aggressiveness"].firstMatch
                XCTAssertTrue(aggression.waitForExistence(timeout: 10)); reveal(aggression, in: app)
                // Navigation and visibility only: neither picker is activated.
                XCTAssertTrue(lookahead.exists); XCTAssertTrue(aggression.isHittable)
            }
            app.terminate()
        }
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }
}
