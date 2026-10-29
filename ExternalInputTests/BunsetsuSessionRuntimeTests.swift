import XCTest

/// Runs only with the real extension selected and bunsetsuSeparation enabled.
/// The acceptance host must expose current UITextInput state; it must not edit
/// or unmark text on behalf of the keyboard.
final class BunsetsuSessionRuntimeTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false; app.launch() }
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, _ message: String) {
        let condition = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed, message)
    }
    private func value(_ expected: String) {
        wait(NSPredicate(format: "value == %@", expected), on: app.textFields["external-input-field"], "Host text must equal fixed test text")
    }
    private func selectKeyboard() {
        for _ in 0..<12 {
            if app.staticTexts["compositionReading"].exists { break }
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "次のキーボード", "次の入力モード"])).firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 3)); next.tap()
        }
        XCTAssertTrue(app.staticTexts["compositionReading"].waitForExistence(timeout: 5), "Real Sumire extension required")
        if !app.buttons["gojuon-0-10"].exists {
            let switcher = app.buttons["keyboard-switch"]
            XCTAssertTrue(switcher.waitForExistence(timeout: 3)); switcher.press(forDuration: 1)
            let button = app.buttons["50音"], item = app.menuItems["50音"]
            if button.waitForExistence(timeout: 2) { button.tap() }
            else { XCTAssertTrue(item.waitForExistence(timeout: 2)); item.tap() }
        }
        XCTAssertEqual(app.buttons["gojuon-0-10"].label, "あ")
    }
    private func type(_ text: String) {
        for character in text {
            let label = character == "ょ" ? "よ" : String(character)
            let key = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gojuon-' AND label == %@", label)).firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 3)); key.tap()
            if character == "ょ" {
                let modifier = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gojuon-' AND label == %@", "゛小")).firstMatch
                XCTAssertTrue(modifier.exists); modifier.tap()
            }
        }
    }
    private func record(_ name: String) {
        let input = app.textFields["external-input-field"]
        let state = app.staticTexts["external-input-field-state"].label
        let data = XCTAttachment(string: "fixedHostText=\(input.value ?? "nil");\(state)")
        data.name = name; data.lifetime = .keepAlways; add(data)
    }
    func testFocusedPrefixCommitRetainsMarkedRemainderAndAllowsEditing() {
        app.textFields["external-input-field"].tap(); selectKeyboard()
        type("わたしはとうきょうにいきます")
        value("わたしはとうきょうにいきます")
        app.buttons["gojuon-space"].tap()
        wait(NSPredicate(format: "label BEGINSWITH %@", "文節 1/"), on: app.staticTexts["compositionReading"], "Bunsetsu session must start")
        app.buttons["gojuon-right"].tap()
        wait(NSPredicate(format: "label BEGINSWITH %@", "文節 2/"), on: app.staticTexts["compositionReading"], "Focus must move to second segment")
        let candidate = app.collectionViews["candidate-items"].cells.element(boundBy: 0)
        wait(NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), on: candidate, "Focused candidate must finish loading")
        XCTAssertEqual(candidate.label, "東京に")
        candidate.tap()
        value("私は東京にいきます")
        let state = app.staticTexts["external-input-field-state"]
        wait(NSPredicate(format: "label CONTAINS %@", "marked=true;markedUTF16=4;"), on: state, "Only the four-unit reading remainder stays marked")
        record("prefix-committed-and-four-unit-remainder")
        type("あ"); value("私は東京にいきますあ")
        app.buttons["gojuon-delete"].tap(); value("私は東京にいきます")
        app.buttons["gojuon-enter"].tap(); value("私は東京にいきます")
        wait(NSPredicate(format: "label CONTAINS %@", "marked=false;"), on: state, "Explicit final commit must clear marked text")
        record("remainder-edited-and-finally-committed")
    }
}
