import XCTest

final class CustomLayoutDragSwapTests: XCTestCase {
    func testDraggingPreviewKeySwapsPersistedPlacements() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launch()
        let inputCategory = app.buttons["settings-category-input"]
        XCTAssertTrue(inputCategory.waitForExistence(timeout: 30))
        inputCategory.tap()
        let customKeyboardSettings = app.buttons["settings-destination-customKeyboard"]
        XCTAssertTrue(customKeyboardSettings.waitForExistence(timeout: 30))
        customKeyboardSettings.tap()
        let name = "SwapEditor-" + String(UUID().uuidString.prefix(8))

        let createLayout = app.buttons["新しい配列を作成"]
        XCTAssertTrue(createLayout.waitForExistence(timeout: 30))
        createLayout.tap()
        let nameField = app.textFields["配列名"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 30))
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (nameField.value as? String ?? "").count) + name)
        let addKey = app.buttons["キーを追加"]
        XCTAssertTrue(addKey.waitForExistence(timeout: 30))
        addKey.tap()
        let applyKey = app.buttons["適用"]
        XCTAssertTrue(applyKey.waitForExistence(timeout: 30))
        applyKey.tap()

        let prefix = "customLayoutPreviewKey-"
        let firstKey = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix, "あ")).firstMatch
        XCTAssertTrue(firstKey.waitForExistence(timeout: 30))
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
        let row = app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", "上から：")).firstMatch
        for _ in 0..<2 { row.buttons.element(boundBy: 1).tap() }
        for label in ["高さ：", "幅："] {
            app.steppers.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.buttons.element(boundBy: 0).tap()
        }
        app.buttons["適用"].tap()

        let previewKeys = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let secondKey = previewKeys.element(boundBy: 1)
        XCTAssertTrue(secondKey.waitForExistence(timeout: 30))
        let secondKeyID = secondKey.identifier
        let firstBefore = app.buttons[firstKeyID]
        let secondBefore = app.buttons[secondKeyID]
        let firstFrame = firstBefore.frame
        let secondFrame = secondBefore.frame
        XCTAssertLessThan(firstFrame.minX, secondFrame.minX)
        XCTAssertLessThan(firstFrame.minY, secondFrame.minY)
        XCTAssertGreaterThan(firstFrame.width, secondFrame.width)
        XCTAssertGreaterThan(firstFrame.height, secondFrame.height)
        // A simple tap must still open the existing editor, without swapping.
        firstBefore.tap()
        XCTAssertTrue(app.navigationBars["キーを編集"].waitForExistence(timeout: 10))
        app.navigationBars["キーを編集"].buttons["キャンセル"].tap()
        // Dropping into an empty grid cell must leave both placements intact.
        let outside = firstBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: firstFrame.height * 2.5))
        firstBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.7, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.6)
        assertFrame(firstBefore.frame, matches: firstFrame)
        assertFrame(secondBefore.frame, matches: secondFrame)

        let source = firstBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = secondBefore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.7, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.6)
        assertFrame(app.buttons[firstKeyID].frame, matches: secondFrame)
        assertFrame(app.buttons[secondKeyID].frame, matches: firstFrame)

        app.buttons["保存"].tap()
        let savedLayout = app.buttons[name]
        for _ in 0..<5 {
            if savedLayout.exists && savedLayout.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(savedLayout.waitForExistence(timeout: 10))
        savedLayout.tap()
        app.buttons["編集"].tap()
        let persistedFirst = app.buttons[firstKeyID]
        let persistedSecond = app.buttons[secondKeyID]
        XCTAssertTrue(persistedFirst.waitForExistence(timeout: 30))
        XCTAssertTrue(persistedSecond.exists)
        XCTAssertGreaterThan(persistedFirst.frame.minX, persistedSecond.frame.minX)
        XCTAssertGreaterThan(persistedFirst.frame.minY, persistedSecond.frame.minY)
        XCTAssertEqual(persistedFirst.frame.width, secondFrame.width, accuracy: 1)
        XCTAssertEqual(persistedFirst.frame.height, secondFrame.height, accuracy: 1)
        XCTAssertEqual(persistedSecond.frame.width, firstFrame.width, accuracy: 1)
        XCTAssertEqual(persistedSecond.frame.height, firstFrame.height, accuracy: 1)

        app.navigationBars["配列を編集"].buttons["キャンセル"].tap()
        app.buttons["この配列を削除"].tap()
        app.buttons["削除する"].tap()
        app.buttons["完了"].tap()
        app.terminate()
    }
    private func assertFrame(_ actual: CGRect, matches expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }
}
