import XCTest

/// Cross-process tests. The host contains no keyboard implementation or InputHarness.
/// Before running, enable and select the real Sumire extension manually. Tests that
/// require 50音 choose that internal layout through Sumire's own layout menu. The
/// scheme builds the containing app and keyboard extension as well as
/// this host/runner. The generated .xctestrun may include them as dependent products:
/// inspect its staging paths and keep app/extension binaries from the same source
/// revision and signing configuration. Do not assume running this scheme installs
/// only the test host or preserves an existing Sumire installation unchanged.
/// Set SUMIRE_REQUIRE_EXTENSION=1 in the test environment after setup to make
/// missing/crashed extension visibility fail instead of skipping. Pass the explicit
/// xcodebuild setting `SUMIRE_REQUIRE_EXTENSION=1` with scheme
/// `SumireExternalKeyboardAcceptance`; the scheme forwards it to the test runner.
final class ExternalKeyboardAcceptanceTests: XCTestCase {
    private struct CompositionTraceEvent: Equatable {
        let sequence: UInt64
        let processIdentifier: Int32
        let controllerIdentifier: UInt64
        let uptime: TimeInterval
        let name: String
    }

    private var app: XCUIApplication!

    private let sumireBundleIdentifier = "com.kazumaproject.sumire.ios"

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

    private func compositionTraceEvents(in trace: String) -> [CompositionTraceEvent] {
        trace.split(separator: "|", omittingEmptySubsequences: true).compactMap { rawEvent in
            var fields: [String: String] = [:]
            for component in rawEvent.split(separator: ";", omittingEmptySubsequences: true) {
                let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                fields[String(pair[0])] = String(pair[1])
            }
            guard let sequence = fields["seq"].flatMap({ UInt64($0) }),
                  let processIdentifier = fields["pid"].flatMap({ Int32($0) }),
                  let controllerIdentifier = fields["controller"].flatMap({ UInt64($0) }),
                  let uptime = fields["uptime"].flatMap({ TimeInterval($0) }),
                  let name = fields["event"] else { return nil }
            return CompositionTraceEvent(sequence: sequence, processIdentifier: processIdentifier,
                                         controllerIdentifier: controllerIdentifier, uptime: uptime,
                                         name: name)
        }
    }

    private func hostLifecycleEventUptime(named name: String, laterThan lowerBound: TimeInterval? = nil,
                                          in trace: String) -> TimeInterval? {
        trace.split(separator: "|", omittingEmptySubsequences: true).compactMap { rawEvent in
            let header = rawEvent.split(separator: "{", maxSplits: 1).first ?? rawEvent[...]
            let nameParts = header.split(separator: ":", maxSplits: 1)
            guard nameParts.count == 2, String(nameParts[1]) == name else { return nil }
            let sequenceAndUptime = nameParts[0].split(separator: "@", maxSplits: 1)
            guard sequenceAndUptime.count == 2 else { return nil }
            guard let uptime = TimeInterval(String(sequenceAndUptime[1])) else { return nil }
            if let lowerBound, uptime <= lowerBound { return nil }
            return uptime
        }.last
    }

    private func waitForHostLifecycleEvent(named name: String, laterThan lowerBound: TimeInterval,
                                           in traceElement: XCUIElement,
                                           timeout: TimeInterval = 5) -> TimeInterval? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let uptime = hostLifecycleEventUptime(named: name, laterThan: lowerBound,
                                                     in: traceElement.label) {
                return uptime
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return hostLifecycleEventUptime(named: name, laterThan: lowerBound, in: traceElement.label)
    }

    private func freshCompositionTraceEvent(named name: String, after baseline: CompositionTraceEvent,
                                            laterThan uptime: TimeInterval,
                                            in trace: String) -> CompositionTraceEvent? {
        compositionTraceEvents(in: trace).first { event in
            event.name == name && event.uptime > uptime &&
                (event.processIdentifier != baseline.processIdentifier || event.sequence > baseline.sequence)
        }
    }

    private func japanese50OnKey(_ identifier: String, label: String) throws -> XCUIElement {
        let kanaKey = app.buttons[identifier]
        if !(kanaKey.exists && kanaKey.isHittable) {
            // Sumire's OS keyboard selection and its internal layout are separate.
            // A Simulator can correctly select the extension while remembering a
            // custom layout; use the public long-press menu instead of skipping.
            let switcher = app.buttons["keyboard-switch"]
            guard switcher.waitForExistence(timeout: 3), switcher.isHittable else {
                XCTFail("The Sumire extension is visible, but its internal layout switcher is unavailable.")
                throw NSError(domain: "ExternalKeyboardAcceptance", code: 4)
            }
            switcher.press(forDuration: 1.0)
            let menuButton = app.buttons["50音"]
            let menuItem = app.menuItems["50音"]
            let menuChoice: XCUIElement
            if menuButton.waitForExistence(timeout: 3) { menuChoice = menuButton }
            else if menuItem.waitForExistence(timeout: 2) { menuChoice = menuItem }
            else {
                XCTFail("Sumire's internal layout menu did not expose its 50音 choice.")
                throw NSError(domain: "ExternalKeyboardAcceptance", code: 5)
            }
            menuChoice.tap()
        }
        guard kanaKey.waitForExistence(timeout: 5), kanaKey.isHittable else {
            XCTFail("Selecting Sumire's 50音 layout did not expose key \(identifier).")
            throw NSError(domain: "ExternalKeyboardAcceptance", code: 6)
        }
        XCTAssertEqual(kanaKey.label, label, "The selected 50音 key must be in Japanese mode.")
        return kanaKey
    }

    private func selectSumireKeyboardIfNeeded() throws {
        let marker = app.staticTexts["compositionReading"]
        if marker.waitForExistence(timeout: 1) { return }

        // The system input-mode key is separate from Sumire's in-keyboard layout
        // selector. Use it only to return to the already-enabled Sumire extension.
        let nextKeyboard = app.buttons.matching(
            NSPredicate(format: "label == %@", "Next keyboard")
        ).firstMatch
        for _ in 0..<12 {
            guard nextKeyboard.exists && nextKeyboard.isHittable else { break }
            nextKeyboard.tap()
            if marker.waitForExistence(timeout: 2) { return }
        }
        XCTFail("Sumire must be enabled and selectable before external keyboard acceptance.")
        throw NSError(domain: "ExternalKeyboardAcceptance", code: 3)
    }

    private func scroll(_ list: XCUIElement, until element: XCUIElement,
                        towardTop: Bool, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            guard list.exists && list.isHittable else { return false }
            if towardTop { list.swipeDown() } else { list.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    private func captureKeyboardSettingsState(_ sumire: XCUIApplication) throws -> String {
        sumire.launchArguments = ["--sumire-test-capture-keyboard-state", "--sumire-test-export-keyboard-state"]
        sumire.launch()
        // These arguments are consumed by the app initializer. Do not let a later
        // cleanup launch overwrite the original snapshot with the mutated test state.
        sumire.launchArguments = []
        XCTAssertTrue(sumire.buttons["settings-preview"].waitForExistence(timeout: 5))
        sumire.buttons["settings-preview"].tap()
        XCTAssertTrue(sumire.textViews["入力テスト"].waitForExistence(timeout: 5))
        sumire.buttons["preview-settings"].tap()
        XCTAssertTrue(sumire.buttons["Custom Keyboard"].waitForExistence(timeout: 5))
        sumire.buttons["Custom Keyboard"].tap()

        let state = sumire.staticTexts["sumire-test-keyboard-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let loaded = expectation(for: NSPredicate(format: "label != %@", "loading"), evaluatedWith: state)
        wait(for: [loaded], timeout: 5)
        guard state.label.hasPrefix("none|"), state.label.count < 256 else {
            throw NSError(domain: "ExternalKeyboardAcceptance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Keyboard settings fingerprint was invalid."])
        }
        return state.label
    }

    private func installForwardDeleteLayout(_ sumire: XCUIApplication, id layoutID: String) throws {
        let source: [String: Any] = [
            "schemaVersion": 4,
            "layouts": [[
                "layout": ["stableId": layoutID, "name": layoutID, "rowCount": 1, "columnCount": 5],
                "keysWithFlicks": [
                    ["key": [
                        "keyIdentifier": "forward",
                        "label": "後削除",
                        "column": 0,
                        "action": "DeleteAfterCursor"
                    ]],
                    ["key": [
                        "keyIdentifier": "undo",
                        "label": "戻す",
                        "column": 1,
                        "action": "UndoLastDelete"
                    ]],
                    ["key": [
                        "keyIdentifier": "backward",
                        "label": "前削除",
                        "column": 2,
                        "action": "Backspace"
                    ]],
                    ["key": [
                        "keyIdentifier": "boundary",
                        "label": "区切削除",
                        "column": 3,
                        "action": "DeleteUntilSymbol"
                    ]],
                    ["key": [
                        "keyIdentifier": "forward-boundary",
                        "label": "後区切削除",
                        "column": 4,
                        "action": "DeleteAfterCursorUntilSymbol"
                    ]]
                ]
            ]]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
        let importJSON = sumire.buttons["配列JSONを入力"]
        XCTAssertTrue(importJSON.waitForExistence(timeout: 5),
                      "The JSON import control must be visible in Custom Keyboard settings.")
        XCTAssertTrue(importJSON.isHittable)
        importJSON.tap()
        let editor = sumire.textViews["customLayoutJSON"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(json)
        XCTAssertEqual(editor.value as? String, json,
                       "The generated layout JSON must be present in the editor before validation.")
        sumire.buttons["内容を検証"].tap()
        XCTAssertTrue(sumire.staticTexts["有効：1件／不正：0件"].waitForExistence(timeout: 5))
        sumire.buttons["有効な配列を追加"].tap()
        sumire.buttons["完了"].tap()
        sumire.buttons["preview-settings"].tap()
        sumire.buttons["Custom Keyboard"].tap()
        let verificationList = sumire.collectionViews.firstMatch
        let definition = sumire.descendants(matching: .any)["custom-layout-definition:" + layoutID]
        XCTAssertTrue(verificationList.waitForExistence(timeout: 5))
        XCTAssertTrue(scroll(verificationList, until: definition, towardTop: false),
                      "The imported fixture must be visible by its exact stable ID.")
        sumire.buttons["完了"].tap()
        sumire.buttons["preview-settings"].tap()
        sumire.buttons["キーボードの選択・順序"].tap()
        let selectionList = sumire.collectionViews.firstMatch
        XCTAssertTrue(selectionList.waitForExistence(timeout: 5))
        let selectionRow = sumire.descendants(matching: .any)["keyboard-selection-row-custom:" + layoutID]
        let alreadySelected = scroll(selectionList, until: selectionRow, towardTop: false)
        if !alreadySelected {
            let add = sumire.buttons[layoutID]
            XCTAssertTrue(scroll(selectionList, until: add, towardTop: false),
                          "The imported layout must be reachable in the Add section of keyboard selection.")
            add.tap()
            XCTAssertTrue(scroll(selectionList, until: selectionRow, towardTop: false),
                          "The imported layout must appear in the selected keyboard list after adding it.")
        }
        sumire.buttons["完了"].tap()
        sumire.terminate()
    }

    private func restoreKeyboardSettings(_ sumire: XCUIApplication, snapshot: String) -> Bool {
        sumire.launchArguments = [
            "--sumire-test-restore-keyboard-state",
            "--sumire-test-export-keyboard-state"
        ]
        sumire.launch()
        sumire.launchArguments = []
        let preview = sumire.buttons["settings-preview"]
        guard preview.waitForExistence(timeout: 5) else { sumire.terminate(); return false }
        preview.tap()
        guard sumire.textViews["入力テスト"].waitForExistence(timeout: 5) else {
            sumire.terminate(); return false
        }
        let settings = sumire.buttons["preview-settings"]
        guard settings.waitForExistence(timeout: 5) else { sumire.terminate(); return false }
        settings.tap()
        let customKeyboards = sumire.buttons["Custom Keyboard"]
        guard customKeyboards.waitForExistence(timeout: 5) else { sumire.terminate(); return false }
        customKeyboards.tap()
        let state = sumire.staticTexts["sumire-test-keyboard-state"]
        guard state.waitForExistence(timeout: 5) else { sumire.terminate(); return false }
        let loaded = expectation(for: NSPredicate(format: "label != %@", "loading"), evaluatedWith: state)
        wait(for: [loaded], timeout: 5)
        let expectedFingerprint = snapshot.split(separator: "|", maxSplits: 1).last.map(String.init)
        let stateComponents = state.label.split(separator: "|", maxSplits: 1).map(String.init)
        XCTAssertEqual(stateComponents.first, "restored", "The app must find and apply the saved test snapshot.")
        XCTAssertEqual(stateComponents.last, expectedFingerprint, "The test-only keyboard settings must match their pre-test digest.")
        let restored = stateComponents.first == "restored" && stateComponents.last == expectedFingerprint
        sumire.terminate()
        return restored
    }

    private func exerciseForwardDelete(
        scenarios: [(text: String, selectionStart: Int, selectionLength: Int, expected: String)],
        undoAfterDelete: Bool = false,
        deletionButtonIdentifier: String = "custom-forward",
        deletionResults: [String]? = nil,
        undoResults: [String]? = nil,
        undoCaretOffsetsFromSelectionStart: [Int]? = nil,
        hideReturnBeforeDelete: Bool = false
    ) throws {
        let sumire = XCUIApplication(bundleIdentifier: sumireBundleIdentifier)
        let layoutID = "ExternalForwardDelete-" + UUID().uuidString
        let keyboardState = try captureKeyboardSettingsState(sumire)
        defer {
            app.terminate()
            XCTAssertTrue(restoreKeyboardSettings(sumire, snapshot: keyboardState),
                          "Keyboard settings must match their pre-test state.")
        }
        try installForwardDeleteLayout(sumire, id: layoutID)
        if let offsets = undoCaretOffsetsFromSelectionStart {
            XCTAssertEqual(offsets.count, scenarios.count)
        }
        sumire.launchArguments = ["--sumire-test-last-used-keyboard=custom:\(layoutID)"]
        sumire.launch()
        sumire.terminate()
        sumire.launchArguments = []

        for (scenarioIndex, scenario) in scenarios.enumerated() {
            app.terminate()
            app.launchArguments = [
                "--sumire-forward-delete-test",
                "--sumire-forward-delete-text=\(scenario.text)",
                "--sumire-forward-delete-start=\(scenario.selectionStart)",
                "--sumire-forward-delete-length=\(scenario.selectionLength)"
            ]
            app.launch()
            let input = app.textFields["external-input-field"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, scenario.text)
            app.buttons["external-input-test-set-selection"].tap()
            XCTAssertTrue(app.staticTexts["external-input-test-selection-status"]
                .waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["external-input-test-selection-status"].label,
                           "\(scenario.selectionStart):\(scenario.selectionLength)")
            try selectSumireKeyboardIfNeeded()
            try requireExtension()
            if hideReturnBeforeDelete {
                XCUIDevice.shared.press(.home)
                app.activate()
                try requireExtension()
                let selectionStatus = app.staticTexts["external-input-test-selection-status"]
                XCTAssertEqual(selectionStatus.label,
                               "\(scenario.selectionStart):\(scenario.selectionLength)",
                               "The host selection must remain at the test cursor after hide and return.")
            }
            let expectedDeletionStates = deletionResults ?? [scenario.expected]
            XCTAssertFalse(expectedDeletionStates.isEmpty)
            for expected in expectedDeletionStates {
                let delete = app.buttons[deletionButtonIdentifier]
                XCTAssertTrue(delete.waitForExistence(timeout: 5),
                              "The test-selected custom layout must be active in the extension.")
                XCTAssertTrue(delete.isHittable)
                delete.tap()
                let deleted = expectation(for: NSPredicate(format: "value == %@", expected),
                                          evaluatedWith: input)
                wait(for: [deleted], timeout: 5)
                XCTAssertEqual(input.value as? String, expected, scenario.text)
            }
            if undoAfterDelete {
                let undo = app.buttons["custom-undo"]
                XCTAssertTrue(undo.waitForExistence(timeout: 5),
                              "The imported Android UndoLastDelete command must be exposed by the extension.")
                XCTAssertTrue(undo.isHittable)
                for expected in undoResults ?? [scenario.text] {
                    undo.tap()
                    let restored = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: input)
                    wait(for: [restored], timeout: 5)
                    XCTAssertEqual(input.value as? String, expected)

                    let selectionStatus = app.staticTexts["external-input-test-selection-status"]
                    let caretOffset = undoCaretOffsetsFromSelectionStart?[scenarioIndex] ?? 0
                    let expectedCaret = "\(scenario.selectionStart + caretOffset):0"
                    let caretRestored = expectation(for: NSPredicate(format: "label == %@", expectedCaret),
                                                    evaluatedWith: selectionStatus)
                    wait(for: [caretRestored], timeout: 5)
                    XCTAssertEqual(selectionStatus.label, expectedCaret,
                                   "Undo should restore deleted text and the expected editor cursor location.")
                }

                // The entry is consumed once; a second undo must not modify host text.
                undo.tap()
                XCTAssertEqual(input.value as? String, undoResults?.last ?? scenario.text)
            }
            app.terminate()
        }
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

    func testForwardDeleteAfterHostHideReturnUsesExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A日B", selectionStart: 1, selectionLength: 0, expected: "AB")],
            hideReturnBeforeDelete: true
        )
    }

    func testForwardDeleteRemovesNextComposedCharacterThroughExtensionProxy() throws {
        // These cases traverse the real UITextDocumentProxy path. Each cursor sits
        // after ASCII A and before exactly one grapheme cluster.
        try exerciseForwardDelete(scenarios: [
            (text: "A日B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A𠮷B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "Aか\u{3099}B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A🇯🇵B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A👍🏽B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A👩‍💻B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            // With no trailing context, the production proxy path must be a no-op.
            (text: "AB", selectionStart: 2, selectionLength: 0, expected: "AB")
        ])
    }

    func testForwardDeleteDeletesHostSelectionBeforeTrailingContext() throws {
        // A selected prefix plus trailing text distinguishes selection deletion
        // from moving the proxy to and deleting the following grapheme.
        try exerciseForwardDelete(scenarios: [
            (text: "A👩‍💻B", selectionStart: 0, selectionLength: 1, expected: "👩‍💻B")
        ])
    }

    func testForwardDeleteUndoRestoresComposedTextAndCaretThroughExtensionProxy() throws {
        try exerciseForwardDelete(scenarios: [
            (text: "A日B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A𠮷B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "Aか\u{3099}B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A🇯🇵B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A👍🏽B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            (text: "A👩‍💻B", selectionStart: 1, selectionLength: 0, expected: "AB"),
            // Select the supplementary grapheme (five UTF-16 units) and verify
            // Android's collapsed-caret undo behavior for selection deletion.
            (text: "A👩‍💻B", selectionStart: 1, selectionLength: 5, expected: "AB")
        ], undoAfterDelete: true)
    }

    func testForwardDeleteUndoRestoresSelectedComposedTextThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A👩‍💻B", selectionStart: 1, selectionLength: 5, expected: "AB")],
            undoAfterDelete: true
        )
    }

    func testForwardDeleteUndoRestoresUnselectedZWJThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A👩‍💻B", selectionStart: 1, selectionLength: 0, expected: "AB")],
            undoAfterDelete: true
        )
    }

    func testForwardBoundaryDeleteUndoRestoresUnicodeWordAndCaretThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [
                (text: "ab👩‍💻かな。tail", selectionStart: 0, selectionLength: 0, expected: "。tail"),
                (text: "。tail", selectionStart: 0, selectionLength: 0, expected: "tail")
            ],
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-forward-boundary"
        )
    }

    func testForwardDeleteUndoDoesNotGuessRepeatedSelectionPrefixThroughExtensionProxy() throws {
        // The context "AB" is ambiguous when the first A is selected in AAB:
        // it could include the selected A or begin after it. Preserve deletion,
        // but do not construct undo history from that proxy snapshot alone.
        try exerciseForwardDelete(
            scenarios: [(text: "AAB", selectionStart: 0, selectionLength: 1, expected: "AB")],
            undoAfterDelete: true,
            undoResults: ["AB"]
        )
    }

    func testBackwardDeleteUndoRestoresSelectedTextThroughExtensionProxy() throws {
        // Selection lengths and the restored cursor offset are UTF-16 units,
        // matching UITextInput and Android's InputConnection cursor contract.
        let selectedClusters = ["あ", "𠮷", "か\u{3099}", "🇯🇵", "👋🏽", "👩‍💻"]
        let scenarios = selectedClusters.map { selected in
            (text: "A\(selected)B", selectionStart: 1,
             selectionLength: selected.utf16.count, expected: "AB")
        }
        try exerciseForwardDelete(
            scenarios: scenarios,
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-backward",
            undoCaretOffsetsFromSelectionStart: selectedClusters.map { $0.utf16.count }
        )
    }

    func testDeleteUntilBoundaryUndoRestoresSelectedTextThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A👩‍💻B", selectionStart: 1, selectionLength: 5, expected: "AB")],
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-boundary"
        )
    }

    func testBackwardDeleteUndoDoesNotGuessRepeatedSelectionPrefixThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "AAB", selectionStart: 0, selectionLength: 1, expected: "AB")],
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-backward",
            undoResults: ["AB"]
        )
    }

    func testDeleteUntilBoundaryUndoDoesNotGuessRepeatedSelectionPrefixThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "AAB", selectionStart: 0, selectionLength: 1, expected: "AB")],
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-boundary",
            undoResults: ["AB"]
        )
    }

    func testRepeatedForwardDeleteUndoRestoresEachDeletionInReverseOrder() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A日𠮷B", selectionStart: 1, selectionLength: 0, expected: "AB")],
            undoAfterDelete: true,
            deletionResults: ["A𠮷B", "AB"],
            undoResults: ["A𠮷B", "A日𠮷B"]
        )
    }

    func testBackwardDeleteUndoRestoresTextAndOriginalCaretThroughExtensionProxy() throws {
        try exerciseForwardDelete(
            scenarios: [(text: "A👩‍💻B", selectionStart: 6, selectionLength: 0, expected: "AB")],
            undoAfterDelete: true,
            deletionButtonIdentifier: "custom-backward"
        )
    }

    func testComposingTextSurvivesHostReturnWithoutStaleReplacement() throws {
        let input = app.textFields["external-input-field"]
        input.tap()
        try requireExtension()
        let a = try japanese50OnKey("gojuon-0-10", label: "あ")
        a.tap()
        let hasText = NSPredicate(format: "value != '' AND value != nil")
        expectation(for: hasText, evaluatedWith: input)
        waitForExpectations(timeout: 5)
        let before = input.value as? String ?? ""
        XCTAssertFalse(before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCUIDevice.shared.press(.home)
        app.activate()
        input.tap()
        try requireExtension()
        XCTAssertEqual(input.value as? String, before)
        let returnedA = try japanese50OnKey("gojuon-0-10", label: "あ")
        returnedA.tap()
        // The previous host text must not be replaced by a stale marked-text session.
        let appended = NSPredicate(format: "value == %@", before + "あ")
        expectation(for: appended, evaluatedWith: input)
        waitForExpectations(timeout: 5)
    }

    func testActiveCompositionDoesNotTransferToDifferentHostContext() throws {
        let original = app.textFields["external-input-field"]
        let originalState = app.staticTexts["external-input-field-state"]
        let other = app.textFields["external-input-other-field"]
        let otherState = app.staticTexts["external-input-other-field-state"]
        XCTAssertEqual(original.value as? String ?? "", "")
        original.tap()
        try requireExtension()
        let first = try japanese50OnKey("gojuon-0-10", label: "あ")
        first.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "marked=true;"),
                    evaluatedWith: originalState)
        waitForExpectations(timeout: 5)

        other.tap()
        try requireExtension()
        let reading = app.staticTexts["compositionReading"]
        let extensionTrace = reading.value as? String ?? "<missing debug trace>"
        let hostTrace = app.staticTexts["external-input-lifecycle-state"].label
        XCTAssertEqual(other.value as? String, "別",
                       "An active marked reading must not follow focus to another field; new=\(otherState.label), old=\(originalState.label), extension=\(extensionTrace), host=\(hostTrace)")
        XCTAssertTrue(originalState.label.contains("content=first;marked=false;"),
                      "The old field should retain the reading as committed text; old=\(originalState.label), extension=\(extensionTrace), host=\(hostTrace)")
    }

    func testHiddenCompositionDoesNotTransferToDifferentHostContext() throws {
        let original = app.textFields["external-input-field"]
        XCTAssertEqual(original.value as? String ?? "", "",
                       "The external input host must start with an empty original field")
        original.tap()
        try requireExtension()
        XCTAssertEqual(original.value as? String ?? "", "",
                       "A previous extension composition must not be restored into a freshly focused host before a key is pressed")
        let first = try japanese50OnKey("gojuon-0-10", label: "あ")
        first.tap()
        expectation(for: NSPredicate(format: "value == %@", "あ"), evaluatedWith: original)
        waitForExpectations(timeout: 5)
        let originalState = app.staticTexts["external-input-field-state"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "marked=true;"),
                    evaluatedWith: originalState)
        waitForExpectations(timeout: 5)
        let reading = app.staticTexts["compositionReading"]
        let hostLifecycleTrace = app.staticTexts["external-input-lifecycle-state"]
        let traceBeforeHide = reading.value as? String ?? ""
        let traceBaseline = try XCTUnwrap(compositionTraceEvents(in: traceBeforeHide).last,
                                         "The extension must publish a sequenced trace before Home.")

        XCUIDevice.shared.press(.home)
        let hostStateImmediatelyAfterHide = originalState.label
        let hostTraceImmediatelyAfterHide = app.staticTexts["external-input-lifecycle-state"].label
        let extensionTraceImmediatelyAfterHide = reading.value as? String ?? "<missing debug trace>"
        let hideBoundaryUptime = try XCTUnwrap(
            hostLifecycleEventUptime(named: "will-resign-active", in: hostTraceImmediatelyAfterHide),
            "The host lifecycle trace must timestamp the Home transition."
        )
        XCTAssertEqual(original.value as? String, "あ",
                       "The host must retain the composing characters immediately after Home; state=\(hostStateImmediatelyAfterHide), host=\(hostTraceImmediatelyAfterHide), extension=\(extensionTraceImmediatelyAfterHide)")
        XCTAssertTrue(hostStateImmediatelyAfterHide.contains("content=first;marked=false;"),
                      "Home must finalize the owned mark at the hide boundary while retaining its text; state=\(hostStateImmediatelyAfterHide), host=\(hostTraceImmediatelyAfterHide), extension=\(extensionTraceImmediatelyAfterHide)")

        app.activate()
        try requireExtension()
        let activeHostUptime = try XCTUnwrap(
            waitForHostLifecycleEvent(named: "did-become-active", laterThan: hideBoundaryUptime,
                                      in: hostLifecycleTrace),
            "The host must record a fresh did-become-active event after app.activate(). Trace=\(hostLifecycleTrace.label)"
        )
        let resumeDeadline = Date().addingTimeInterval(5)
        var extensionTraceAfterReturn = reading.value as? String ?? "<missing debug trace>"
        var freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                    laterThan: activeHostUptime, in: extensionTraceAfterReturn)
        while Date() < resumeDeadline && freshReady == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            extensionTraceAfterReturn = reading.value as? String ?? "<missing debug trace>"
            freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                   laterThan: activeHostUptime, in: extensionTraceAfterReturn)
        }
        let hostTraceAfterReturn = hostLifecycleTrace.label
        XCTAssertNotNil(freshReady,
                        "The appearance-ready event must be newer than did-become-active and the pre-Home trace baseline; Home uptime=\(hideBoundaryUptime), active uptime=\(activeHostUptime), baseline=\(traceBaseline), trace=\(extensionTraceAfterReturn)")
        XCTAssertTrue(originalState.label.contains("content=first;marked=false;"),
                      "Hiding must commit the owned mark while retaining its text: field=\(originalState.label), value=\(original.value ?? "<nil>"), host=\(hostTraceAfterReturn), extension=\(extensionTraceAfterReturn)")

        XCTAssertEqual(original.value as? String, "あ",
                       "The original host field must still retain its committed reading after activation returns")

        // A fresh key after reentry starts in the current editor and appends to
        // the text committed by the hide lifecycle.
        let returnedKey = try japanese50OnKey("gojuon-1-10", label: "い")
        returnedKey.tap()
        expectation(for: NSPredicate(format: "value == %@", "あい"), evaluatedWith: original)
        waitForExpectations(timeout: 5)
        let enter = try XCTUnwrap(key(["gojuon-enter", "tenkey-enter", "sumire-enter_key"]))
        enter.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "content=both;marked=false;"),
                    evaluatedWith: originalState)
        waitForExpectations(timeout: 5)

        // Move focus to a field with different surrounding text. No old mark
        // remains to follow the focus.
        let other = app.textFields["external-input-other-field"]
        let otherState = app.staticTexts["external-input-other-field-state"]
        XCTAssertEqual(other.value as? String, "別",
                       "The second host field must be unchanged before focus moves to it")
        other.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let compositionTrace = reading.value as? String ?? "<missing debug trace>"
        let hostTraceAfterFocusChange = hostLifecycleTrace.label
        XCTAssertEqual(other.value as? String, "別",
                       "Changing host focus must not transfer the first field's marked reading; state=\(otherState.label), trace=\(compositionTrace), host=\(hostTraceAfterFocusChange)")
        XCTAssertTrue(originalState.label.contains("content=both;marked=false;"),
                      "The previous host keeps its text committed after focus changes: \(originalState.label), host=\(hostTraceAfterFocusChange)")
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Sumire"), evaluatedWith: reading)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(other.value as? String, "別")

        let second = try japanese50OnKey("gojuon-1-10", label: "い")
        second.tap()
        expectation(for: NSPredicate(format: "value == %@", "別い"), evaluatedWith: other)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(other.value as? String, "別い")
        XCTAssertEqual(original.value as? String, "あい")
    }

    func testHiddenCompositionDoesNotTransferToIdenticalHostTextContext() throws {
        app.terminate()
        app.launchArguments = ["--identical-context-owner"]
        app.launch()

        let original = app.textFields["external-input-field"]
        XCTAssertEqual(original.value as? String, "あ",
                       "This fixture starts both host fields with the same committed prefix")
        original.tap()
        try requireExtension()
        let originalState = app.staticTexts["external-input-field-state"]
        let first = try japanese50OnKey("gojuon-1-10", label: "い")
        first.tap()
        expectation(for: NSPredicate(format: "value == %@", "あい"), evaluatedWith: original)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "content=both;marked=true;"),
                    evaluatedWith: originalState)
        waitForExpectations(timeout: 5)
        let reading = app.staticTexts["compositionReading"]
        let hostLifecycleTrace = app.staticTexts["external-input-lifecycle-state"]
        let traceBeforeHide = reading.value as? String ?? ""
        let traceBaseline = try XCTUnwrap(compositionTraceEvents(in: traceBeforeHide).last,
                                         "The extension must publish a sequenced trace before Home.")

        XCUIDevice.shared.press(.home)
        let hostStateImmediatelyAfterHide = originalState.label
        let hostTraceImmediatelyAfterHide = app.staticTexts["external-input-lifecycle-state"].label
        let extensionTraceImmediatelyAfterHide = reading.value as? String ?? "<missing debug trace>"
        let hideBoundaryUptime = try XCTUnwrap(
            hostLifecycleEventUptime(named: "will-resign-active", in: hostTraceImmediatelyAfterHide),
            "The host lifecycle trace must timestamp the Home transition."
        )
        XCTAssertEqual(original.value as? String, "あい",
                       "The original reading must remain in the host when the app is hidden; host=\(hostTraceImmediatelyAfterHide), extension=\(extensionTraceImmediatelyAfterHide)")
        XCTAssertTrue(hostStateImmediatelyAfterHide.contains("content=both;marked=false;"),
                      "Home must finalize the owned mark at the hide boundary while retaining its text; state=\(hostStateImmediatelyAfterHide), host=\(hostTraceImmediatelyAfterHide), extension=\(extensionTraceImmediatelyAfterHide)")
        app.activate()
        try requireExtension()
        let activeHostUptime = try XCTUnwrap(
            waitForHostLifecycleEvent(named: "did-become-active", laterThan: hideBoundaryUptime,
                                      in: hostLifecycleTrace),
            "The host must record a fresh did-become-active event after app.activate(). Trace=\(hostLifecycleTrace.label)"
        )

        // This field has the same surrounding text and selection as the owner,
        // but it is a different UITextField. Focus it as a user would after
        // returning to the host; a focus callback must invalidate the suspended
        // composition before a new key can write into this field.
        let matchingContext = app.textFields["external-input-matching-context-field"]
        let matchingState = app.staticTexts["external-input-matching-context-field-state"]
        let resumeDeadline = Date().addingTimeInterval(5)
        var appearanceTrace = reading.value as? String ?? "<missing debug trace>"
        var freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                    laterThan: activeHostUptime, in: appearanceTrace)
        while Date() < resumeDeadline && freshReady == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            appearanceTrace = reading.value as? String ?? "<missing debug trace>"
            freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                   laterThan: activeHostUptime, in: appearanceTrace)
        }
        XCTAssertNotNil(freshReady,
                        "The appearance-ready event must be newer than did-become-active and the pre-Home trace baseline; Home uptime=\(hideBoundaryUptime), active uptime=\(activeHostUptime), baseline=\(traceBaseline), trace=\(appearanceTrace)")
        XCTAssertEqual(original.value as? String, "あい",
                       "Returning to the host must not lose the original reading")
        XCTAssertTrue(originalState.label.contains("content=both;marked=false;"),
                      "The same host editor must retain its text as committed after hide: \(originalState.label)")
        XCTAssertTrue(appearanceTrace.contains("hostReplay=false"),
                      "A finalized hide must not reattach an old host mark: \(appearanceTrace)")
        XCTAssertEqual(matchingContext.value as? String, "あ")
        XCTAssertTrue(matchingState.label.contains("content=first;marked=false;"),
                      "The matching-context field must begin as committed text: \(matchingState.label)")
        try requireExtension()
        matchingContext.tap()
        try requireExtension()
        let traceAfterFocusChange = reading.value as? String ?? "<missing debug trace>"
        let hostTraceAfterMatchingContextFocus = hostLifecycleTrace.label
        XCTAssertTrue(originalState.label.contains("content=both;marked=false;"),
                      "The original field must retain committed text after focus moves: \(originalState.label), host=\(hostTraceAfterMatchingContextFocus)")

        let focusDeadline = Date().addingTimeInterval(5)
        while Date() < focusDeadline && !matchingState.label.contains("firstResponder=true") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(matchingState.label.contains("firstResponder=true"),
                      "The matching field must own focus before the next key: \(matchingState.label)")

        let deadline = Date().addingTimeInterval(5)
        var staleMarkTransferred = false
        while Date() < deadline {
            if matchingState.label.contains("marked=true;") {
                staleMarkTransferred = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(staleMarkTransferred,
                       "A composition from the original field must not become a mark in a different field with identical text context; state=\(matchingState.label)")
        XCTAssertEqual(matchingContext.value as? String, "あ")

        guard let second = key(["gojuon-2-10"]), second.label == "う" else {
            throw XCTSkip("The Sumire keyboard changed layout after focus moved.")
        }
        second.tap()
        expectation(for: NSPredicate(format: "value == %@", "あう"), evaluatedWith: matchingContext)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "content=other;marked=true;markedUTF16=1;"),
                    evaluatedWith: matchingState)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(matchingState.label.contains("content=other;marked=true;markedUTF16=1;selectionUTF16=2"),
                      "The new field must receive only the new key's composition: \(matchingState.label); reading=\(reading.label)")
        let trace = reading.value as? String ?? "<missing debug trace>"
        XCTAssertTrue(originalState.label.contains("content=both;"),
                      "Changing host fields must preserve the original owner's text instead of transferring it: \(originalState.label); trace=\(trace)")
        XCTAssertEqual(original.value as? String, "あい",
                       "The old field must not lose its marked characters when focus changes: \(originalState.label); trace=\(trace)")
    }
}
