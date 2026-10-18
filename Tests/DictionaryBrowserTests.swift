import XCTest

final class DictionaryBrowserTests: XCTestCase {
    private func open(_ app: XCUIApplication) {
        app.launch()
        let category = app.buttons["settings-category-dictionaries"]
        for _ in 0..<4 where !category.isHittable { app.swipeUp() }
        category.tap()
        app.buttons["settings-destination-dictionaryBrowser"].tap()
        XCTAssertTrue(app.textFields["dictionary-browser-query"].waitForExistence(timeout: 5))
    }
    func testSystemPagingAndPrefixSearch() {
        let app = XCUIApplication(); open(app)
        // SwiftUI may expose combined rows as cells, so inspect all descendants.
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dictionary-browser-row-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let original = first.identifier
        app.buttons["dictionary-browser-next"].tap()
        let changed = NSPredicate { _, _ in first.exists && first.identifier != original }
        expectation(for: changed, evaluatedWith: nil); waitForExpectations(timeout: 10)
        app.buttons["読みの先頭"].tap()
        let query = app.textFields["dictionary-browser-query"]; query.tap(); query.typeText("あい")
        XCTAssertTrue(app.staticTexts["あい"].waitForExistence(timeout: 10))
        XCTAssertTrue(first.exists)
        app.buttons["完了"].tap()
        XCTAssertTrue(app.buttons["settings-destination-dictionaryBrowser"].waitForExistence(timeout: 3))
    }
    func testNormalizedSearchFindsMixedWidthAndCaseSurface() {
        let app = XCUIApplication(); open(app)
        app.buttons["dictionary-browser-choice"].tap()
        app.buttons["英単語"].tap()
        let query = app.textFields["dictionary-browser-query"]
        query.tap(); query.typeText("ＩＰＨＯＮＥ")
        XCTAssertTrue(app.staticTexts["iPhone"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["検索を閉じる"].tap()
        XCTAssertTrue(app.buttons["読み・表記"].isSelected)
    }

    func testEnglishAndSurfaceSearch() {
        let app = XCUIApplication(); open(app)
        app.buttons["dictionary-browser-choice"].tap()
        app.buttons["英単語"].tap()
        let query = app.textFields["dictionary-browser-query"]
        query.tap(); query.typeText("hello")
        XCTAssertTrue(app.staticTexts["hello"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["検索を閉じる"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Dictionary browser English prefix"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["表記に含む"].tap()
        XCTAssertTrue(app.staticTexts["hello"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["完了"].tap()
    }
}
