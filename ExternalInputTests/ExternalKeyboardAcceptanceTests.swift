import XCTest

/// Cross-process tests. The host contains no keyboard implementation or InputHarness.
/// Before running, enable Sumire manually and select its Japanese Sumire/TenKey/50音
/// layout. The scheme builds the containing app and keyboard extension as well as
/// this host/runner. The generated .xctestrun may include them as dependent products:
/// inspect its staging paths and keep app/extension binaries from the same source
/// revision and signing configuration. Do not assume running this scheme installs
/// only the test host or preserves an existing Sumire installation unchanged.
/// Set SUMIRE_REQUIRE_EXTENSION=1 in the test environment after setup to make
/// missing/crashed extension visibility fail instead of skipping. Pass the explicit
/// xcodebuild setting `SUMIRE_REQUIRE_EXTENSION=1` with scheme
/// `SumireExternalKeyboardAcceptance`; the scheme forwards it to the test runner.
final class ExternalKeyboardAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func requireExtension() throws {
        // Only Sumire's real extension can expose this identifier in this host.
        guard app.staticTexts["compositionReading"].waitForExistence(timeout: 10) else {
            if ProcessInfo.processInfo.environment["SUMIRE_REQUIRE_EXTENSION"] == "1" {
                XCTFail("Expected the real Sumire extension, but its accessibility marker is missing.")
                throw NSError(domain: "ExternalKeyboardAcceptance", code: 1)
            }
            throw XCTSkip("Sumire extension is not selected/visible. Install the built Sumire app, then enable and select its keyboard manually; this test never changes Full Access. No stock keyboard input was tested.")
        }
    }

    private func key(_ identifiers: [String]) -> XCUIElement? {
        identifiers.map { app.buttons[$0] }.first { $0.exists && $0.isHittable }
    }

    private func exercise(_ input: XCUIElement, rotateAfterCommit: Bool = false) throws {
        input.tap()
        try requireExtension()
        guard let a = key(["sumire-a", "tenkey-0-0", "gojuon-0-10"]),
              let delete = key(["sumire-delete_key", "tenkey-delete", "gojuon-delete"]),
              let enter = key(["sumire-enter_key", "tenkey-enter", "gojuon-enter"]) else {
            throw XCTSkip("Sumire is visible, but a supported Japanese layout is not selected. Select Sumire/TenKey/50音 manually.")
        }
        guard a.label == "あ" else {
            throw XCTSkip("The selected Sumire layout is not in Japanese mode.")
        }
        a.tap()
        let reading = app.staticTexts["compositionReading"]
        let hasReading = NSPredicate(format: "label BEGINSWITH %@", "あ")
        expectation(for: hasReading, evaluatedWith: reading)
        waitForExpectations(timeout: 5)
        XCTAssertFalse((input.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Marked input must propagate into the external host before commit")
        delete.tap()
        // Verify deletion through the host document, not only the extension's reading label.
        XCTAssertEqual(input.value as? String ?? "", "")
        a.tap()
        enter.tap()
        let committed = NSPredicate(format: "value != '' AND value != nil")
        expectation(for: committed, evaluatedWith: input)
        waitForExpectations(timeout: 5)
        let result = input.value as? String ?? ""
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if rotateAfterCommit {
            defer { XCUIDevice.shared.orientation = .portrait }
            XCUIDevice.shared.orientation = .landscapeLeft
            try requireExtension()
            XCTAssertGreaterThan(app.frame.width, app.frame.height, "Host must actually rotate to landscape")
            XCTAssertEqual(input.value as? String, result)
            XCUIDevice.shared.orientation = .portrait
            try requireExtension()
            XCTAssertEqual(input.value as? String, result)
        }
        delete.tap()
        XCTAssertEqual(input.value as? String ?? "", "")
    }

    func testUITextFieldInputDeleteCommit() throws {
        try exercise(app.textFields["external-input-field"], rotateAfterCommit: true)
    }

    func testUITextViewInputDeleteCommitAndHostReturn() throws {
        let input = app.textViews["external-input-view"]
        try exercise(input)
        XCUIDevice.shared.press(.home)
        app.activate()
        input.tap()
        try requireExtension()
        try exercise(input)
    }

    private func exerciseDistinctCompositionAcrossHostReturn(_ input: XCUIElement,
                                                             hostKind: String) throws {
        let hostState = app.staticTexts["\(input.identifier)-state"]
        input.tap()
        try requireExtension()
        guard let first = key(["gojuon-0-10"]), first.label == "あ",
              let second = key(["gojuon-1-10"]), second.label == "い",
              let enter = key(["gojuon-enter"]) else {
            throw XCTSkip("Select a supported Japanese Sumire/TenKey/50音 layout manually.")
        }
        first.tap()
        expectation(for: NSPredicate(format: "value == %@", "あ"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "あ", "The first synthetic reading must be marked in the host")
        let initialMark = NSPredicate(format: "label CONTAINS %@", "content=first;marked=true;")
        expectation(for: initialMark, evaluatedWith: hostState)
        waitForExpectations(timeout: 5)

        XCUIDevice.shared.press(.home)
        app.activate()
        input.tap()
        try requireExtension()
        let finalized = NSPredicate(format: "label CONTAINS %@", "content=first;marked=false;")
        expectation(for: finalized, evaluatedWith: hostState)
        waitForExpectations(timeout: 5)
        let stateOnReturn = hostState.label
        XCTAssertTrue(stateOnReturn.contains("content=first;"),
                      "The host should retain the first reading across activation; stateOnReturn=\(stateOnReturn)")
        XCTAssertTrue(stateOnReturn.contains("marked=false;"),
                      "The old composition must be finalized before a new reading; stateOnReturn=\(stateOnReturn)")
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The selected Sumire layout disappeared on host return")

        second.tap()
        let bothContent = NSPredicate(format: "label CONTAINS %@", "content=both;marked=true;")
        let bothExpectation = XCTNSPredicateExpectation(predicate: bothContent, object: hostState)
        XCTAssertEqual(XCTWaiter.wait(for: [bothExpectation], timeout: 5), .completed,
                       "The resumed composition should expose both synthetic readings as marked")
        let stateAfterSecond = hostState.label
        XCTAssertTrue(stateAfterSecond.contains("content=both;"),
                      "The second distinct reading must append; stateOnReturn=\(stateOnReturn), stateAfterSecond=\(stateAfterSecond)")
        XCTAssertEqual(input.value as? String, "あい",
                       "The second distinct reading must append instead of replacing the suspended mark (\(hostKind)); stateOnReturn=\(stateOnReturn), stateAfterSecond=\(stateAfterSecond)")

        enter.tap()
        expectation(for: NSPredicate(format: "value == %@", "あい"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "あい", "Commit must retain both readings (\(hostKind))")
    }

    func testComposingTextSurvivesHostReturnWithoutStaleReplacementInUITextField() throws {
        try exerciseDistinctCompositionAcrossHostReturn(app.textFields["external-input-field"],
                                                       hostKind: "UITextField")
    }

    func testComposingTextSurvivesHostReturnWithoutStaleReplacementInUITextView() throws {
        try exerciseDistinctCompositionAcrossHostReturn(app.textViews["external-input-view"],
                                                       hostKind: "UITextView")
    }

}
