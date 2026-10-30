import XCTest
@testable import SumireCore

final class CustomKeyActionTests: XCTestCase {
    func testTextAndCommandRemainDistinctAndUnknownDoesNotBecomeText() throws {
        let targets = CustomLayoutTargets(layouts: [])
        XCTAssertEqual(CustomKeyAction.tap("Text:Delete", targets: targets), .text("Delete"))
        XCTAssertEqual(CustomKeyAction.tap("InputText:🌸", targets: targets), .inputText("🌸"))
        XCTAssertEqual(CustomKeyAction.tap("Delete", targets: targets), .command(.delete))
        XCTAssertEqual(CustomKeyAction.tap("DeleteAfterCursor", targets: targets), .command(.deleteAfterCursor))
        XCTAssertEqual(CustomKeyAction.flick(type: "DELETE_AFTER_CURSOR", value: nil, targets: targets), .command(.deleteAfterCursor))
        XCTAssertEqual(CustomKeyAction.flick(type: "DELETE", value: "表示名", targets: targets), .command(.delete))
        XCTAssertEqual(CustomKeyAction.tap("MoveCustomKeyboardTab", targets: targets), .command(.moveCustomKeyboardTab))
        XCTAssertEqual(CustomKeyAction.flick(type: "MoveCustomKeyboardTab", value: "⇄", targets: targets), .command(.moveCustomKeyboardTab))
        XCTAssertEqual(CustomKeyAction.flick(type: "INPUT_TEXT", value: "Delete", targets: targets), .text("Delete"))
        if case .unsupported(let raw, _) = CustomKeyAction.tap("VoiceInput", targets: targets) { XCTAssertEqual(raw, "VoiceInput") }
        else { XCTFail("Unsupported action must not silently change behavior") }
    }
    func testImportedEditingCommandsResolveForTapAndFlick() throws {
        let targets = CustomLayoutTargets(layouts: [])
        let cases: [(String, String, CustomKeyAction.Command)] = [
            ("MoveCursorRight", "MOVE_CURSOR_RIGHT", .cursorRight),
            ("DeleteUntilSymbol", "DELETE_UNTIL_SYMBOL", .deleteUntilBoundary),
            ("ShowEmojiKeyboard", "SHOW_EMOJI_KEYBOARD", .openSymbols),
            ("SwitchToKanaLayout", "SWITCH_TO_KANA_LAYOUT", .switchKana),
            ("SwitchToEnglishLayout", "SWITCH_TO_ENGLISH_LAYOUT", .switchEnglish),
            ("SwitchToNumberLayout", "SWITCH_TO_NUMBER_LAYOUT", .switchNumber)]
        for (raw, alias, command) in cases {
            XCTAssertEqual(CustomKeyAction.tap(raw, targets: targets), .command(command))
            XCTAssertEqual(CustomKeyAction.flick(type: raw, value: nil, targets: targets), .command(command))
            XCTAssertEqual(CustomKeyAction.flick(type: alias, value: nil, targets: targets), .command(command))
        }
    }

    func testPinnedSerializedModeAndEmojiNames() {
        let targets = CustomLayoutTargets(layouts: [])
        let cases: [(String, CustomKeyAction.Command)] = [("SwitchToKana", .switchKana),
            ("SwitchToEnglish", .switchEnglish), ("SwitchToNumber", .switchNumber), ("^_^", .openSymbols)]
        for (raw, command) in cases {
            XCTAssertEqual(CustomKeyAction.tap(raw, targets: targets), .command(command))
            XCTAssertEqual(CustomKeyAction.flick(type: raw, value: nil, targets: targets), .command(command))
            XCTAssertEqual(CustomKeyAction.tap("Text:" + raw, targets: targets), .text(raw))
        }
        XCTAssertEqual(CustomKeyAction.tap("InputText:^_^", targets: targets), .inputText("^_^"))
    }

    func testLegacyLayoutReferencesAndReviewPreserveUnresolvedActions() throws {
        let json = #"[{"layout":{"layoutId":11,"stableId":"a","name":"A","rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"keyIdentifier":"key","action":"MoveToCustomKeyboard:12","doubleTapAction":"VoiceInput","isSpecialKey":true},"flicks":[{"actionType":"MoveToCustomKeyboard","actionValue":"missing"}]}]},{"layout":{"layoutId":12,"stableId":"b","name":"B","rowCount":1,"columnCount":1},"keysWithFlicks":[]}]"#
        let preview = try CustomLayoutImportPreview.parse(Data(json.utf8))
        XCTAssertEqual(preview.layouts.count, 2)
        let targets = CustomLayoutTargets(layouts: preview.layouts)
        XCTAssertEqual(CustomKeyAction.tap("MoveToCustomKeyboard:12", targets: targets), .switchLayout("b"))
        XCTAssertEqual(CustomKeyAction.flick(type: "MoveToCustomKeyboard", value: "b", targets: targets), .switchLayout("b"))
        let review = CustomLayoutActionReview(layouts: preview.layouts)
        XCTAssertEqual(review.items.count, 3)
        XCTAssertEqual(review.unsupported.count, 2)
        XCTAssertEqual(review.unsupported.map(\.keyID), ["key", "key"])
        let ambiguous = CustomLayoutTargets(layouts: preview.layouts + [preview.layouts[1]])
        if case .unsupported = CustomKeyAction.tap("MoveToCustomKeyboard:12", targets: ambiguous) {} else { XCTFail("Ambiguous reference") }
    }
    func testInputTextReviewDistinguishesSupportedOperationsFromLiteralText() throws {
        let tokens = ["ひらがな小文字", "濁点", "半濁点", "^_^", ":", "-"]
        for token in tokens { XCTAssertTrue(CustomKeyAction.supportsInputText(token), token) }
        XCTAssertFalse(CustomKeyAction.supportsInputText("🌸"))
        var editor = CustomLayoutEditor(rows: 1, columns: 3)
        editor.putKey(id: "marker", label: "濁", action: "InputText:濁点", special: false, row: 0, column: 0, height: 2, width: 2)
        editor.putKey(id: "unknown", label: "🌸", action: "InputText:🌸", special: false, row: 0, column: 2, height: 2, width: 2)
        editor.putKey(id: "literal", label: "文字", action: "Text:濁点", special: false, row: 0, column: 4, height: 2, width: 2)
        let layout = try editor.validated()
        let review = CustomLayoutActionReview(layouts: [layout])
        XCTAssertEqual(review.items.map(\.action), [.inputText("濁点"), .inputText("🌸"), .text("濁点")])
        XCTAssertEqual(review.unsupported.map(\.keyID), ["unknown"])
    }

}
