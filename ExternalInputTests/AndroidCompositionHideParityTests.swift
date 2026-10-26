import XCTest

/// Verifies the Android InputMethodService hide lifecycle through the real iOS
/// keyboard extension in an external editor. The pinned Android service calls
/// `super.onFinishInputView`, whose framework implementation finishes composing
/// text; `onUpdateSelection` then clears the service's local pre-edit state.
/// A later key starts a new marked range at the caret.
final class AndroidCompositionHideParityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testHideFinalizesReadingAndNextKeyAppendsInExternalTextField() throws {
        let field = app.textFields["external-input-field"]
        field.tap()
        try requireSumireKeyboard()

        let firstKey = try japaneseKey(identifier: "gojuon-0-10", label: "あ")
        firstKey.tap()
        waitForValue(field, equals: "あ")
        waitForLabel(app.staticTexts["compositionReading"], equals: "あ")
        let fieldState = app.staticTexts["external-input-field-state"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "marked=true;"), evaluatedWith: fieldState)
        waitForExpectations(timeout: 5)
        let traceBeforeSwitch = app.staticTexts["sumire-debug-composition-trace"].label
        XCTAssertTrue(traceBeforeSwitch.contains("event=mark.wrote;"),
                      "The current extension trace should confirm a marked-text write: \(traceBeforeSwitch)")

        let keyboardSwitcher = app.buttons["Next keyboard"]
        XCTAssertTrue(keyboardSwitcher.waitForExistence(timeout: 3),
                      "The active third-party keyboard should expose the system input-mode switch")
        keyboardSwitcher.tap()
        let compositionReading = app.staticTexts["compositionReading"]
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: compositionReading
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed,
                       "Switching input methods should hide the Sumire keyboard extension")
        XCTAssertEqual(field.value as? String, "あ",
                       "Hiding the input view must keep the host text")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "marked=false;"), evaluatedWith: fieldState)
        waitForExpectations(timeout: 5)

        try requireSumireKeyboard()
        XCTAssertEqual(field.value as? String, "あ",
                       "Returning to Sumire must not lose the finalized host text")
        waitForLabel(app.staticTexts["compositionReading"], equals: "Sumire · C++変換")

        let nextKey = try japaneseKey(identifier: "gojuon-0-9", label: "か")
        nextKey.tap()
        waitForLabel(app.staticTexts["compositionReading"], equals: "か",
                     message: "The next key must begin a new composing range")
        waitForValue(field, equals: "あか")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "content=other;marked=true;markedUTF16=1;"),
                    evaluatedWith: fieldState)
        waitForExpectations(timeout: 5)

        guard let enter = key(["sumire-enter_key", "tenkey-enter", "gojuon-enter"]) else {
            XCTFail("The selected Japanese layout has no accessible enter key")
            return
        }
        enter.tap()
        waitForValue(field, equals: "あか")
    }

    private func requireSumireKeyboard() throws {
        let marker = app.staticTexts["compositionReading"]
        // A prior run may have left the Simulator on iOS's stock keyboard.
        // Cycle only the Simulator's enabled input methods until this host
        // exposes the real Sumire extension; no physical settings are touched.
        for _ in 0..<4 {
            if marker.waitForExistence(timeout: 1) { return }
            let keyboardHelp = app.buttons["Continue"]
            if keyboardHelp.exists && keyboardHelp.isHittable {
                keyboardHelp.tap()
                continue
            }
            let nextSystemKeyboard = app.buttons["Next keyboard"]
            guard nextSystemKeyboard.exists && nextSystemKeyboard.isHittable else { break }
            nextSystemKeyboard.tap()
        }
        guard marker.waitForExistence(timeout: 1) else {
            if ProcessInfo.processInfo.environment["SUMIRE_REQUIRE_EXTENSION"] == "1" {
                XCTFail("Expected the real Sumire keyboard extension, but its accessibility marker is missing")
                throw NSError(domain: "AndroidCompositionHideParity", code: 1)
            }
            throw XCTSkip("Enable and select the Sumire keyboard in this Simulator before running the external-host acceptance test")
        }
    }

    private func japaneseKey(identifier: String, label: String) throws -> XCUIElement {
        let kanaKey = app.buttons[identifier]
        if kanaKey.exists && kanaKey.isHittable {
            guard kanaKey.label == label else { throw XCTSkip("The 50音 layout is not in Japanese mode") }
            return kanaKey
        }
        // The acceptance Simulator may remember a custom layout. Its globe key
        // has a public UIMenu for Sumire's internal layouts; tap would switch to
        // the next system IME, so long-press and choose 50音 explicitly.
        let switcher = app.buttons["keyboard-switch"]
        guard switcher.exists && switcher.isHittable else {
            throw XCTSkip("No 50音 key or internal layout menu is available")
        }
        switcher.press(forDuration: 1.0)
        let menuButton = app.buttons["50音"]
        let menuItem = app.menuItems["50音"]
        let menuChoice: XCUIElement
        if menuButton.waitForExistence(timeout: 3) { menuChoice = menuButton }
        else if menuItem.waitForExistence(timeout: 2) { menuChoice = menuItem }
        else {
            throw XCTSkip("The keyboard switch menu did not expose its 50音 choice")
        }
        menuChoice.tap()
        guard kanaKey.waitForExistence(timeout: 5), kanaKey.isHittable else {
            throw XCTSkip("Selecting 50音 did not show its Japanese keys")
        }
        guard kanaKey.label == label else { throw XCTSkip("The 50音 layout is not in Japanese mode") }
        return kanaKey
    }

    private func key(_ identifiers: [String]) -> XCUIElement? {
        identifiers.map { app.buttons[$0] }.first { $0.exists && $0.isHittable }
    }

    private func waitForValue(_ element: XCUIElement, equals value: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected external host value \(value)", file: file, line: line)
        XCTAssertEqual(element.value as? String, value, file: file, line: line)
    }

    private func waitForLabel(_ element: XCUIElement, equals value: String,
                              message: String = "Expected keyboard status",
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "\(message): \(value)", file: file, line: line)
        XCTAssertEqual(element.label, value, file: file, line: line)
    }
}
