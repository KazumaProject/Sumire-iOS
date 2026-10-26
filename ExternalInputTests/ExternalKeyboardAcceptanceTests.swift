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
        let detail: String?
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

    private func compositionTraceLabel() -> String {
        app.staticTexts["sumire-debug-composition-trace"].label
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
                                         name: name, detail: fields["detail"])
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

    private func hostLifecycleReplacementMarkSnapshots(in trace: String)
        -> [(sequence: UInt64, uptime: TimeInterval, event: String, marked: Bool)] {
        trace.split(separator: "|", omittingEmptySubsequences: true).compactMap { rawEvent in
            let parts = rawEvent.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let header = String(parts[0])
            let headerParts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard headerParts.count == 2 else { return nil }
            let sequenceAndUptime = headerParts[0].split(separator: "@", maxSplits: 1,
                                                         omittingEmptySubsequences: false)
            guard sequenceAndUptime.count == 2,
                  let sequence = UInt64(sequenceAndUptime[0].dropFirst()),
                  let uptime = TimeInterval(String(sequenceAndUptime[1])) else { return nil }

            let body = String(parts[1])
            guard let replacementStart = body.range(of: "other="),
                  let nextEditor = body.range(of: ";matching=",
                                              range: replacementStart.upperBound..<body.endIndex) else {
                return nil
            }
            let replacementState = body[replacementStart.upperBound..<nextEditor.lowerBound]
            return (sequence, uptime, String(headerParts[1]),
                    replacementState.contains(";marked=true;"))
        }
    }

    private func hostObservedReplacementMark(in trace: String) -> Bool? {
        let prefix = "replacement-mark-observed="
        guard let marker = trace.split(separator: "|").last(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        switch marker.dropFirst(prefix.count) {
        case "true": return true
        case "false": return false
        default: return nil
        }
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

    private func waitForCompositionTraceEvent(named name: String, after baseline: CompositionTraceEvent,
                                              timeout: TimeInterval = 5) -> CompositionTraceEvent? {
        func matchingEvent(in trace: String) -> CompositionTraceEvent? {
            compositionTraceEvents(in: trace).first { event in
                event.name == name && event.uptime > baseline.uptime &&
                    event.processIdentifier == baseline.processIdentifier &&
                    event.controllerIdentifier == baseline.controllerIdentifier &&
                    event.sequence > baseline.sequence
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var trace = compositionTraceLabel()
        while Date() < deadline {
            if let event = matchingEvent(in: trace) {
                return event
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            trace = compositionTraceLabel()
        }
        return matchingEvent(in: trace)
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
        let traceBeforeMark = compositionTraceLabel()
        let eventBaseline = try XCTUnwrap(
            compositionTraceEvents(in: traceBeforeMark).last,
            "The extension must publish a sequenced trace before the marked-text write."
        )
        let first = try japanese50OnKey("gojuon-0-10", label: "あ")
        first.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "marked=true;"),
                    evaluatedWith: originalState)
        waitForExpectations(timeout: 5)

        let traceBaseline = try XCTUnwrap(
            waitForCompositionTraceEvent(named: "mark.accepted", after: eventBaseline),
            "The extension must publish a new accepted ownership event before host focus changes."
        )
        let hostLifecycleTraceElement = app.staticTexts["external-input-lifecycle-state"]
        let hostTraceBeforeSwitch = hostLifecycleTraceElement.label
        let hostEventBaselineSequence = try XCTUnwrap(
            hostLifecycleReplacementMarkSnapshots(in: hostTraceBeforeSwitch).last?.sequence,
            "The host must publish a sequenced callback snapshot before the focus-switch diagnostic."
        )
        XCTAssertEqual(hostObservedReplacementMark(in: hostTraceBeforeSwitch), false,
                       "The replacement field must not already have a callback-observed mark before focus switches: \(hostTraceBeforeSwitch)")
        let originalFocusUptime = try XCTUnwrap(
            hostLifecycleEventUptime(named: "field-begin-editing", in: hostTraceBeforeSwitch),
            "The host must record the original field entering editing before the focus-change diagnostic."
        )
        other.tap()
        try requireExtension()
        let finalizationExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "content=first;marked=false;"),
            evaluatedWith: originalState
        )
        let finalizationWaitResult = XCTWaiter.wait(for: [finalizationExpectation], timeout: 5)
        // Capture only the host's coarse state labels and the extension's
        // boolean ownership trace before assertions can stop the test. Neither
        // diagnostic surface contains the field's actual text or document IDs.
        let originalStateAfterSwitch = originalState.label
        let otherStateAfterSwitch = otherState.label
        let extensionTrace = compositionTraceLabel()
        let freshExtensionEvents = compositionTraceEvents(in: extensionTrace).filter { event in
            event.processIdentifier == traceBaseline.processIdentifier &&
                event.controllerIdentifier == traceBaseline.controllerIdentifier &&
                event.sequence > traceBaseline.sequence
        }
        let freshOwnershipEvents = freshExtensionEvents.filter { event in
            event.name == "ownership.discard" || event.name == "composition.invalidate.request" ||
                event.name.hasPrefix("owner.resolve.")
        }
        let freshDiscardReasonEvents = freshOwnershipEvents.filter { event in
            guard let detail = event.detail, detail.hasPrefix("reason=") else { return false }
            return detail != "reason=none" &&
                (event.name == "ownership.discard" || event.name == "composition.invalidate.request" ||
                    event.name.hasSuffix(".discard"))
        }
        let freshOwnershipSummary = freshOwnershipEvents.map { event in
            "\(event.sequence):\(event.name):\(event.detail ?? "na")"
        }.joined(separator: "|")
        let hostTrace = hostLifecycleTraceElement.label
        let replacementMarkObserved = hostObservedReplacementMark(in: hostTrace)
        let postSwitchHostSnapshots = hostLifecycleReplacementMarkSnapshots(in: hostTrace).filter {
            $0.sequence > hostEventBaselineSequence
        }
        let replacementMarkedSnapshots = postSwitchHostSnapshots.filter(\.marked)
        let replacementMarkedSnapshotSummary = replacementMarkedSnapshots.map {
            "\($0.sequence):\($0.event)@\($0.uptime)"
        }.joined(separator: ",")
        let otherValueAfterSwitch = other.value as? String
        let hostShouldEndUptime = hostLifecycleEventUptime(
            named: "field-should-end-editing", laterThan: originalFocusUptime, in: hostTrace
        )
        let hostShouldBeginUptime = hostLifecycleEventUptime(
            named: "field-should-begin-editing", laterThan: originalFocusUptime, in: hostTrace
        )
        let finalizationRequestUptime = freshExtensionEvents.first {
            $0.name == "mark.finalize.request"
        }?.uptime
        let finalizationReturnUptime = freshExtensionEvents.first {
            $0.name == "mark.finalize.return"
        }?.uptime
        let ownerProxyFinalizationRequest = freshExtensionEvents.first {
            $0.name == "mark.finalize.request" && $0.detail?.hasPrefix("target=marked-owner-proxy,") == true
        }
        let ownerProxyFinalizationReturn = freshExtensionEvents.first {
            $0.name == "mark.finalize.return" && $0.detail?.hasPrefix("target=marked-owner-proxy,") == true
        }
        let ownerProxyFinalizationRequestedDuringFocusSwitch = ownerProxyFinalizationRequest != nil
        let ownerProxyFinalizationReturnedDuringFocusSwitch = ownerProxyFinalizationReturn != nil

        // Persist only callback labels, monotonic timestamps, and marked-state
        // booleans. The attachment deliberately excludes editor contents and IDs.
        XCTContext.runActivity(named: "Sanitized host-extension focus callback order") { activity in
            let attachment = XCTAttachment(string: [
                "field-should-end-editing=\(hostShouldEndUptime.map { String($0) } ?? "missing")",
                "field-should-begin-editing=\(hostShouldBeginUptime.map { String($0) } ?? "missing")",
                "mark.finalize.request=\(finalizationRequestUptime.map { String($0) } ?? "missing")",
                "mark.finalize.return=\(finalizationReturnUptime.map { String($0) } ?? "missing")",
                "owner-proxy-finalization-request-during-focus-switch=\(ownerProxyFinalizationRequestedDuringFocusSwitch)",
                "owner-proxy-finalization-return-during-focus-switch=\(ownerProxyFinalizationReturnedDuringFocusSwitch)",
                "owner-proxy-request-comparison=\(ownerProxyFinalizationRequest?.detail ?? "missing")",
                "owner-proxy-return-comparison=\(ownerProxyFinalizationReturn?.detail ?? "missing")",
                "old-host-marked-after-switch=\(originalStateAfterSwitch.contains("marked=true;"))",
                "new-host-marked-after-switch=\(otherStateAfterSwitch.contains("marked=true;"))",
                "replacement-mark-observed-after-switch=\(replacementMarkObserved.map { String($0) } ?? "missing")",
                "post-switch-host-callback-snapshots=\(postSwitchHostSnapshots.count)",
                "replacement-marked-callback-snapshots=\(replacementMarkedSnapshotSummary.isEmpty ? "none" : replacementMarkedSnapshotSummary)"
            ].joined(separator: "\n"))
            attachment.name = "Focus callback timing (privacy-safe)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let previousContinueAfterFailure = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previousContinueAfterFailure }

        XCTAssertFalse(freshExtensionEvents.isEmpty,
                       "The extension published no sequenced events after focus switched; baseline=\(traceBaseline.sequence), trace=\(extensionTrace)")
        XCTAssertFalse(freshDiscardReasonEvents.isEmpty,
                      "The fresh ownership trace must identify a fixed discard/resolution reason without host text or document IDs: \(freshOwnershipSummary)")
        XCTAssertTrue(ownerProxyFinalizationRequestedDuringFocusSwitch &&
                      ownerProxyFinalizationReturnedDuringFocusSwitch,
                      "The focus-boundary callback must finalize through the retained owner proxy, not the dynamically routed current proxy: \(extensionTrace)")
        XCTAssertTrue(
            ownerProxyFinalizationRequest?.detail?.contains("ownerDocumentCurrent=") == true &&
                ownerProxyFinalizationReturn?.detail?.contains("ownerDocumentCurrent=") == true,
            "The privacy-safe owner-document comparison must be captured around finalization: \(extensionTrace)"
        )
        XCTAssertNotNil(hostShouldEndUptime,
                        "The host must capture its should-end boundary after the original field began editing: \(hostTrace)")
        XCTAssertNotNil(hostShouldBeginUptime,
                        "The host must capture its should-begin boundary for the replacement field: \(hostTrace)")
        XCTAssertTrue(replacementMarkedSnapshots.isEmpty,
                      "The replacement field must stay unmarked in every retained post-switch host callback snapshot; snapshots=\(replacementMarkedSnapshotSummary)")
        XCTAssertEqual(replacementMarkObserved, false,
                       "No host callback after the focus-switch baseline may observe a marked replacement field, even if its event ages out of the bounded trace: \(hostTrace)")
        XCTAssertEqual(otherValueAfterSwitch, "別",
                       "An active marked reading must not follow focus to another field; new=\(otherStateAfterSwitch), old=\(originalStateAfterSwitch), extension=\(extensionTrace), host=\(hostTrace)")
        XCTAssertTrue(otherStateAfterSwitch.contains("marked=false;"),
                      "The replacement field must remain unmarked after the original host composition is finalized: new=\(otherStateAfterSwitch), old=\(originalStateAfterSwitch), extension=\(extensionTrace), host=\(hostTrace)")
        XCTAssertTrue(originalStateAfterSwitch.contains("content=first;marked=false;"),
                      "The old field should retain the reading as committed text; wait=\(finalizationWaitResult), old=\(originalStateAfterSwitch), new=\(otherStateAfterSwitch), extension=\(extensionTrace), host=\(hostTrace)")
        let finalizedWithinDeadline: Bool
        if case .completed = finalizationWaitResult {
            finalizedWithinDeadline = true
        } else {
            finalizedWithinDeadline = false
        }
        XCTAssertTrue(finalizedWithinDeadline,
                      "The old field should finalize within five seconds; wait=\(finalizationWaitResult), old=\(originalStateAfterSwitch), new=\(otherStateAfterSwitch), extension=\(extensionTrace), host=\(hostTrace)")
    }

    private func privacySafeOwnerContextComparison(_ detail: String?) -> String {
        let allowlistedKeys = [
            "document", "before", "after", "selected", "baseline",
            "ownerDocumentPresent", "ownerDocumentCurrent", "ownerDocumentMatchesMark",
            "markedContextCurrent", "canFinalize"
        ]
        let metadataValues: [String: Set<String>] = [
            "lease": ["present"],
            "suspended": ["true", "false"]
        ]
        guard let detail else { return "missing" }
        guard detail.hasPrefix("target=retained-owner-proxy,") else { return "invalid" }

        var values: [String: String] = [:]
        let comparison = detail.dropFirst("target=retained-owner-proxy,".count)
        for component in comparison.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            guard let separator = component.firstIndex(of: "=") else { return "invalid" }
            let key = String(component[..<separator])
            let value = String(component[component.index(after: separator)...])
            if allowlistedKeys.contains(key) {
                guard value == "true" || value == "false" else { return "invalid" }
            } else if let acceptedValues = metadataValues[key] {
                guard acceptedValues.contains(value) else { return "invalid" }
            } else {
                return "invalid"
            }
            guard values[key] == nil else { return "invalid" }
            values[key] = value
        }

        guard values.count == allowlistedKeys.count + metadataValues.count else { return "invalid" }
        return allowlistedKeys.map { "\($0)=\(values[$0]!)" }.joined(separator: ",")
    }

    func testOwnedMarkFinalizesThroughRetainedProxyWhileHostFocusRemainsStable() throws {
        let original = app.textFields["external-input-field"]
        let originalState = app.staticTexts["external-input-field-state"]
        let hostLifecycleTraceElement = app.staticTexts["external-input-lifecycle-state"]

        original.tap()
        try requireExtension()
        let first = try japanese50OnKey("gojuon-0-10", label: "あ")
        first.tap()

        let markedExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                             "content=first;marked=true;", "firstResponder=true"),
            evaluatedWith: originalState
        )
        let markedWaitResult = XCTWaiter.wait(for: [markedExpectation], timeout: 5)
        let markedStateReady = originalState.label.contains("content=first;marked=true;") &&
            originalState.label.contains("firstResponder=true")
        let markedWaitCompleted: Bool
        if case .completed = markedWaitResult {
            markedWaitCompleted = true
        } else {
            markedWaitCompleted = false
        }
        XCTAssertTrue(markedStateReady,
                      "The original field must own a mark before retained-proxy finalization: \(originalState.label)")

        let hostTraceBefore = hostLifecycleTraceElement.label
        let originalFocusUptime = try XCTUnwrap(
            hostLifecycleEventUptime(named: "field-begin-editing", in: hostTraceBefore),
            "The host must record the original field entering editing before the diagnostic."
        )
        let traceBefore = compositionTraceLabel()
        let traceBaseline = try XCTUnwrap(
            compositionTraceEvents(in: traceBefore).last,
            "The extension must publish a sequenced trace before retained-proxy finalization."
        )

        let finishButton = app.buttons["sumire-debug-finish-retained-owner-marked-text"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5),
                      "The DEBUG-only retained-owner finalization control must be visible.")
        XCTAssertTrue(finishButton.isHittable,
                      "The retained-owner control must be hittable without switching host fields.")

        let previousContinueAfterFailure = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previousContinueAfterFailure }

        finishButton.tap()
        let finalizedExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                             "content=first;marked=false;", "firstResponder=true"),
            evaluatedWith: originalState
        )
        let finalizationWaitResult = XCTWaiter.wait(for: [finalizedExpectation], timeout: 5)

        let originalStateAfter = originalState.label
        let extensionTrace = compositionTraceLabel()
        let freshEvents = compositionTraceEvents(in: extensionTrace).filter { event in
            event.processIdentifier == traceBaseline.processIdentifier &&
                event.controllerIdentifier == traceBaseline.controllerIdentifier &&
                event.sequence > traceBaseline.sequence
        }
        let hostTraceAfter = hostLifecycleTraceElement.label
        let hostShouldEnd = hostLifecycleEventUptime(
            named: "field-should-end-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostDidEnd = hostLifecycleEventUptime(
            named: "field-end-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostShouldBegin = hostLifecycleEventUptime(
            named: "field-should-begin-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostDidBegin = hostLifecycleEventUptime(
            named: "field-begin-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let ownerRequest = freshEvents.first {
            $0.name == "mark.finalize.request" &&
                $0.detail?.hasPrefix("target=retained-owner-proxy,") == true
        }
        let ownerReturn = freshEvents.first {
            $0.name == "mark.finalize.return" &&
                $0.detail?.hasPrefix("target=retained-owner-proxy,") == true
        }
        let diagnosticAccepted = freshEvents.contains {
            $0.name == "debug.stable-owner.finalization-return"
        }
        let diagnosticRejected = freshEvents.contains {
            $0.name == "debug.stable-owner.finalization-rejected"
        }
        let hostContentPreserved = originalStateAfter.contains("content=first;")
        let hostCompositionCleared = originalStateAfter.contains("marked=false;")
        let hostStillFirstResponder = originalStateAfter.contains("firstResponder=true")
        let hostStillMarked = originalStateAfter.contains("marked=true;")
        let finalizationWaitCompleted: Bool
        if case .completed = finalizationWaitResult {
            finalizationWaitCompleted = true
        } else {
            finalizationWaitCompleted = false
        }
        let requestUptime = ownerRequest?.uptime
        let returnUptime = ownerReturn?.uptime
        let ownerRequestComparison = privacySafeOwnerContextComparison(ownerRequest?.detail)
        let ownerReturnComparison = privacySafeOwnerContextComparison(ownerReturn?.detail)

        XCTContext.runActivity(named: "Sanitized retained-owner stable-focus result") { activity in
            let attachment = XCTAttachment(string: [
                "marked-state-ready=\(markedStateReady)",
                "marked-wait-completed=\(markedWaitCompleted)",
                "owner-proxy-request=\(ownerRequest != nil)",
                "owner-proxy-return=\(ownerReturn != nil)",
                "owner-proxy-request-comparison=\(ownerRequestComparison)",
                "owner-proxy-return-comparison=\(ownerReturnComparison)",
                "diagnostic-accepted=\(diagnosticAccepted)",
                "diagnostic-rejected=\(diagnosticRejected)",
                "host-content-preserved=\(hostContentPreserved)",
                "host-composition-cleared=\(hostCompositionCleared)",
                "host-still-marked=\(hostStillMarked)",
                "host-still-first-responder=\(hostStillFirstResponder)",
                "field-should-end-after-baseline=\(hostShouldEnd.map { String($0) } ?? "missing")",
                "field-did-end-after-baseline=\(hostDidEnd.map { String($0) } ?? "missing")",
                "field-should-begin-after-baseline=\(hostShouldBegin.map { String($0) } ?? "missing")",
                "field-did-begin-after-baseline=\(hostDidBegin.map { String($0) } ?? "missing")",
                "owner-proxy-request-uptime=\(requestUptime.map { String($0) } ?? "missing")",
                "owner-proxy-return-uptime=\(returnUptime.map { String($0) } ?? "missing")",
                "finalization-wait-completed=\(finalizationWaitCompleted)"
            ].joined(separator: "\n"))
            attachment.name = "Retained-owner stable-focus finalization (privacy-safe)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertNotNil(ownerRequest,
                        "The stable-focus control must request unmark through the retained owner proxy: \(extensionTrace)")
        XCTAssertNotNil(ownerReturn,
                        "The retained owner proxy call must return before interpreting host state: \(extensionTrace)")
        XCTAssertTrue(ownerRequest?.detail?.contains("ownerDocumentCurrent=") == true &&
                      ownerReturn?.detail?.contains("ownerDocumentCurrent=") == true,
                      "The diagnostic must retain only boolean owner-context comparisons: \(extensionTrace)")
        XCTAssertFalse(["missing", "invalid"].contains(ownerRequestComparison) ||
                       ["missing", "invalid"].contains(ownerReturnComparison),
                       "The stable-focus attachment must contain only the complete allowlisted boolean comparisons.")
        XCTAssertTrue(diagnosticAccepted,
                      "The extension must accept the guarded retained-owner diagnostic: \(extensionTrace)")
        XCTAssertFalse(diagnosticRejected,
                       "The extension must not reject the stable same-field control: \(extensionTrace)")
        XCTAssertNil(hostShouldEnd, "Stable-focus finalization must not start host focus handoff: \(hostTraceAfter)")
        XCTAssertNil(hostDidEnd, "Stable-focus finalization must not end host editing: \(hostTraceAfter)")
        XCTAssertNil(hostShouldBegin, "Stable-focus finalization must not begin another host field: \(hostTraceAfter)")
        XCTAssertNil(hostDidBegin, "Stable-focus finalization must not begin another host field: \(hostTraceAfter)")
        XCTAssertTrue(hostContentPreserved,
                      "The same field must retain its content class: \(originalStateAfter)")
        XCTAssertTrue(hostCompositionCleared,
                      "The same field's marked range must be cleared: \(originalStateAfter)")
        XCTAssertTrue(hostStillFirstResponder,
                      "The same field must remain first responder: \(originalStateAfter)")
        XCTAssertFalse(hostStillMarked,
                       "The same field must no longer have a marked range: \(originalStateAfter)")
        XCTAssertTrue(finalizationWaitCompleted,
                      "The same field must report committed text within five seconds: \(originalStateAfter)")
    }

    func testOwnedMarkFinalizesWhileHostFocusRemainsStable() throws {
        let original = app.textFields["external-input-field"]
        let originalState = app.staticTexts["external-input-field-state"]
        let hostLifecycleTraceElement = app.staticTexts["external-input-lifecycle-state"]

        original.tap()
        try requireExtension()
        let first = try japanese50OnKey("gojuon-0-10", label: "あ")
        first.tap()

        let markedExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                             "content=first;marked=true;", "firstResponder=true"),
            evaluatedWith: originalState
        )
        let markedWaitResult = XCTWaiter.wait(for: [markedExpectation], timeout: 5)
        let markedStateReady = originalState.label.contains("content=first;marked=true;") &&
            originalState.label.contains("firstResponder=true")
        let markedWaitCompleted: Bool
        if case .completed = markedWaitResult {
            markedWaitCompleted = true
        } else {
            markedWaitCompleted = false
        }
        XCTAssertTrue(markedStateReady,
                      "The original field must own a marked composition before the stable-focus diagnostic: \(originalState.label)")

        let hostTraceBefore = hostLifecycleTraceElement.label
        let originalFocusUptime = try XCTUnwrap(
            hostLifecycleEventUptime(named: "field-begin-editing", in: hostTraceBefore),
            "The host must record the original field entering editing before the diagnostic."
        )
        let traceBefore = compositionTraceLabel()
        let traceBaseline = try XCTUnwrap(
            compositionTraceEvents(in: traceBefore).last,
            "The extension must publish a sequenced trace before stable-focus finalization."
        )

        let finishButton = app.buttons["sumire-debug-finish-marked-text"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5),
                      "The DEBUG-only control for the existing extension finalization closure must be visible.")
        XCTAssertTrue(finishButton.isHittable,
                      "The DEBUG-only finalization control must be hittable without switching host fields.")

        let previousContinueAfterFailure = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previousContinueAfterFailure }

        finishButton.tap()
        let finalizedExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                             "content=first;marked=false;", "firstResponder=true"),
            evaluatedWith: originalState
        )
        let finalizationWaitResult = XCTWaiter.wait(for: [finalizedExpectation], timeout: 5)

        // Retain only fixed event names, times, and coarse host-state booleans.
        let originalStateAfter = originalState.label
        let extensionTrace = compositionTraceLabel()
        let freshEvents = compositionTraceEvents(in: extensionTrace).filter { event in
            event.processIdentifier == traceBaseline.processIdentifier &&
                event.controllerIdentifier == traceBaseline.controllerIdentifier &&
                event.sequence > traceBaseline.sequence
        }
        let hostTraceAfter = hostLifecycleTraceElement.label
        let hostShouldEnd = hostLifecycleEventUptime(
            named: "field-should-end-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostDidEnd = hostLifecycleEventUptime(
            named: "field-end-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostShouldBegin = hostLifecycleEventUptime(
            named: "field-should-begin-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let hostDidBegin = hostLifecycleEventUptime(
            named: "field-begin-editing", laterThan: originalFocusUptime, in: hostTraceAfter
        )
        let finalizationRequested = freshEvents.contains { $0.name == "mark.finalize.request" }
        let finalizationReturned = freshEvents.contains { $0.name == "mark.finalize.return" }
        let diagnosticAccepted = freshEvents.contains {
            $0.name == "debug.stable-focus.finalization-return"
        }
        let diagnosticRejected = freshEvents.contains {
            $0.name == "debug.stable-focus.finalization-rejected"
        }
        let hostStateStillMarked = originalStateAfter.contains("marked=true;")
        let hostCompositionCleared = originalStateAfter.contains("marked=false;")
        let hostContentPreserved = originalStateAfter.contains("content=first;")
        let hostStillFirstResponder = originalStateAfter.contains("firstResponder=true")
        let finalizationWaitCompleted: Bool
        if case .completed = finalizationWaitResult {
            finalizationWaitCompleted = true
        } else {
            finalizationWaitCompleted = false
        }
        let finalizationRequestUptime = freshEvents.first {
            $0.name == "mark.finalize.request"
        }?.uptime
        let finalizationReturnUptime = freshEvents.first {
            $0.name == "mark.finalize.return"
        }?.uptime

        XCTContext.runActivity(named: "Sanitized stable-focus finalization result") { activity in
            let attachment = XCTAttachment(string: [
                "marked-state-ready=\(markedStateReady)",
                "marked-wait-completed=\(markedWaitCompleted)",
                "marked-wait=\(String(describing: markedWaitResult))",
                "proxy-finalization-request=\(finalizationRequested)",
                "proxy-finalization-return=\(finalizationReturned)",
                "diagnostic-accepted=\(diagnosticAccepted)",
                "diagnostic-rejected=\(diagnosticRejected)",
                "host-content-preserved=\(hostContentPreserved)",
                "host-composition-cleared=\(hostCompositionCleared)",
                "host-still-marked=\(hostStateStillMarked)",
                "host-still-first-responder=\(hostStillFirstResponder)",
                "field-should-end-after-baseline=\(hostShouldEnd.map { String($0) } ?? "missing")",
                "field-did-end-after-baseline=\(hostDidEnd.map { String($0) } ?? "missing")",
                "field-should-begin-after-baseline=\(hostShouldBegin.map { String($0) } ?? "missing")",
                "field-did-begin-after-baseline=\(hostDidBegin.map { String($0) } ?? "missing")",
                "mark.finalize.request-uptime=\(finalizationRequestUptime.map { String($0) } ?? "missing")",
                "mark.finalize.return-uptime=\(finalizationReturnUptime.map { String($0) } ?? "missing")",
                "finalization-wait-completed=\(finalizationWaitCompleted)",
                "finalization-wait=\(String(describing: finalizationWaitResult))"
            ].joined(separator: "\n"))
            attachment.name = "Stable-focus finalization (privacy-safe)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertTrue(finalizationRequested && finalizationReturned && diagnosticAccepted,
                      "The extension must acknowledge a fresh request and return through its existing proxy closure before this result is interpreted.")
        XCTAssertFalse(diagnosticRejected,
                       "The extension must not reject the stable-focus diagnostic preconditions.")
        XCTAssertNil(hostShouldEnd, "Stable-focus finalization must not start host focus handoff: \(hostTraceAfter)")
        XCTAssertNil(hostDidEnd, "Stable-focus finalization must not end host editing: \(hostTraceAfter)")
        XCTAssertNil(hostShouldBegin, "Stable-focus finalization must not begin another host field: \(hostTraceAfter)")
        XCTAssertNil(hostDidBegin, "Stable-focus finalization must not begin another host field: \(hostTraceAfter)")
        XCTAssertTrue(hostContentPreserved,
                      "The same host field must retain the original content class: \(originalStateAfter)")
        XCTAssertTrue(hostCompositionCleared,
                      "The same host field's marked range must be cleared: \(originalStateAfter)")
        XCTAssertTrue(hostStillFirstResponder,
                      "The same host field must remain first responder during the diagnostic: \(originalStateAfter)")
        XCTAssertTrue(finalizationWaitCompleted,
                      "The host must report committed composition within five seconds: \(originalStateAfter)")
        XCTAssertFalse(hostStateStillMarked,
                       "The existing extension unmark path should commit the mark while host focus is stable: \(originalStateAfter)")
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
        let traceBeforeHide = compositionTraceLabel()
        let traceBaseline = try XCTUnwrap(compositionTraceEvents(in: traceBeforeHide).last,
                                         "The extension must publish a sequenced trace before Home. Trace label=\(traceBeforeHide)")

        XCUIDevice.shared.press(.home)
        let hostStateImmediatelyAfterHide = originalState.label
        let hostTraceImmediatelyAfterHide = app.staticTexts["external-input-lifecycle-state"].label
        let extensionTraceImmediatelyAfterHide = compositionTraceLabel()
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
        var extensionTraceAfterReturn = compositionTraceLabel()
        var freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                    laterThan: hideBoundaryUptime, in: extensionTraceAfterReturn)
        while Date() < resumeDeadline && freshReady == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            extensionTraceAfterReturn = compositionTraceLabel()
            freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                   laterThan: hideBoundaryUptime, in: extensionTraceAfterReturn)
        }
        let hostTraceAfterReturn = hostLifecycleTrace.label
        XCTAssertNotNil(freshReady,
                        "The appearance-ready event must be newer than Home and the pre-Home trace baseline; Home uptime=\(hideBoundaryUptime), active uptime=\(activeHostUptime), baseline=\(traceBaseline), trace=\(extensionTraceAfterReturn)")
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
        let compositionTrace = compositionTraceLabel()
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
        let traceBeforeHide = compositionTraceLabel()
        let traceBaseline = try XCTUnwrap(compositionTraceEvents(in: traceBeforeHide).last,
                                         "The extension must publish a sequenced trace before Home. Trace label=\(traceBeforeHide)")

        XCUIDevice.shared.press(.home)
        let hostStateImmediatelyAfterHide = originalState.label
        let hostTraceImmediatelyAfterHide = app.staticTexts["external-input-lifecycle-state"].label
        let extensionTraceImmediatelyAfterHide = compositionTraceLabel()
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
        var appearanceTrace = compositionTraceLabel()
        var freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                    laterThan: hideBoundaryUptime, in: appearanceTrace)
        while Date() < resumeDeadline && freshReady == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            appearanceTrace = compositionTraceLabel()
            freshReady = freshCompositionTraceEvent(named: "lifecycle.did-appear.ready", after: traceBaseline,
                                                   laterThan: hideBoundaryUptime, in: appearanceTrace)
        }
        XCTAssertNotNil(freshReady,
                        "The appearance-ready event must be newer than Home and the pre-Home trace baseline; UIKit may report extension readiness before host did-become-active (\(activeHostUptime)); Home uptime=\(hideBoundaryUptime), baseline=\(traceBaseline), trace=\(appearanceTrace)")
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
        let trace = compositionTraceLabel()
        XCTAssertTrue(originalState.label.contains("content=both;"),
                      "Changing host fields must preserve the original owner's text instead of transferring it: \(originalState.label); trace=\(trace)")
        XCTAssertEqual(original.value as? String, "あい",
                       "The old field must not lose its marked characters when focus changes: \(originalState.label); trace=\(trace)")
    }
}
