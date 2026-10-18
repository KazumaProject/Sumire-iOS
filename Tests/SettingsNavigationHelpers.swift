import XCTest

extension XCTestCase {
    /// Follow the same visible dashboard entry as a person opening the input preview.
    func launchInputPreview(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.launch()
        let entry = app.buttons["settings-preview"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), file: file, line: line)
        entry.tap()
        XCTAssertTrue(app.textViews["入力テスト"].waitForExistence(timeout: 5), file: file, line: line)
    }

    func settingsButton(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let button = app.buttons[title]
        if !button.exists || !button.isHittable {
            let menu = app.buttons["preview-settings"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3), file: file, line: line)
            menu.tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 3), file: file, line: line)
        return button
    }
}
