#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

/// Production custom-key callback dispatch, not direct invocation of the action helper.
/// Expected marker semantics follow pinned Android df1f383 IMEService InputText.
@MainActor
final class CustomInputTextActionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let domain = "custom-input-text-" + UUID().uuidString
        let defaults: UserDefaults
        let surface = Sumire.KeyboardSurface()
        var reading = ""
        var inserted = ""
        var selection = NSRange(location: 0, length: 0)
        var rawParts: [(left: String, tail: String)] = []
        init(actions: [(String, String)], direct: Bool = false, romaji: Bool = false, flickToggle: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            var editor = CustomLayoutEditor(name: "InputText fixture", rows: 1, columns: actions.count)
            editor.setInputMode(romaji: romaji, direct: direct)
            for (index, item) in actions.enumerated() {
                editor.putKey(id: item.0, label: item.0, action: item.1, special: true,
                              row: 0, column: index * 2, height: 2, width: 2)
            }
            if flickToggle {
                try editor.setKeyType(id: "toggle", type: "STANDARD_FLICK")
                try editor.setGestureMappings(id: "toggle", field: "flicks", mappings: [
                    .object(["flickDirection": .string("UP"), "actionType": .string("TOGGLE_CASE")])
                ])
            }
            var library = CustomKeyboardLibrary()
            try library.append([editor.validated()])
            library.activeID = try XCTUnwrap(library.layouts().first?.id)
            try library.save(defaults: defaults)
            let id = "custom:" + (try XCTUnwrap(library.activeID))
            try KeyboardSelection(ids: [id]).save(defaults: defaults)
            defaults.set(id, forKey: "keyboard.lastUsed")
            surface.settingsDefaults = defaults
            surface.updateMarkedText = { [weak self] in self?.reading = $0 }
            surface.updateMarkedSelection = { [weak self] text, selection in self?.reading = text; self?.selection = selection }
            surface.insert = { [weak self] in self?.inserted += $0 }
            surface.commitMarkedText = { [weak self] text in
                self?.inserted += text
                self?.reading = ""
            }
            surface.finishMarkedText = { [weak self] in
                guard let self else { return }
                self.inserted += self.reading
                self.reading = ""
            }
            surface.commitRawTextAndSpace = { [weak self] left, tail in
                self?.rawParts.append((left, tail))
                self?.inserted += left + " " + tail
                self?.reading = ""
            }
            surface.reloadCustomLayouts()
            surface.reloadRomaji()
            surface.reloadAppearance()
        }
        deinit { defaults.removePersistentDomain(forName: domain) }
        func tap(_ id: String) throws {
            let key = try XCTUnwrap(descendants(surface).first {
                $0.accessibilityIdentifier == "custom-" + id
            } as? Sumire.RepeatingKey)
            XCTAssertTrue(key.isEnabled)
            let callback = try XCTUnwrap(key.onCommittedPress)
            callback(true)
        }
        func numberFlick(_ id: String, _ direction: MultiFlickDirection) throws {
            let key = try XCTUnwrap(find("custom-" + id) as? Sumire.MultiStageFlickKey)
            let callback = try XCTUnwrap(key.onCommit)
            callback(.init(output: .text(""), isTap: direction == .tap, wasFlick: direction != .tap,
                           isLongPress: false, direction: direction, secondDirection: nil, circularSlot: nil))
        }
        func find(_ id: String) -> UIView? { descendants(surface).first { $0.accessibilityIdentifier == id } }
        func contains(_ id: String) -> Bool {
            descendants(surface).contains { $0.accessibilityIdentifier == id }
        }
        private func descendants(_ view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
    }

    func testNextCustomTabResetsShiftEvenWhenOnlyOneLayoutExists() throws {
        for (arm, expected) in [("shift", "ON"), ("caps", "Caps Lock")] {
            let fixture = try Fixture(actions: [("word", "Text:あ👩‍💻い"), ("left", "MoveCursorLeft"),
                ("shift", "ShiftKey"), ("caps", "CapLockKey"), ("next", "MoveCustomKeyboardTab"), ("a", "Text:a")])
            let lastUsed = fixture.defaults.string(forKey: "keyboard.lastUsed")
            try fixture.tap("word"); try fixture.tap("left"); try fixture.tap(arm)
            XCTAssertEqual(fixture.find("custom-" + arm)?.accessibilityValue, expected)
            let selection = fixture.selection
            try fixture.tap("next")
            XCTAssertEqual(fixture.find("custom-shift")?.accessibilityValue, "OFF")
            XCTAssertEqual(fixture.find("custom-caps")?.accessibilityValue, "OFF")
            XCTAssertEqual(fixture.reading, "あ👩‍💻い")
            XCTAssertEqual(fixture.selection, selection)
            XCTAssertEqual(fixture.defaults.string(forKey: "keyboard.lastUsed"), lastUsed)
            try fixture.tap("a")
            XCTAssertEqual(fixture.reading, "あ👩‍💻aい")
            XCTAssertEqual(fixture.inserted, "")
        }
    }

    func testCustomShiftConsumesTextButNotCommandsOrInputTextWithoutRebuilding() throws {
        let fixture = try Fixture(actions: [("shift", "ShiftKey"), ("a", "Text:a"),
            ("punct", "InputText:-"), ("noop", "DoNothing"), ("empty", "Text:")])
        let original = try XCTUnwrap(fixture.find("custom-shift"))
        try fixture.tap("shift")
        XCTAssertEqual(original.accessibilityValue, "ON")
        try fixture.tap("noop"); try fixture.tap("punct"); try fixture.tap("empty")
        XCTAssertEqual(original.accessibilityValue, "ON")
        try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "-A")
        XCTAssertEqual(original.accessibilityValue, "OFF")
        XCTAssertTrue(fixture.find("custom-shift") === original)
        try fixture.tap("a"); XCTAssertEqual(fixture.reading, "-Aa")
    }
    func testCustomCapsLockDirectTextIsAsciiOnlyAndTogglesOff() throws {
        let fixture = try Fixture(actions: [("caps", "CapLockKey"), ("text", "Text:aßéあ"),
            ("shift", "ShiftKey")], direct: true)
        try fixture.tap("caps"); try fixture.tap("text"); try fixture.tap("text")
        XCTAssertEqual(fixture.inserted, "AßéあAßéあ")
        XCTAssertEqual(fixture.find("custom-caps")?.accessibilityValue, "Caps Lock")
        try fixture.tap("shift"); try fixture.tap("text")
        XCTAssertEqual(fixture.inserted, "AßéあAßéあaßéあ")
    }
    func testDefaultRomajiShiftSingleUnitUppercasesPrefixAndPreservesTail() throws {
        let fixture = try Fixture(actions: [("tail", "Text:あい"), ("left", "MoveCursorLeft"),
            ("k", "Text:k"), ("a", "Text:a"), ("shift", "ShiftKey")], romaji: true)
        try fixture.tap("tail"); try fixture.tap("left"); try fixture.tap("k")
        XCTAssertEqual(fixture.reading, "あkい")
        try fixture.tap("shift"); try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "あKAい")
        XCTAssertEqual(fixture.selection.location, "あKA".utf16.count)
        XCTAssertEqual(fixture.find("custom-shift")?.accessibilityValue, "OFF")
    }
    func testDefaultRomajiShiftMultiUnitConvertsShiftedText() throws {
        let fixture = try Fixture(actions: [("shift", "ShiftKey"), ("ka", "Text:ka")], romaji: true)
        try fixture.tap("shift"); try fixture.tap("ka")
        XCTAssertEqual(fixture.reading, "KA")
        XCTAssertEqual(fixture.find("custom-shift")?.accessibilityValue, "OFF")
    }

    func testCustomRomajiSingleUnitConvertsThenAppliesShift() throws {
        let fixture = try Fixture(actions: [("shift", "ShiftKey"), ("a", "Text:a")], romaji: true)
        var library = RomajiLibrary()
        let profile = RomajiProfile(name: "Shift fixture", rules: ["a": RomajiRule("x", 1)])
        library.profiles = [profile]; library.activeID = profile.id
        try library.save(defaults: fixture.defaults); fixture.surface.reloadRomaji()
        try fixture.tap("shift"); try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "X")
        XCTAssertEqual(fixture.find("custom-shift")?.accessibilityValue, "OFF")
    }

    func testCanonicalShiftPromotesSecondTapToCapsWithoutReplacingControls() async throws {
        let fixture = try Fixture(actions: [("shift", "ShiftKeyPressed"), ("a", "Text:a")])
        let original = try XCTUnwrap(fixture.find("custom-shift"))
        try fixture.tap("shift")
        XCTAssertEqual(original.accessibilityValue, "ON")
        try await Task.sleep(nanoseconds: 70_000_000)
        try fixture.tap("shift")
        XCTAssertEqual(original.accessibilityValue, "Caps Lock")
        XCTAssertTrue(fixture.find("custom-shift") === original)
        try fixture.tap("a"); try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "AA")
    }

    func testCustomShiftResetsOnEnglishReturnButSurvivesAppearanceRefresh() throws {
        let fixture = try Fixture(actions: [("caps", "CapLockKey"), ("a", "Text:a"),
            ("mode", "ChangeInputMode")])
        try fixture.tap("caps")
        fixture.surface.reloadAppearance()
        XCTAssertEqual(fixture.find("custom-caps")?.accessibilityValue, "Caps Lock")
        try fixture.tap("mode")
        let back = try XCTUnwrap(fixture.find("custom-input-mode-return") as? UIButton)
        back.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.find("custom-caps")?.accessibilityValue, "OFF")
        try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "a")
    }

    func testCustomCaseCommandsModifyLatinAndKanaAtCaretWithoutTouchingTail() throws {
        for command in ["a/A", "小゛゜"] {
            let fixture = try Fixture(actions: [("word", "Text:a👩‍💻い"), ("left", "MoveCursorLeft"), ("toggle", command)])
            try fixture.tap("word"); try fixture.tap("left"); try fixture.tap("left")
            try fixture.tap("toggle")
            XCTAssertEqual(fixture.reading, "A👩‍💻い")
            XCTAssertEqual(fixture.selection.location, 1)
            XCTAssertEqual(fixture.inserted, "")
            try fixture.tap("toggle"); XCTAssertEqual(fixture.reading, "a👩‍💻い")
        }
        let kana = try Fixture(actions: [("word", "Text:つ尾"), ("left", "MoveCursorLeft"), ("toggle", "a/A")])
        try kana.tap("word"); try kana.tap("left")
        for expected in ["っ尾", "づ尾", "つ尾"] {
            try kana.tap("toggle"); XCTAssertEqual(kana.reading, expected)
        }
    }
    func testCustomCaseFlickExecutesCommandAndNeverInsertsActionName() throws {
        let fixture = try Fixture(actions: [("word", "Text:z"), ("toggle", "a/A")], flickToggle: true)
        try fixture.tap("word"); try fixture.numberFlick("toggle", .up)
        XCTAssertEqual(fixture.reading, "Z")
        XCTAssertEqual(fixture.inserted, "")
    }
    func testCustomCaseNoopsAtStartDirectEditorAndUnsupportedUnicode() throws {
        let direct = try Fixture(actions: [("word", "Text:abc"), ("toggle", "a/A")], direct: true)
        try direct.tap("word"); try direct.tap("toggle")
        XCTAssertEqual(direct.inserted, "abc"); XCTAssertEqual(direct.reading, "")
        for text in ["か\u{3099}", "a\u{301}", "👩‍💻", "ア"] {
            let fixture = try Fixture(actions: [("word", "Text:" + text), ("toggle", "a/A"), ("left", "MoveCursorLeft")])
            try fixture.tap("word"); try fixture.tap("toggle")
            XCTAssertEqual(Array(fixture.reading.utf16), Array(text.utf16))
            XCTAssertEqual(fixture.inserted, "")
            try fixture.tap("left"); try fixture.tap("toggle")
            XCTAssertEqual(Array(fixture.reading.utf16), Array(text.utf16))
        }
    }

    func testCustomCaseCommandsPreservePendingShiftAndCapsLock() throws {
        for state in [("shift", "ShiftKeyPressed", "ON"), ("caps", "CapLockKey", "Caps Lock")] {
            let fixture = try Fixture(actions: [(state.0, state.1), ("word", "Text:a"), ("toggle", "a/A")])
            try fixture.tap("word")
            try fixture.tap(state.0)
            try fixture.tap("toggle")
            XCTAssertEqual(fixture.reading, "A")
            XCTAssertEqual(fixture.find("custom-" + state.0)?.accessibilityValue, state.2)
            try fixture.tap("word")
            XCTAssertEqual(fixture.reading, "AA")
            XCTAssertEqual(fixture.find("custom-" + state.0)?.accessibilityValue,
                           state.0 == "shift" ? "OFF" : "Caps Lock")
        }
    }

    func testCursorCommandsPreserveMarkedReadingAndDelegateOutsideComposition() throws {
        let fixture = try Fixture(actions: [("word", "Text:あ👩‍💻い"),
            ("left", "MoveCursorLeft"), ("right", "MoveCursorRight")])
        var left = 0, right = 0
        fixture.surface.moveCursorLeft = { left += 1 }
        fixture.surface.moveCursorRight = { right += 1 }
        try fixture.tap("right")
        XCTAssertEqual(right, 1)
        try fixture.tap("word")
        try fixture.tap("left")
        XCTAssertEqual(fixture.reading, "あ👩‍💻い")
        XCTAssertEqual(fixture.selection.location, "あ👩‍💻".utf16.count)
        try fixture.tap("right")
        XCTAssertEqual(fixture.selection.location, fixture.reading.utf16.count)
        XCTAssertEqual(left, 0)
        XCTAssertEqual(right, 1)
        XCTAssertEqual(fixture.inserted, "")
    }

    func testDeleteUntilSymbolClearsCompositionBeforeDelegatingToEditor() throws {
        let fixture = try Fixture(actions: [("word", "Text:にほんご"), ("delete", "DeleteUntilSymbol")])
        var calls = 0
        fixture.surface.deleteUntilBoundary = { calls += 1 }
        try fixture.tap("word")
        try fixture.tap("delete")
        XCTAssertEqual(fixture.reading, "")
        XCTAssertEqual(calls, 0)
        try fixture.tap("delete")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.inserted, "")
    }

    func testExplicitSymbolCommandOpensPanel() throws {
        let fixture = try Fixture(actions: [("symbols", "^_^")])
        try fixture.tap("symbols")
        XCTAssertTrue(fixture.contains("symbol-keyboard"))
        XCTAssertEqual(fixture.inserted, "")
    }

    func testCustomSpaceAndEnterCommandsFollowCompositionState() throws {
        for command in ["Convert", "ForceHalfWidthSpace", "ForceFullWidthSpace"] {
            let empty = try Fixture(actions: [("command", command)])
            try empty.tap("command")
            XCTAssertEqual(empty.inserted, command == "ForceFullWidthSpace" ? "　" : " ")
            let composing = try Fixture(actions: [("word", "Text:あ"), ("command", command)])
            try composing.tap("word"); try composing.tap("command")
            XCTAssertEqual(composing.inserted, "", command)
            XCTAssertFalse(composing.reading.isEmpty, command)
        }
        for command in ["Confirm", "ForceNewLine"] {
            let fixture = try Fixture(actions: [("word", "Text:あ"), ("command", command)])
            try fixture.tap("word"); try fixture.tap("command")
            XCTAssertEqual(fixture.inserted, "あ", command)
            XCTAssertEqual(fixture.reading, "", command)
            try fixture.tap("command")
            XCTAssertEqual(fixture.inserted, "あ\n", command)
        }
    }

    func testDirectModeUsesLiteralHalfWidthSpaceBeforeWidthPreference() throws {
        let fixture = try Fixture(actions: [("word", "Text:abc"),
            ("space", "ForceFullWidthSpace")], direct: true)
        try fixture.tap("word"); try fixture.tap("space")
        XCTAssertEqual(fixture.inserted, "abc ")
        XCTAssertEqual(fixture.reading, "")
    }

    func testCustomEnglishProxyReturnsWithoutChangingLastUsedOrComposition() throws {
        let fixture = try Fixture(actions: [("word", "Text:あ👩‍💻い"),
            ("left", "MoveCursorLeft"), ("mode", "ChangeInputMode")])
        let saved = fixture.defaults.string(forKey: "keyboard.lastUsed")
        try fixture.tap("word"); try fixture.tap("left")
        let selection = fixture.selection
        try fixture.tap("mode")
        XCTAssertTrue(fixture.contains("qwerty-character-a"))
        XCTAssertTrue(fixture.contains("custom-input-mode-return"))
        XCTAssertEqual(fixture.reading, "あ👩‍💻い")
        XCTAssertEqual(fixture.selection, selection)
        XCTAssertEqual(fixture.defaults.string(forKey: "keyboard.lastUsed"), saved)
        let button = try XCTUnwrap(fixture.find("custom-input-mode-return") as? UIButton)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.contains("custom-word"))
        XCTAssertFalse(fixture.contains("custom-input-mode-return"))
        XCTAssertEqual(fixture.reading, "あ👩‍💻い")
        XCTAssertEqual(fixture.selection, selection)
        XCTAssertEqual(fixture.inserted, "")
        XCTAssertEqual(fixture.defaults.string(forKey: "keyboard.lastUsed"), saved)
    }

    func testCustomProxyPagingAndEnglishTypingKeepReturnOwner() throws {
        let fixture = try Fixture(actions: [("mode", "ChangeInputMode")])
        let saved = fixture.defaults.string(forKey: "keyboard.lastUsed")
        try fixture.tap("mode")
        let letter = try XCTUnwrap(fixture.find("qwerty-character-a") as? Sumire.FlickKey)
        XCTAssertTrue(letter.accessibilityActivate())
        XCTAssertEqual(fixture.reading, "a")
        for _ in 0..<2 {
            let page = try XCTUnwrap(fixture.find("qwerty-page-toggle") as? UIButton)
            page.sendActions(for: .touchUpInside)
            XCTAssertTrue(fixture.contains("custom-input-mode-return"))
        }
        XCTAssertTrue(fixture.contains("qwerty-character-a"))
        XCTAssertEqual(fixture.defaults.string(forKey: "keyboard.lastUsed"), saved)
        let back = try XCTUnwrap(fixture.find("custom-input-mode-return") as? UIButton)
        back.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.contains("custom-mode"))
        XCTAssertEqual(fixture.reading, "a")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testCustomProxyRoundTripPreservesPendingRomaji() throws {
        let fixture = try Fixture(actions: [("n", "Text:n"), ("a", "Text:a"),
            ("mode", "ChangeInputMode")], romaji: true)
        try fixture.tap("n"); try fixture.tap("mode")
        let back = try XCTUnwrap(fixture.find("custom-input-mode-return") as? UIButton)
        back.sendActions(for: .touchUpInside)
        try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "な")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testRemovingProxyOwnerRecomputesConversionLanguage() throws {
        let fixture = try Fixture(actions: [("a", "Text:a"), ("mode", "ChangeInputMode")])
        try fixture.tap("a"); try fixture.tap("mode")
        var editor = CustomLayoutEditor(name: "Replacement", rows: 1, columns: 1)
        editor.putKey(id: "space", label: "space", action: "ForceFullWidthSpace", special: true,
                      row: 0, column: 0, height: 2, width: 2)
        var library = CustomKeyboardLibrary()
        try library.append([editor.validated()])
        library.activeID = try XCTUnwrap(library.layouts().first?.id)
        try library.save(defaults: fixture.defaults)
        try KeyboardSelection(ids: ["custom:" + library.activeID!]).save(defaults: fixture.defaults)
        fixture.surface.reloadCustomLayouts(); fixture.surface.reloadAppearance()
        XCTAssertFalse(fixture.contains("custom-input-mode-return"))
        try fixture.tap("space")
        XCTAssertEqual(fixture.reading, "a")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testCustomNumberProxyKeepsOwnerAndExactSixteenKeys() throws {
        let fixture = try Fixture(actions: [("number", "SwitchToNumber")])
        let saved = fixture.defaults.string(forKey: "keyboard.lastUsed")
        try fixture.tap("number")
        let ids = (0...9).map { "number-" + String($0) } +
            ["number-comma", "number-dot", "number-globe", "number-space", "number-delete", "number-enter"]
        for id in ids { XCTAssertTrue(fixture.contains("custom-" + id), id) }
        XCTAssertFalse(fixture.contains("custom-input-mode-return"))
        XCTAssertFalse(fixture.contains("keyboard-switch"), "No extra generic bottom row")
        XCTAssertEqual(fixture.defaults.string(forKey: "keyboard.lastUsed"), saved)
        try fixture.numberFlick("number-1", .tap)
        try fixture.numberFlick("number-comma", .left)
        try fixture.numberFlick("number-dot", .right)
        XCTAssertEqual(fixture.reading, "1+)")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testNumberProxyUsesOwningCustomRomajiAndDirectModes() throws {
        for direct in [false, true] {
            let fixture = try Fixture(actions: [("number", "SwitchToNumber")], direct: direct, romaji: true)
            try fixture.tap("number")
            try fixture.numberFlick("number-comma", .up)
            XCTAssertEqual(fixture.reading, direct ? "" : "ー")
            XCTAssertEqual(fixture.inserted, direct ? "-" : "")
        }
    }

    func testNumberDeleteFlickAndGlobeUseEditingCallbacks() throws {
        let fixture = try Fixture(actions: [("word", "Text:あ"), ("number", "SwitchToNumber")])
        try fixture.tap("word"); try fixture.tap("number")
        var boundaryCalls = 0, keyboardCalls = 0
        fixture.surface.deleteUntilBoundary = { boundaryCalls += 1 }
        fixture.surface.nextKeyboard = { keyboardCalls += 1 }
        try fixture.numberFlick("number-delete", .left)
        XCTAssertEqual(fixture.reading, "")
        XCTAssertEqual(boundaryCalls, 0)
        try fixture.numberFlick("number-delete", .left)
        XCTAssertEqual(boundaryCalls, 1)
        try fixture.numberFlick("number-2", .tap)
        try fixture.tap("number-globe")
        XCTAssertEqual(keyboardCalls, 1)
        XCTAssertEqual(fixture.inserted, "2")
        XCTAssertEqual(fixture.reading, "")
    }

    func testRawSpaceCommitsAtCaretAndKeepsPendingRomajiLiteral() throws {
        let middle = try Fixture(actions: [("word", "Text:あ👩‍💻い"),
            ("left", "MoveCursorLeft"), ("space", "CommitAndInsertSpace")])
        try middle.tap("word"); try middle.tap("left"); try middle.tap("space")
        XCTAssertEqual(middle.rawParts.first?.left, "あ👩‍💻")
        XCTAssertEqual(middle.rawParts.first?.tail, "い")
        XCTAssertEqual(middle.inserted, "あ👩‍💻 い")
        XCTAssertEqual(middle.reading, "")
        XCTAssertTrue(middle.surface.candidateBar.candidates.isEmpty)
        try middle.tap("space")
        XCTAssertEqual(middle.inserted, "あ👩‍💻 い ")
        let pending = try Fixture(actions: [("n", "Text:n"), ("space", "CommitAndInsertSpace")], romaji: true)
        try pending.tap("n"); try pending.tap("space")
        XCTAssertEqual(pending.inserted, "n ")
        XCTAssertEqual(pending.rawParts.first?.left, "n")
        XCTAssertEqual(pending.reading, "")
    }

    func testRawSpaceIgnoresSelectedConversionSurface() throws {
        let fixture = try Fixture(actions: [("word", "Text:にほんご"), ("convert", "Convert"),
            ("space", "CommitAndInsertSpace")])
        try fixture.tap("word")
        let ready = expectation(for: NSPredicate { _, _ in
            fixture.surface.candidateBar.candidates.contains("日本語")
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        try fixture.tap("convert")
        XCTAssertNotEqual(fixture.reading, "にほんご", "Selected preview must differ from raw reading")
        try fixture.tap("space")
        XCTAssertEqual(fixture.inserted, "にほんご ")
        XCTAssertEqual(fixture.rawParts.first?.left, "にほんご")
        XCTAssertEqual(fixture.reading, "")
        XCTAssertTrue(fixture.surface.candidateBar.candidates.isEmpty)
    }

    func testRomajiTogglePreservesPendingReadingWithoutFlushing() throws {
        let fixture = try Fixture(actions: [("n", "Text:n"), ("a", "Text:a"),
            ("toggle", "SwitchRomajiEnglish")], romaji: true)
        try fixture.tap("n"); try fixture.tap("toggle")
        XCTAssertEqual(fixture.reading, "n")
        XCTAssertEqual(fixture.inserted, "")
        try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "na")
        try fixture.tap("toggle"); try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "なあ")
    }

    func testDirectToggleFinishesCurrentPreviewWithoutRomajiFlush() throws {
        let fixture = try Fixture(actions: [("n", "Text:n"), ("x", "Text:x"),
            ("direct", "SwitchDirectMode")], romaji: true)
        try fixture.tap("n"); try fixture.tap("direct")
        XCTAssertEqual(fixture.inserted, "n")
        XCTAssertEqual(fixture.reading, "")
        try fixture.tap("x")
        XCTAssertEqual(fixture.inserted, "nx")
        try fixture.tap("direct"); try fixture.tap("n")
        XCTAssertEqual(fixture.reading, "n")
    }

    func testDirectReplacementOptInReplacesRatherThanCommitsPendingReading() throws {
        let fixture = try Fixture(actions: [("word", "Text:あ"), ("x", "Text:x"),
            ("direct", "SwitchDirectMode"), ("full", "ForceFullWidthSpace"),
            ("rawspace", "CommitAndInsertSpace")])
        fixture.defaults.set(true, forKey: CustomInputModeStore.replaceKey)
        try fixture.tap("word"); try fixture.tap("direct")
        XCTAssertEqual(fixture.reading, "あ")
        XCTAssertEqual(fixture.inserted, "")
        try fixture.tap("x")
        XCTAssertEqual(fixture.reading, "")
        XCTAssertEqual(fixture.inserted, "x")
        try fixture.tap("direct"); try fixture.tap("word"); try fixture.tap("direct"); try fixture.tap("full")
        XCTAssertEqual(fixture.inserted, "x ")
        XCTAssertEqual(fixture.reading, "")
        try fixture.tap("rawspace")
        XCTAssertEqual(fixture.inserted, "x  ")
        XCTAssertTrue(fixture.rawParts.isEmpty, "Direct space bypasses raw split commit")
    }

    func testRememberedRuntimeModeRestoresOnlyWhenEnabledAndReachesNumberProxy() throws {
        for remember in [false, true] {
            let fixture = try Fixture(actions: [("direct", "SwitchDirectMode"), ("x", "Text:x"),
                ("number", "SwitchToNumber")])
            fixture.defaults.set(remember, forKey: CustomInputModeStore.rememberKey)
            try fixture.tap("direct")
            let library = try CustomKeyboardLibrary.load(defaults: fixture.defaults)
            let owner = try XCTUnwrap(library.layouts().first)
            let stored = try CustomInputModeStore.load(defaults: fixture.defaults)
            XCTAssertEqual(stored.state(for: owner, remember: true).direct, remember)
            let next = Sumire.KeyboardSurface()
            next.settingsDefaults = fixture.defaults
            next.reloadCustomLayouts(); next.reloadAppearance()
            let saved = try XCTUnwrap(nextValue(next, id: "custom-direct"))
            XCTAssertEqual(saved, remember ? "直接入力" : "変換入力")
            try fixture.tap("number"); try fixture.numberFlick("number-1", .tap)
            XCTAssertEqual(fixture.inserted, "1")
            XCTAssertEqual(fixture.reading, "")
        }
    }
    private func nextValue(_ view: UIView, id: String) -> String? {
        if view.accessibilityIdentifier == id { return view.accessibilityValue }
        return view.subviews.compactMap { nextValue($0, id: id) }.first
    }

    func testDirectEntryThroughLayoutReloadFinishesPendingPreviewByDefault() throws {
        for replace in [false, true] {
            let fixture = try Fixture(actions: [("word", "Text:あ")])
            fixture.defaults.set(replace, forKey: CustomInputModeStore.replaceKey)
            try fixture.tap("word")
            var editor = CustomLayoutEditor(name: "Direct replacement", rows: 1, columns: 1)
            editor.setInputMode(romaji: false, direct: true)
            editor.putKey(id: "x", label: "x", action: "Text:x", special: false,
                          row: 0, column: 0, height: 2, width: 2)
            var library = CustomKeyboardLibrary(); try library.append([editor.validated()])
            library.activeID = try XCTUnwrap(library.layouts().first?.id)
            try library.save(defaults: fixture.defaults)
            try KeyboardSelection(ids: ["custom:" + library.activeID!]).save(defaults: fixture.defaults)
            fixture.surface.reloadCustomLayouts(); fixture.surface.reloadAppearance()
            XCTAssertEqual(fixture.inserted, replace ? "" : "あ")
            XCTAssertEqual(fixture.reading, replace ? "あ" : "")
            try fixture.tap("x")
            XCTAssertEqual(fixture.inserted, replace ? "x" : "あx")
            XCTAssertEqual(fixture.reading, "")
        }
    }

    func testDirectToggleUnmarksSelectedPreviewInRealTextView() throws {
        let fixture = try Fixture(actions: [("word", "Text:にほんご"), ("convert", "Convert"),
            ("direct", "SwitchDirectMode"), ("x", "Text:x")])
        let field = UITextView()
        fixture.surface.updateMarkedSelection = { [weak field] in field?.setMarkedText($0, selectedRange: $1) }
        fixture.surface.updateMarkedText = { [weak field] in field?.setMarkedText($0, selectedRange: NSRange(location: $0.utf16.count, length: 0)) }
        fixture.surface.finishMarkedText = { [weak field] in field?.unmarkText() }
        fixture.surface.insert = { [weak field] in field?.insertText($0) }
        try fixture.tap("word")
        let ready = expectation(for: NSPredicate { _, _ in
            fixture.surface.candidateBar.candidates.contains("日本語")
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        try fixture.tap("convert")
        XCTAssertEqual(field.text, "日本語")
        XCTAssertNotNil(field.markedTextRange)
        try fixture.tap("direct")
        XCTAssertEqual(field.text, "日本語")
        XCTAssertNil(field.markedTextRange)
        XCTAssertFalse(fixture.surface.hasComposition)
        try fixture.tap("x")
        XCTAssertEqual(field.text, "日本語x")
    }

    func testRestoredModeMemoryAppliesWhenLayoutDefinitionIsUnchanged() throws {
        let fixture = try Fixture(actions: [("word", "Text:あ"), ("direct", "SwitchDirectMode")])
        fixture.defaults.set(true, forKey: CustomInputModeStore.rememberKey)
        try fixture.tap("word")
        let library = try CustomKeyboardLibrary.load(defaults: fixture.defaults)
        let owner = try XCTUnwrap(library.layouts().first)
        var restored = CustomInputModeStore()
        try restored.set(state: CustomInputMode(direct: true, romaji: false), for: owner.id)
        try restored.save(defaults: fixture.defaults)
        fixture.surface.reloadCustomLayouts()
        XCTAssertEqual(fixture.inserted, "あ")
        XCTAssertEqual(fixture.reading, "")
        XCTAssertEqual(nextValue(fixture.surface, id: "custom-direct"), "直接入力")
        try CustomInputModeStore().save(defaults: fixture.defaults)
        fixture.surface.reloadCustomLayouts()
        XCTAssertEqual(nextValue(fixture.surface, id: "custom-direct"), "変換入力")
    }

    func testRestoredRomajiOffPreservesPendingLettersWithoutFlush() throws {
        let fixture = try Fixture(actions: [("n", "Text:n"), ("a", "Text:a")], romaji: true)
        fixture.defaults.set(true, forKey: CustomInputModeStore.rememberKey)
        try fixture.tap("n")
        let owner = try XCTUnwrap(CustomKeyboardLibrary.load(defaults: fixture.defaults).layouts().first)
        var restored = CustomInputModeStore()
        try restored.set(state: CustomInputMode(direct: false, romaji: false), for: owner.id)
        try restored.save(defaults: fixture.defaults)
        fixture.surface.reloadCustomLayouts()
        XCTAssertEqual(fixture.reading, "n")
        XCTAssertEqual(fixture.inserted, "")
        try fixture.tap("a")
        XCTAssertEqual(fixture.reading, "na")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testKanaMarkersModifyPriorKanaWithoutInsertingTheirNames() throws {
        let fixture = try Fixture(actions: [("ha", "Text:は"), ("a", "Text:あ"),
            ("voice", "InputText:濁点"), ("semi", "InputText:半濁点"), ("small", "InputText:ひらがな小文字")])
        try fixture.tap("voice")
        XCTAssertEqual(fixture.reading, "")
        try fixture.tap("ha")
        try fixture.tap("voice")
        XCTAssertEqual(fixture.reading, "ば")
        try fixture.tap("semi")
        XCTAssertEqual(fixture.reading, "ぱ")
        try fixture.tap("a")
        try fixture.tap("small")
        XCTAssertEqual(fixture.reading, "ぱぁ")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testFaceTokenOpensSymbolsOnlyWhenEmptyAndOtherwiseMakesSmallKana() throws {
        let empty = try Fixture(actions: [("face", "InputText:^_^")])
        try empty.tap("face")
        XCTAssertTrue(empty.contains("symbol-keyboard"))
        XCTAssertEqual(empty.reading, "")
        XCTAssertEqual(empty.inserted, "")
        let composing = try Fixture(actions: [("a", "Text:あ"), ("face", "InputText:^_^")])
        try composing.tap("a")
        try composing.tap("face")
        XCTAssertEqual(composing.reading, "ぁ")
        XCTAssertFalse(composing.contains("symbol-keyboard"))
        XCTAssertEqual(composing.inserted, "")
    }

    func testTextPayloadsStayLiteralAndPunctuationHonorsDirectMode() throws {
        for direct in [false, true] {
            let fixture = try Fixture(actions: [("literal", "Text:濁点"), ("colon", "InputText::"), ("hyphen", "InputText:-")], direct: direct)
            try fixture.tap("literal")
            try fixture.tap("colon")
            try fixture.tap("hyphen")
            XCTAssertEqual(fixture.reading, direct ? "" : "濁点:-")
            XCTAssertEqual(fixture.inserted, direct ? "濁点:-" : "")
        }
    }

    func testInputTextPunctuationBypassesRomajiConversionWithoutFlushingPendingLetters() throws {
        let literal = try Fixture(actions: [("hyphen", "InputText:-"), ("colon", "InputText::")], romaji: true)
        try literal.tap("hyphen")
        try literal.tap("colon")
        XCTAssertEqual(literal.reading, "-:")
        XCTAssertEqual(literal.inserted, "")
        let text = try Fixture(actions: [("hyphen", "Text:-")], romaji: true)
        try text.tap("hyphen")
        XCTAssertEqual(text.reading, "ー")
        for (letter, punctuation) in [("k", "-"), ("n", ":")] {
            let pending = try Fixture(actions: [("letter", "Text:" + letter), ("punctuation", "InputText:" + punctuation)], romaji: true)
            try pending.tap("letter")
            XCTAssertEqual(pending.reading, letter)
            try pending.tap("punctuation")
            XCTAssertEqual(pending.reading, letter + punctuation)
            XCTAssertEqual(pending.inserted, "")
        }
    }

}
#endif
