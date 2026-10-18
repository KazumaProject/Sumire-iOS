import XCTest

/// Real UIKit gesture regression; independent multi-touch routing is covered
/// separately by Core tests because XCUITest does not expose arbitrary two-key
/// simultaneous finger paths through its public API.
final class TouchRoutingTests: XCTestCase {
    func testFeedbackSettingsSaveAndRestoreThroughVisibleSettings() {
        let app = XCUIApplication()
        app.launch()
        func open() {
            app.buttons["settings-category-input"].tap()
            let destination = app.buttons["settings-destination-touchFeedback"]
            for _ in 0..<4 where !destination.isHittable { app.swipeUp() }
            destination.tap()
        }
        open()
        let reset = app.buttons["標準に戻す"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        let multi = app.switches["feedback-independent-touch"].switches.firstMatch
        for _ in 0..<4 where !multi.isHittable { app.swipeDown() }
        XCTAssertEqual(multi.value as? String, "0"); multi.tap()
        let popup = app.switches["feedback-popup-visible"].switches.firstMatch
        for _ in 0..<4 where !popup.isHittable { app.swipeDown() }
        XCTAssertEqual(popup.value as? String, "1"); popup.tap()
        app.buttons["完了"].tap()
        app.terminate(); app.launch(); open()
        XCTAssertEqual(app.switches["feedback-popup-visible"].switches.firstMatch.value as? String, "0")
        let restored = app.switches["feedback-independent-touch"].switches.firstMatch
        for _ in 0..<4 where !restored.isHittable { app.swipeUp() }
        XCTAssertEqual(restored.value as? String, "1")
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
    }

    func testFlickPopupGestureCommitsOnlyTheSelectedDirectionOnRelease() {
        let app = XCUIApplication()
        app.launchArguments = ["-liveConversion", "NO", "-learningEnabled", "NO"]
        launchInputPreview(app)
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        app.collectionViews.buttons["テンキー"].tap()
        let key = app.buttons["tenkey-0-0"]
        XCTAssertTrue(key.waitForExistence(timeout: 3))
        let start = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        print("SUMIRE_POPUP_CAPTURE_BEGIN")
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -48, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 4)
        XCTAssertEqual(editor.value as? String, "い")
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "")
    }

    func testNormalReleaseAndHeldDeleteStopAtReleaseAndMenuStillOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-liveConversion", "NO", "-learningEnabled", "NO"]
        launchInputPreview(app)
        let editor = app.textViews["入力テスト"]
        editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["ABC"].waitForExistence(timeout: 3))
        app.buttons["ABC"].tap()
        let a = app.buttons["a"]
        XCTAssertTrue(a.waitForExistence(timeout: 3))
        for _ in 0..<20 { a.tap() }
        XCTAssertEqual(editor.value as? String, String(repeating: "a", count: 20))
        let delete = app.buttons["削除"]
        delete.tap()
        XCTAssertEqual(editor.value as? String, String(repeating: "a", count: 19))
        delete.press(forDuration: 0.65)
        let afterHold = editor.value as? String ?? ""
        XCTAssertLessThan(afterHold.count, 18)
        XCTAssertGreaterThan(afterHold.count, 0)
        let settled = expectation(description: "repeat timer stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(editor.value as? String, afterHold)
        a.tap()
        XCTAssertEqual(editor.value as? String, afterHold + "a")
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["50音"].waitForExistence(timeout: 3))
    }
}
