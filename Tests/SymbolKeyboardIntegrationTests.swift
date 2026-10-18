import XCTest

final class SymbolKeyboardIntegrationTests: XCTestCase {
    private func chooseGojuon(_ app: XCUIApplication) {
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["50音"].waitForExistence(timeout: 3))
        app.buttons["50音"].tap()
    }

    func testTabsAndClosePreserveCompositionAndUnderlyingKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-symbol.initialMode", "emoji"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap(); chooseGojuon(app)
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        app.buttons["gojuon-symbols"].tap()
        XCTAssertTrue(app.collectionViews["symbol-items"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "あい")
        for mode in ["emoticon", "symbol", "clipboard", "emoji"] {
            app.buttons["symbol-mode-" + mode].tap()
            XCTAssertTrue(app.buttons["symbol-mode-" + mode].isSelected)
        }
        app.buttons["symbol-close"].tap()
        XCTAssertTrue(app.buttons["gojuon-left"].exists)
        app.buttons["う"].tap()
        XCTAssertEqual(editor.value as? String, "あいう")
    }

    func testSkinTonePopupInsertsChosenVariantAndUpdatesDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["-symbol.initialMode", "emoji"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["symbol-open"].tap()
        app.buttons["symbol-category-PEOPLE_BODY"].tap()
        let first = app.collectionViews["symbol-items"].cells["symbol-item-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.8)
        let dark = app.buttons["symbol-skin-tone-1F3FF"]
        XCTAssertTrue(dark.waitForExistence(timeout: 3)); dark.tap()
        XCTAssertTrue((editor.value as? String)?.contains("🏿") == true)
        app.buttons["symbol-close"].tap()
        app.buttons["symbol-open"].tap()
        app.buttons["symbol-category-PEOPLE_BODY"].tap()
        XCTAssertTrue(first.label.contains("🏿"))
        app.buttons["symbol-close"].tap()
    }

    func testExplicitClipboardCaptureCreatesHistoryAndPastesText() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-test-text", "-symbol.initialMode", "clipboard", "-clipboard.historyEnabled", "YES", "-clipboardAutomaticPreview", "NO"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["symbol-open"].tap()
        let load = app.buttons["symbol-clipboard-load"]
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow Paste", "ペーストを許可")).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        let content = app.collectionViews["symbol-items"].cells.matching(NSPredicate(format: "label == %@", "すみれ clipboard 🪻")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 8)); content.tap()
        XCTAssertEqual(editor.value as? String, "すみれ clipboard 🪻")
        app.buttons["symbol-close"].tap()
    }
}
