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
        let first = app.collectionViews["symbol-items"].descendants(matching: .any)["symbol-item-0"].firstMatch
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
        let content = app.collectionViews["symbol-items"].descendants(matching: .any).matching(NSPredicate(format: "label == %@", "すみれ clipboard 🪻")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 8)); content.tap()
        XCTAssertEqual(editor.value as? String, "すみれ clipboard 🪻")
        let savedID = content.identifier
        content.press(forDuration: 0.8)
        let pin = app.buttons["ピン留め"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3)); pin.tap()
        app.terminate(); app.launch()
        editor.tap(); app.buttons["symbol-open"].tap()
        let restored = app.descendants(matching: .any)[savedID].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        restored.press(forDuration: 0.8)
        let unpin = app.buttons["ピン留めを解除"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 3)); unpin.tap()
        restored.press(forDuration: 0.8)
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "削除", "symbol-delete")).firstMatch.tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: restored)
        waitForExpectations(timeout: 5)
        app.buttons["symbol-close"].tap()
    }

    func testClipboardImageHistoryOffDisappearsAfterRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-test-image", "-symbol.initialMode", "clipboard", "-clipboard.historyEnabled", "NO", "-clipboardAutomaticPreview", "NO"]
        app.launch()
        app.textViews["入力テスト"].tap()
        app.buttons["symbol-open"].tap()
        let load = app.buttons["symbol-clipboard-load"]
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow Paste", "ペーストを許可")).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        let current = app.descendants(matching: .any)["symbol-clipboard-current"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        current.tap()
        XCTAssertTrue(app.staticTexts["画像をコピーしました。入力先の貼り付けメニューから挿入してください"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews["入力テスト"].value as? String, "")
        app.terminate(); app.launch()
        app.textViews["入力テスト"].tap(); app.buttons["symbol-open"].tap()
        XCTAssertTrue(app.collectionViews["symbol-items"].waitForExistence(timeout: 5))
        XCTAssertFalse(current.exists)
    }


    func testSavedClipboardImageRestoresAfterRestartAndDeletes() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-test-image", "-symbol.initialMode", "clipboard", "-clipboard.historyEnabled", "YES", "-clipboardAutomaticPreview", "NO"]
        app.launch()
        app.textViews["入力テスト"].tap(); app.buttons["symbol-open"].tap()
        let load = app.buttons["symbol-clipboard-load"]
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow Paste", "ペーストを許可")).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        let image = app.collectionViews["symbol-items"].descendants(matching: .any).matching(NSPredicate(format: "label == %@", "画像")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        let savedID = image.identifier
        app.terminate(); app.launch()
        app.textViews["入力テスト"].tap(); app.buttons["symbol-open"].tap()
        let restored = app.descendants(matching: .any)[savedID].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5)); restored.tap()
        XCTAssertTrue(app.staticTexts["画像をコピーしました。入力先の貼り付けメニューから挿入してください"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews["入力テスト"].value as? String, "")
        // Refresh the tab to dismiss the explanatory notice before opening the row menu.
        app.buttons["symbol-mode-emoji"].tap(); app.buttons["symbol-mode-clipboard"].tap()
        restored.press(forDuration: 0.8); app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "削除", "symbol-delete")).firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: restored)
        waitForExpectations(timeout: 5)
    }


    func testConfiguredSpecialKeyOpensSymbolsWithoutLosingReading() throws {
        let app = XCUIApplication()
        let payload: [String: Any] = ["version": 1, "overrides": [
            ["arrangement": "toggle", "inputMode": 0, "key": "paste_key", "gesture": "up", "action": "openSymbols"]
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let argument = "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
        app.launchArguments = ["-sumire.keyArrangement", "toggle", "-liveConversion", "NO", "-sumire.specialKeyActions", argument]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap(); chooseGojuon(app)
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["Sumire"].tap()
        let paste = app.buttons["sumire-paste_key"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        paste.press(forDuration: 0.05, thenDragTo: paste.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertTrue(app.collectionViews["symbol-items"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["symbol-close"].tap()
        XCTAssertTrue(app.buttons["sumire-paste_key"].exists)
        XCTAssertEqual(editor.value as? String, "あい")
    }

}
