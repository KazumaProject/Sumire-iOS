import XCTest
@testable import SumireCore

final class CustomCommandCatalogTests: XCTestCase {
    func testCatalogCoversExactlySupportedCommandsWithJapaneseLabels() {
        XCTAssertEqual(Set(CustomCommandCatalog.entries.map(\.command)), Set(CustomKeyAction.Command.allCases))
        XCTAssertEqual(Set(CustomCommandCatalog.entries.map(\.tapRaw)).count, CustomCommandCatalog.entries.count)
        XCTAssertEqual(Set(CustomCommandCatalog.entries.map(\.flickType)).count, CustomCommandCatalog.entries.count)
        for entry in CustomCommandCatalog.entries {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertNotEqual(entry.title, entry.command.rawValue)
        }
    }
    func testPinnedLiteralTapAndFlickSerializationTable() {
        // Literal expectations are independent of the catalog and decoder.
        let table: [(CustomKeyAction.Command, String, String)] = [
            (.doNothing,"DoNothing","DoNothing"), (.delete,"Delete","DELETE"), (.backspace,"Backspace","BACKSPACE"),
            (.deleteAfterCursor,"DeleteAfterCursor","DELETE_AFTER_CURSOR"),
            (.space,"Space","SPACE"), (.enter,"Enter","ENTER"), (.newLine,"NewLine","NEW_LINE"),
            (.confirm,"Confirm","CONFIRM"), (.convert,"Convert","CONVERT"), (.paste,"Paste","PASTE"),
            (.cursorLeft,"MoveCursorLeft","MOVE_CURSOR_LEFT"), (.cursorRight,"MoveCursorRight","MOVE_CURSOR_RIGHT"),
            (.nextKeyboard,"SwitchToNextIme","SWITCH_TO_NEXT_IME"), (.modifier,"小゛゜","TOGGLE_DAKUTEN"),
            (.toggleCase,"a/A","TOGGLE_CASE"), (.shift,"ShiftKeyPressed","ShiftKey"), (.capsLock,"CapLockKey","CapLockKey"),
            (.changeMode,"ChangeInputMode","CHANGE_INPUT_MODE"), (.moveCustomKeyboardTab,"MoveCustomKeyboardTab","MoveCustomKeyboardTab"),
            (.forceNewLine,"ForceNewLine","ForceNewLine"), (.halfSpace,"ForceHalfWidthSpace","ForceHalfWidthSpace"),
            (.fullSpace,"ForceFullWidthSpace","ForceFullWidthSpace"), (.commitAndSpace,"CommitAndInsertSpace","CommitAndInsertSpace"),
            (.deleteUntilBoundary,"DeleteUntilSymbol","DeleteUntilSymbol"), (.openSymbols,"^_^","ShowEmojiKeyboard"),
            (.switchKana,"SwitchToKana","SwitchToKana"), (.switchEnglish,"SwitchToEnglish","SwitchToEnglish"),
            (.switchNumber,"SwitchToNumber","SwitchToNumber"), (.switchDirect,"SwitchDirectMode","SwitchDirectMode"),
            (.switchRomaji,"SwitchRomajiEnglish","SwitchRomajiEnglish")]
        let targets = CustomLayoutTargets(layouts: [])
        XCTAssertEqual(table.count, CustomCommandCatalog.entries.count)
        for (command, tap, flick) in table {
            let entry = CustomCommandCatalog.entries.first { $0.command == command }
            XCTAssertEqual(entry?.tapRaw, tap); XCTAssertEqual(entry?.flickType, flick)
            XCTAssertEqual(CustomKeyAction.tap(tap, targets: targets), .command(command))
            XCTAssertEqual(CustomKeyAction.flick(type: flick, value: entry?.flickValue, targets: targets), .command(command))
        }
        XCTAssertEqual(CustomCommandCatalog.entries.first { $0.command == .openSymbols }?.flickValue, "絵")
        XCTAssertEqual(CustomCommandCatalog.entries.first { $0.command == .moveCustomKeyboardTab }?.flickValue, "⇄")
    }
    func testAliasesAndPayloadKindsAreSelectionsWithoutChangingOriginalData() {
        for (raw, expected) in [("ShiftKey","ShiftKeyPressed"), ("SwitchToEnglishLayout","SwitchToEnglish"),
                                ("ShowEmojiKeyboard","^_^"), ("NewLine","Enter"), ("Text:濁点","Text"), ("InputText:濁点","InputText"),
                                ("MoveToCustomKeyboard:stable-id","SwitchLayout"), ("VoiceInput","VoiceInput")] {
            XCTAssertEqual(CustomCommandCatalog.tapSelection(raw), expected)
        }
        XCTAssertEqual(CustomCommandCatalog.flickSelection("MOVE_CURSOR_RIGHT"), "MOVE_CURSOR_RIGHT")
        XCTAssertEqual(CustomCommandCatalog.flickSelection("MoveCursorRight"), "MOVE_CURSOR_RIGHT")
        XCTAssertEqual(CustomCommandCatalog.flickSelection("VOICE_INPUT"), "VOICE_INPUT")
        XCTAssertEqual(CustomCommandCatalog.flickSelection("NEW_LINE"), "ENTER")
        XCTAssertFalse(CustomCommandCatalog.selectableEntries.contains { $0.command == .newLine })
        XCTAssertTrue(CustomCommandCatalog.inputTextTokens.allSatisfy(CustomKeyAction.supportsInputText))
        let targets = CustomLayoutTargets(layouts: [])
        XCTAssertEqual(CustomKeyAction.tap("Text:濁点", targets: targets), .text("濁点"))
        XCTAssertEqual(CustomKeyAction.tap("InputText:濁点", targets: targets), .inputText("濁点"))
        XCTAssertEqual(CustomKeyAction.flick(type: "INPUT_TEXT", value: "濁点", targets: targets), .text("濁点"))
        guard case .unsupported = CustomKeyAction.tap("MoveToCustomKeyboard:missing", targets: targets) else { return XCTFail("Missing target must not become a command or text") }
    }
}
