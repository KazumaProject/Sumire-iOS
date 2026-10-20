import XCTest

final class StableCandidateHeightTests: XCTestCase {
    func testConfiguredRowsKeepKeysAndEditorStableAcrossComposition() {
        for rows in 1...3 {
            let app = XCUIApplication()
            app.launchArguments = ["-candidateRowCount", "\(rows)", "-liveConversion", "NO"]
            launchInputPreview(app)
            let editor = app.textViews["入力テスト"]
            editor.tap()
            app.buttons["keyboard-switch"].press(forDuration: 0.8)
            let layout = app.collectionViews.buttons["50音"]
            XCTAssertTrue(layout.waitForExistence(timeout: 3)); layout.tap()
            let key = app.buttons["あ"]
            XCTAssertTrue(key.waitForExistence(timeout: 3))
            let idleKey = key.frame
            let idleEditor = editor.frame
            let header = app.staticTexts["compositionReading"]
            let idleHeader = header.frame
            key.tap()
            XCTAssertEqual(editor.value as? String, "あ")
            XCTAssertTrue(app.staticTexts["compositionReading"].waitForExistence(timeout: 3))
            XCTAssertEqual(header.frame.minY, idleHeader.minY, accuracy: 1, "rows=\(rows)")
            XCTAssertEqual(key.frame.minY, idleKey.minY, accuracy: 1, "rows=\(rows)")
            XCTAssertEqual(key.frame.height, idleKey.height, accuracy: 1, "rows=\(rows)")
            XCTAssertEqual(editor.frame.maxY, idleEditor.maxY, accuracy: 1, "rows=\(rows)")
            app.buttons["改行"].tap()
            XCTAssertEqual(app.staticTexts["compositionReading"].label, "Sumire · C++変換")
            XCTAssertEqual(header.frame.minY, idleHeader.minY, accuracy: 1, "rows=\(rows)")
            XCTAssertEqual(key.frame.minY, idleKey.minY, accuracy: 1, "rows=\(rows)")
            XCTAssertEqual(editor.frame.maxY, idleEditor.maxY, accuracy: 1, "rows=\(rows)")
            app.terminate()
        }
    }
}
