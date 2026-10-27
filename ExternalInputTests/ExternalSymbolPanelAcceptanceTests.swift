import XCTest

/// Exercises the symbol panels from the actual keyboard extension in an external host.
/// Before running, enable Sumire manually in this Simulator and select a Japanese
/// Sumire/TenKey/50音 layout. The host keeps input only in its volatile text field.
/// Set SUMIRE_REQUIRE_EXTENSION=1 to make a missing Sumire extension/layout fail
/// instead of skipping; this test does not change keyboard permissions or Full Access.
final class ExternalSymbolPanelAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private var requiresExtension: Bool {
        ProcessInfo.processInfo.environment["SUMIRE_REQUIRE_EXTENSION"] == "1"
    }

    private func requireSelectedExtension() throws {
        guard app.staticTexts["compositionReading"].waitForExistence(timeout: 10) else {
            if requiresExtension {
                XCTFail("Expected the real Sumire extension, but its accessibility marker is missing.")
                throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 1)
            }
            throw XCTSkip("Sumire is not selected/visible. Enable and select it manually in Simulator settings.")
        }
    }

    private func requiredElement(_ identifier: String, description: String) throws -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: 5) else {
            if requiresExtension {
                XCTFail("\(description) was not available in the selected Sumire extension: \(identifier)")
                throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 2)
            }
            throw XCTSkip("\(description) is unavailable; select a supported Japanese Sumire layout manually.")
        }
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        guard XCTWaiter.wait(for: [hittable], timeout: 5) == .completed else {
            if requiresExtension {
                XCTFail("\(description) never became hittable: \(identifier)")
                throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 5)
            }
            throw XCTSkip("\(description) did not become hittable; select a supported Japanese Sumire layout manually.")
        }
        return element
    }

    private func requireSelected(_ element: XCUIElement, description: String) throws {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        guard XCTWaiter.wait(for: [selected], timeout: 5) == .completed else {
            XCTFail("\(description) did not become selected")
            throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 6)
        }
    }

    private func exercise(mode: String, category: String, expectedSymbol: String) throws {
        let input = app.textFields["external-input-field"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        try requireSelectedExtension()
        let previousText = input.value as? String ?? ""
        XCTAssertEqual(previousText, "", "Each host-field test starts with a fresh volatile document")

        let open = try requiredElement("symbol-open", description: "Symbol-panel toolbar action")
        open.tap()

        let modeTab = try requiredElement("symbol-mode-\(mode)", description: "Symbol mode tab")
        modeTab.tap()
        try requireSelected(modeTab, description: "Symbol mode tab")
        let categoryTab = try requiredElement("symbol-category-\(category)", description: "Symbol category")
        categoryTab.tap()
        try requireSelected(categoryTab, description: "Symbol category")

        let collection = app.collectionViews["symbol-items"]
        guard collection.waitForExistence(timeout: 5) else {
            XCTFail("The real extension's symbol collection did not appear")
            throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 3)
        }
        let item = collection.descendants(matching: .any).matching(identifier: "symbol-item-0").firstMatch
        let selectedItem = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND label == %@", expectedSymbol),
            object: item)
        guard XCTWaiter.wait(for: [selectedItem], timeout: 5) == .completed else {
            XCTFail("The expected first symbol did not become visible and hittable in the selected category")
            throw NSError(domain: "ExternalSymbolPanelAcceptance", code: 4)
        }
        XCTAssertEqual(item.label, expectedSymbol, "The selected catalog entry should be stable for this fixture")
        item.tap()

        let expectedValue = previousText + expectedSymbol
        let inserted = NSPredicate(format: "value == %@", expectedValue)
        expectation(for: inserted, evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, expectedValue,
                       "The actual extension should insert the selected symbol into the external UITextField")
    }

    func testEmojiPanelInsertsIntoExternalTextField() throws {
        try exercise(mode: "emoji", category: "SMILEYS_EMOTION", expectedSymbol: "😀")
    }

    func testEmoticonPanelInsertsIntoExternalTextField() throws {
        try exercise(mode: "emoticon", category: "SMILE", expectedSymbol: "(≧∇≦)b")
    }

    func testSymbolPanelInsertsIntoExternalTextField() throws {
        try exercise(mode: "symbol", category: "GENERAL", expectedSymbol: "※")
    }
}
