import XCTest

final class EnglishDictionaryLicenseTests: XCTestCase {
    func testEnglishDictionaryNoticesExposeUnresolvedScopeOffline() {
        let app = XCUIApplication()
        app.launch()

        let appCategory = app.buttons["settings-category-app"]
        for _ in 0..<5 where !appCategory.isHittable { app.swipeUp() }
        XCTAssertTrue(appCategory.waitForExistence(timeout: 5))
        appCategory.tap()
        let licenses = app.buttons["settings-destination-licenses"]
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()

        let status = app.staticTexts["english-dictionary-license-status"]
        for _ in 0..<5 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("未確認"))

        let currentNotice = app.buttons["english-word-dictionary-notice"]
        for _ in 0..<5 where !currentNotice.isHittable { app.swipeUp() }
        XCTAssertTrue(currentNotice.waitForExistence(timeout: 5))
        currentNotice.tap()
        let currentText = app.staticTexts["license-notice-text"]
        XCTAssertTrue(currentText.waitForExistence(timeout: 5))
        XCTAssertTrue(currentText.label.contains("Source and applicable data license: unconfirmed"))
        app.navigationBars.buttons.firstMatch.tap()

        let legacyNotice = app.buttons["english-legacy-wikitext-notice"]
        for _ in 0..<5 where !legacyNotice.isHittable { app.swipeUp() }
        XCTAssertTrue(legacyNotice.waitForExistence(timeout: 5))
        legacyNotice.tap()
        let legacyText = app.staticTexts["license-notice-text"]
        XCTAssertTrue(legacyText.waitForExistence(timeout: 5))
        XCTAssertTrue(legacyText.label.contains("現行の英単語資産への適用は未確認"))
        XCTAssertTrue(legacyText.label.contains("Salesforce WikiText"))
        XCTAssertTrue(legacyText.label.contains("CC BY-SA 4.0"))
        app.navigationBars.buttons.firstMatch.tap()

        let readingNotice = app.buttons["english-reading-dictionary-notice"]
        for _ in 0..<5 where !readingNotice.isHittable { app.swipeUp() }
        XCTAssertTrue(readingNotice.waitForExistence(timeout: 5))
    }
}
