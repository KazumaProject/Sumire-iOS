import XCTest

final class CustomLayoutDragSwapTests: XCTestCase {
    func testDraggingPreviewKeySwapsPersistedPlacements() {
        let app = XCUIApplication()
        app.launch()
        let inputCategory = app.buttons["settings-category-input"]
        XCTAssertTrue(inputCategory.waitForExistence(timeout: 5))
        inputCategory.tap()
        let customKeyboardSettings = app.buttons["settings-destination-customKeyboard"]
        XCTAssertTrue(customKeyboardSettings.waitForExistence(timeout: 5))
        customKeyboardSettings.tap()
        let name = "SwapEditor-" + String(UUID().uuidString.prefix(8))

        let createLayout = app.buttons["新しい配列を作成"]
        XCTAssertTrue(createLayout.waitForExistence(timeout: 5))
        createLayout.tap()
        let nameField = app.textFields["配列名"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (nameField.value as? String ?? "").count) + name)
        let addKey = app.buttons["キーを追加"]
        XCTAssertTrue(addKey.waitForExistence(timeout: 5))
        addKey.tap()
        let applyKey = app.buttons["適用"]
        XCTAssertTrue(applyKey.waitForExistence(timeout: 5))
        applyKey.tap()

        let prefix = "customLayoutPreviewKey-"
        let firstKey = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix, "あ")).firstMatch
        XCTAssertTrue(firstKey.waitForExistence(timeout: 5))
        let firstKeyID = firstKey.identifier

        app.buttons["キーを追加"].tap()
        let column = app.steppers["customKeyColumnPosition"]
        XCTAssertTrue(column.waitForExistence(timeout: 3))
        for _ in 0..<2 {
            let increment = column.buttons.element(boundBy: 1)
            XCTAssertTrue(increment.exists)
            increment.tap()
        }
        XCTAssertTrue(column.label.contains("2"), "Second key must be moved to a non-overlapping half-column")
        app.buttons["適用"].tap()

        let previewKeys = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let secondKey = previewKeys.element(boundBy: 1)
        XCTAssertTrue(secondKey.waitForExistence(timeout: 5))
        let secondKeyID = secondKey.identifier
        let firstBefore = app.buttons[firstKeyID]
        let secondBefore = app.buttons[secondKeyID]
        XCTAssertLessThan(firstBefore.frame.minX, secondBefore.frame.minX)

        let source = firstBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = secondBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.7, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertGreaterThan(app.buttons[firstKeyID].frame.minX, app.buttons[secondKeyID].frame.minX)

        app.buttons["保存"].tap()
        app.buttons[name].tap()
        app.buttons["編集"].tap()
        let persistedFirst = app.buttons[firstKeyID]
        let persistedSecond = app.buttons[secondKeyID]
        XCTAssertTrue(persistedFirst.waitForExistence(timeout: 5))
        XCTAssertTrue(persistedSecond.exists)
        XCTAssertGreaterThan(persistedFirst.frame.minX, persistedSecond.frame.minX)

        app.navigationBars["配列を編集"].buttons["キャンセル"].tap()
        app.buttons["この配列を削除"].tap()
        app.buttons["削除する"].tap()
        app.buttons["完了"].tap()
        app.terminate()
    }
}
