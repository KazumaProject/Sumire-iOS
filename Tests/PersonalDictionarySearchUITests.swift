import XCTest

final class PersonalDictionarySearchUITests: XCTestCase {
    func testSearchMatchesReadingAndSurfaceAndKeepsRowActionsBoundToSourceEntry() {
        let app = XCUIApplication()
        launchInputPreview(app)
        settingsButton("ユーザー辞書・定型文", in: app).tap()

        let suffix = String(UUID().uuidString.lowercased().prefix(8))
        let query = "search" + suffix
        let readingMatchSurface = "reading-match-" + suffix
        let readingMatchReading = query + "-reading"
        let surfaceMatchSurface = query + "-surface"
        let surfaceMatchReading = "reading-only-" + suffix

        addWord(in: app, reading: readingMatchReading, surface: readingMatchSurface)
        addWord(in: app, reading: surfaceMatchReading, surface: surfaceMatchSurface)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(query)
        searchField.typeText("\n")

        let readingMatch = entryButton(readingMatchSurface, in: app)
        let surfaceMatch = entryButton(surfaceMatchSurface, in: app)
        XCTAssertTrue(readingMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(surfaceMatch.waitForExistence(timeout: 5))

        surfaceMatch.tap()
        XCTAssertEqual(app.textFields["personalReading"].value as? String, surfaceMatchReading)
        XCTAssertEqual(app.textFields["personalText"].value as? String, surfaceMatchSurface)
        app.buttons["キャンセル"].tap()

        entryButton(surfaceMatchSurface, in: app).tap()
        app.buttons["この登録を削除"].tap()
        waitForAbsence(of: entryButton(surfaceMatchSurface, in: app))
        XCTAssertTrue(entryButton(readingMatchSurface, in: app).exists)

        entryButton(readingMatchSurface, in: app).tap()
        app.buttons["この登録を削除"].tap()
        XCTAssertTrue(app.staticTexts["一致する登録がありません"].waitForExistence(timeout: 5))
    }

    private func addWord(in app: XCUIApplication, reading: String, surface: String) {
        app.buttons["登録を追加"].tap()
        let readingField = app.textFields["personalReading"]
        readingField.tap()
        readingField.typeText(reading)
        let surfaceField = app.textFields["personalText"]
        surfaceField.tap()
        surfaceField.typeText(surface)
        let scoreField = app.textFields["personalScore"]
        scoreField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        scoreField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "-20000")
        app.buttons["保存"].tap()
        XCTAssertTrue(entryButton(surface, in: app).waitForExistence(timeout: 5))
    }

    private func entryButton(_ surface: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: surface).firstMatch
    }

    private func waitForAbsence(of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed, file: file, line: line)
    }
}
