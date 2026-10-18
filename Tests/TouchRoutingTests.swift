import XCTest

/// Real UIKit gesture regression; independent multi-touch routing is covered
/// separately by Core tests because XCUITest does not expose arbitrary two-key
/// simultaneous finger paths through its public API.
final class TouchRoutingTests: XCTestCase {
    func testNormalReleaseAndHeldDeleteStopAtReleaseAndMenuStillOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-liveConversion", "NO", "-learningEnabled", "NO"]
        app.launch()
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
