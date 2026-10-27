import XCTest

/// Real-extension regressions. Strict checks for unresolved behavior remain enabled.
final class MarkedKeyboardComparisonTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    func testStandardJapaneseFocusAndOldFieldReediting() throws { try compare(sumire: false) }
    func testOriginalSumireFocusAndOldFieldReediting() throws { try compare(sumire: true) }

    func testStableMarkedCaretDeleteAndExplicitCommit() throws {
        let field = app.textFields["external-input-field"]
        field.tap(); try selectIME(sumire: true)
        try character("あ", sumire: true); try character("い", sumire: true)
        value(field, "あい")
        XCTAssertTrue(state("external-input-field-state").contains("marked=true;"))
        app.buttons["gojuon-left"].tap()
        try character("う", sumire: true)
        value(field, "あうい")
        delete(sumire: true); value(field, "あい")
        app.buttons["gojuon-enter"].tap(); value(field, "あい")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
        try character("う", sumire: true); value(field, "あいう")
        record("stable-caret-and-commit", field: field, stateID: "external-input-field-state")
    }

    func testSelectedUnicodeTextReplacementAndCommit() throws {
        app.terminate()
        app.launchArguments = ["--sumire-forward-delete-test", "--sumire-forward-delete-text=A😀B",
                               "--sumire-forward-delete-start=1", "--sumire-forward-delete-length=2"]
        app.launch()
        let field = app.textFields["external-input-field"]
        field.tap(); try selectIME(sumire: true)
        app.buttons["external-input-test-set-selection"].tap()
        XCTAssertEqual(app.staticTexts["external-input-test-selection-status"].label, "1:2")
        try character("あ", sumire: true); value(field, "AあB")
        XCTAssertTrue(state("external-input-field-state").contains("marked=true;"))
        app.buttons["gojuon-enter"].tap(); value(field, "AあB")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
        record("selected-unicode-replacement", field: field, stateID: "external-input-field-state")
    }

    func testHideCommitsReadingAndSameFieldReentryAppends() throws {
        let field = app.textFields["external-input-field"]
        field.tap(); try selectIME(sumire: true); try character("あ", sumire: true)
        value(field, "あ")
        try nextIME()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["compositionReading"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        value(field, "あ")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
        try selectIME(sumire: true); try character("い", sumire: true)
        value(field, "あい")
        app.buttons["gojuon-enter"].tap(); value(field, "あい")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
        record("hide-same-field-reentry", field: field, stateID: "external-input-field-state")
    }

    func testHiddenSameTextOtherFieldReceivesOnlyFreshReading() throws {
        let field = app.textFields["external-input-field"]
        let matching = app.textFields["external-input-matching-context-field"]
        field.tap(); try selectIME(sumire: true); try character("あ", sumire: true)
        value(field, "あ"); value(matching, "あ")
        try nextIME()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["compositionReading"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        matching.tap(); try selectIME(sumire: true); try character("い", sumire: true)
        value(field, "あ"); value(matching, "あい")
        app.buttons["gojuon-enter"].tap(); value(matching, "あい")
        XCTAssertTrue(state("external-input-matching-context-field-state").contains("marked=false;"))
        record("hidden-same-text-other-field", field: matching, stateID: "external-input-matching-context-field-state")
    }

    func testFocusToSelectedUnicodeTextDoesNotTransferReading() throws {
        app.terminate()
        app.launchArguments = ["--sumire-forward-delete-test", "--sumire-forward-delete-text=A😀B",
                               "--sumire-forward-delete-start=1", "--sumire-forward-delete-length=2"]
        app.launch()
        let field = app.textFields["external-input-field"]
        let other = app.textFields["external-input-other-field"]
        field.tap(); try selectIME(sumire: true)
        other.tap(); try character("あ", sumire: true)
        value(other, "別あ"); value(field, "A😀B")
        app.buttons["external-input-test-set-selection"].tap()
        value(field, "A😀B"); value(other, "別あ")
        XCTAssertEqual(app.staticTexts["external-input-test-selection-status"].label, "1:2")
        try character("い", sumire: true); value(field, "AいB"); value(other, "別あ")
        app.buttons["gojuon-enter"].tap(); value(field, "AいB")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
        record("focus-selected-unicode-replacement", field: field, stateID: "external-input-field-state")
    }

    func testGojuonLongPressKeepsReadingAndExplicitCommit() throws {
        app.terminate(); app.launchArguments = []; app.launch()
        let field = app.textFields["external-input-field"]
        field.tap(); try selectIME(sumire: true)
        try character("あ", sumire: true); try character("い", sumire: true); value(field, "あい")
        record("long-press-reading-before", field: field, stateID: "external-input-field-state")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 23, dy: 0)).press(forDuration: 0.7)
        record("long-press-reading-after", field: field, stateID: "external-input-field-state")
        value(field, "あい")
        XCTAssertTrue(state("external-input-field-state").contains("marked=true;markedUTF16=2;"))
        app.buttons["gojuon-enter"].tap(); value(field, "あい")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"))
    }

    func testBlurClearsOriginalMarkedRangeWithoutTransferringText() throws {
        let field = app.textFields["external-input-field"], other = app.textFields["external-input-other-field"]
        field.tap(); try selectIME(sumire: true); try character("あ", sumire: true)
        value(field, "あ")
        XCTAssertTrue(state("external-input-field-state").contains("marked=true;"))
        other.tap(); value(field, "あ"); value(other, "別")
        record("strict-blur-old-field", field: field, stateID: "external-input-field-state")
        XCTAssertTrue(state("external-input-field-state").contains("marked=false;"), "Blur must clear the old field's actual marked range")
    }

    func testExternalMarkedCaretAcceptsFollowingInputAtHostPosition() throws {
        app.terminate(); app.launchArguments = ["--sumire-forward-delete-test", "--sumire-forward-delete-text=", "--sumire-forward-delete-start=1", "--sumire-forward-delete-length=0"]; app.launch()
        let field = app.textFields["external-input-field"]
        field.tap(); try selectIME(sumire: true)
        try character("あ", sumire: true); try character("い", sumire: true); value(field, "あい")
        record("gojuon-proxy-caret-before", field: field, stateID: "external-input-field-state")
        app.buttons["external-input-test-set-selection"].tap()
        XCTAssertEqual(app.staticTexts["external-input-test-selection-status"].label, "1:0")
        record("gojuon-proxy-caret-host-moved", field: field, stateID: "external-input-field-state")
        try character("う", sumire: true)
        record("gojuon-proxy-caret-after-input", field: field, stateID: "external-input-field-state")
        value(field, "あうい")
    }

    private func state(_ id: String) -> String { app.staticTexts[id].label }
    private func readingStatus() -> String { app.staticTexts["compositionReading"].label }
    private func value(_ field: XCUIElement, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        let outcome = XCTWaiter.wait(for: [condition], timeout: 5)
        if outcome != .completed {
            let observation = XCTAttachment(string: "actual=\(field.value ?? "nil");old=\(state("external-input-field-state"));other=\(state("external-input-other-field-state"));trace=\(app.staticTexts["compositionReading"].exists ? readingStatus() : "standard-ime")")
            observation.name = "failed-visible-edit-fresh-state-and-trace"
            observation.lifetime = .keepAlways; add(observation)
            let picture = XCTAttachment(screenshot: field.screenshot())
            picture.name = "failed-visible-edit-field"; picture.lifetime = .keepAlways; add(picture)
        }
        XCTAssertEqual(outcome, .completed,
                       "Expected fixed text \(text), actual \(field.value ?? "nil")", file: file, line: line)
    }
    private func record(_ phase: String, field: XCUIElement, stateID: String) {
        let trace = app.staticTexts["compositionReading"].exists ? readingStatus() : "standard-ime"
        let observation = XCTAttachment(string: state(stateID) + ";hostEvents=" + state("external-input-lifecycle-state") + ";trace=" + trace)
        observation.name = phase + "-fresh-state"; observation.lifetime = .keepAlways; add(observation)
        let picture = XCTAttachment(screenshot: field.screenshot())
        picture.name = phase + "-field-rendering"; picture.lifetime = .keepAlways; add(picture)
    }
    private func nextIME() throws {
        let onboarding = app.buttons["Continue"]
        if onboarding.exists && onboarding.isHittable {
            onboarding.tap()
            return
        }
        let next = app.buttons.matching(NSPredicate(format: "label IN %@",
            ["Next keyboard", "次のキーボード", "次の入力モード"])).firstMatch
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: next)
        guard XCTWaiter.wait(for: [available], timeout: 3) == .completed else {
            // The system's Kana onboarding can arrive after the first query.
            if onboarding.waitForExistence(timeout: 1) && onboarding.isHittable {
                onboarding.tap()
                return
            }
            let setup = XCTAttachment(string: app.debugDescription)
            setup.name = "input-mode-setup-state"; setup.lifetime = .keepAlways; add(setup)
            XCTFail("The system input-mode key is unavailable")
            throw NSError(domain: "MarkedComparison", code: 1)
        }
        next.tap()
    }
    private func selectIME(sumire: Bool, stateID: String = "external-input-field-state") throws {
        if !sumire {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "次のキーボード", "次の入力モード"])).firstMatch
            if next.waitForExistence(timeout: 2) && next.isHittable {
                next.press(forDuration: 1)
                let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "kana", "かな")
                let cell = app.cells.matching(predicate).firstMatch
                let button = app.buttons.matching(predicate).firstMatch
                let item = app.menuItems.matching(predicate).firstMatch
                if cell.waitForExistence(timeout: 2) { cell.tap() }
                else if button.exists { button.tap() }
                else if item.exists { item.tap() }
                else {
                    let a = XCTAttachment(string: app.debugDescription); a.name = "standard-kana-picker-options"; a.lifetime = .keepAlways; add(a)
                    XCTFail("The system input-mode picker did not expose an enabled Kana keyboard")
                    throw NSError(domain: "MarkedComparison", code: 5)
                }
            }
        }
        for _ in 0..<12 {
            let isSumire = app.staticTexts["compositionReading"].waitForExistence(timeout: 0.3)
            if sumire && isSumire { return }
            let hasKanaKey = app.keyboards.keys["あ"].exists || app.keyboards.buttons["あ"].exists
            if !sumire && !isSumire && hasKanaKey && state(stateID).contains("inputLanguage=ja") { return }
            try nextIME()
        }
        XCTFail(sumire ? "Enabled Sumire keyboard not found" : "Enabled standard Japanese keyboard not found")
        throw NSError(domain: "MarkedComparison", code: 2)
    }
    private func character(_ text: String, sumire: Bool) throws {
        if sumire {
            let row = ["あ": 0, "い": 1, "う": 2][text]!
            let key = app.buttons["gojuon-\(row)-10"]
            if !key.exists {
                let switcher = app.buttons["keyboard-switch"]
                XCTAssertTrue(switcher.waitForExistence(timeout: 3))
                switcher.press(forDuration: 1)
                let button = app.buttons["50音"], item = app.menuItems["50音"]
                if button.waitForExistence(timeout: 3) { button.tap() }
                else { XCTAssertTrue(item.waitForExistence(timeout: 2)); item.tap() }
            }
            XCTAssertTrue(key.waitForExistence(timeout: 3)); XCTAssertEqual(key.label, text); key.tap()
        } else {
            let kana = app.keyboards.keys["あ"]
            let kanaButton = app.keyboards.buttons["あ"]
            if kana.exists || kanaButton.exists {
                let key = kana.exists ? kana : kanaButton
                if text == "あ" { key.tap() }
                else {
                    // Flick works with either tap-cycle or flick-only settings.
                    let origin = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    let delta = text == "い" ? CGVector(dx: -key.frame.width * 0.8, dy: 0)
                                            : CGVector(dx: 0, dy: -key.frame.height * 0.8)
                    origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(delta))
                }
            } else {
                let roman = app.keyboards.keys[["あ": "a", "い": "i", "う": "u"][text]!]
                guard roman.exists else {
                    let picture = XCTAttachment(screenshot: app.screenshot()); picture.lifetime = .keepAlways; add(picture)
                    XCTFail("Standard Japanese keyboard exposes neither Kana nor Romaji fixture key")
                    throw NSError(domain: "MarkedComparison", code: 3)
                }
                roman.tap()
            }
        }
    }
    private func delete(sumire: Bool) {
        if sumire { app.buttons["gojuon-delete"].tap() }
        else {
            let predicate = NSPredicate(format: "label IN %@", ["delete", "Delete", "削除"])
            let key = app.keyboards.keys.matching(predicate).firstMatch
            if key.exists { key.tap() }
            else {
                let button = app.keyboards.buttons.matching(predicate).firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
            }
        }
    }
    private func compare(sumire: Bool) throws {
        let old = app.textFields["external-input-field"]
        let other = app.textFields["external-input-other-field"]
        let oldID = "external-input-field-state", otherID = "external-input-other-field-state"
        old.tap(); try selectIME(sumire: sumire)
        try character("あ", sumire: sumire)
        value(old, "あ")
        XCTAssertTrue(state(oldID).contains("marked=true;"), "The baseline must start with a genuinely composing reading")
        record("01-active-reading", field: old, stateID: oldID)
        if sumire {
            let trace = XCTAttachment(string: readingStatus()); trace.name = "original-sumire-privacy-safe-trace"; trace.lifetime = .keepAlways; add(trace)
            XCTAssertTrue(readingStatus().contains("fullAccess=false"), "Comparison requires Full Access OFF; do not change the setting automatically")
        }
        other.tap()
        value(old, "あ"); value(other, "別")
        record("02-old-field-after-focus-change", field: old, stateID: oldID)
        record("03-new-field-before-input", field: other, stateID: otherID)
        try character("い", sumire: sumire)
        value(other, "別い"); value(old, "あ")
        record("04-new-field-after-input", field: other, stateID: otherID)
        old.tap()
        record("05-old-field-reentered", field: old, stateID: oldID)
        try character("う", sumire: sumire)
        value(old, "あう"); value(other, "別い")
        record("06-old-field-appended", field: old, stateID: oldID)
        delete(sumire: sumire)
        value(old, "あ"); value(other, "別い")
        record("07-old-field-after-delete", field: old, stateID: oldID)
    }
}
