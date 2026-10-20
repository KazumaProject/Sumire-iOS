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

    /// App-hosted iPad coverage; this does not exercise the OS floating keyboard.
    func testIPadRotationPreservesCompositionAndKeepsKeysInWindow() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        app.launchArguments = ["-candidateRowCount", "3", "-liveConversion", "NO"]
        launchInputPreview(app)
        guard app.windows.firstMatch.frame.width >= 600 else {
            throw XCTSkip("Requires an iPad Simulator in full-screen portrait")
        }
        let editor = app.textViews["入力テスト"]
        editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        let layout = app.collectionViews.buttons["50音"]
        XCTAssertTrue(layout.waitForExistence(timeout: 3)); layout.tap()
        let key = app.buttons["あ"]
        XCTAssertTrue(key.waitForExistence(timeout: 3)); key.tap()
        let header = app.staticTexts["compositionReading"]
        XCTAssertEqual(editor.value as? String, "あ")
        XCTAssertEqual(header.label, "あ")

        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let window = app.windows.firstMatch.frame
                return landscape ? window.width > window.height : window.height > window.width
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                           "Window must rotate before checking keyboard geometry")
            XCTAssertEqual(editor.value as? String, "あ", "Rotation must preserve editor text")
            XCTAssertEqual(header.label, "あ", "Rotation must preserve uncommitted composition")
            let window = app.windows.firstMatch.frame
            for button in [key, app.buttons["ん"], app.buttons["改行"], app.buttons["keyboard-switch"]] {
                XCTAssertTrue(button.exists)
                let frame = button.frame
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0, "Rotation must not collapse the key area")
                XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, header.frame.maxY - 1)
                XCTAssertLessThanOrEqual(frame.maxY, window.maxY + 1)
                XCTAssertTrue(button.isHittable, "Rotated keys must remain usable")
            }
        }
        // Editing after both rotations must still operate on the same composition.
        key.tap()
        XCTAssertEqual(editor.value as? String, "ああ")
        XCTAssertEqual(header.label, "ああ")
        app.buttons["改行"].tap()
        XCTAssertEqual(editor.value as? String, "ああ")
        XCTAssertEqual(header.label, "Sumire · C++変換")
    }

}
