/// Settings choices for commands implemented by the custom keyboard executor.
/// Serialization names follow pinned Android df1f383, not Swift enum case names.
public enum CustomCommandCatalog {
    public struct Entry: Equatable, Identifiable {
        public let command: CustomKeyAction.Command
        public let title: String
        public let tapRaw: String
        public let flickType: String
        public let flickValue: String?
        public var id: String { tapRaw }
    }
    public static let entries: [Entry] = [
        entry(.doNothing, "何もしない", "DoNothing", "DoNothing"),
        entry(.delete, "削除", "Delete", "DELETE"),
        entry(.backspace, "後退削除", "Backspace", "BACKSPACE"),
        entry(.deleteAfterCursor, "カーソル後を削除", "DeleteAfterCursor", "DELETE_AFTER_CURSOR"),
        entry(.deleteUntilBoundary, "区切りまで削除", "DeleteUntilSymbol", "DeleteUntilSymbol"),
        entry(.space, "空白", "Space", "SPACE"),
        entry(.convert, "変換", "Convert", "CONVERT"),
        entry(.enter, "エンター（確定・改行）", "Enter", "ENTER"),
        entry(.newLine, "エンター（確定・改行）", "NewLine", "NEW_LINE"),
        entry(.confirm, "確定", "Confirm", "CONFIRM"),
        entry(.forceNewLine, "改行", "ForceNewLine", "ForceNewLine"),
        entry(.halfSpace, "半角空白・変換", "ForceHalfWidthSpace", "ForceHalfWidthSpace"),
        entry(.fullSpace, "全角空白・変換", "ForceFullWidthSpace", "ForceFullWidthSpace"),
        entry(.commitAndSpace, "読みを確定して空白", "CommitAndInsertSpace", "CommitAndInsertSpace"),
        entry(.paste, "貼り付け", "Paste", "PASTE"),
        entry(.cursorLeft, "カーソルを左へ", "MoveCursorLeft", "MOVE_CURSOR_LEFT"),
        entry(.cursorRight, "カーソルを右へ", "MoveCursorRight", "MOVE_CURSOR_RIGHT"),
        entry(.modifier, "小文字・濁点", "小゛゜", "TOGGLE_DAKUTEN"),
        entry(.toggleCase, "英字大小・小文字・濁点", "a/A", "TOGGLE_CASE"),
        entry(.shift, "Shift", "ShiftKeyPressed", "ShiftKey"),
        entry(.capsLock, "Caps Lock", "CapLockKey", "CapLockKey"),
        entry(.changeMode, "入力モードを切り替え", "ChangeInputMode", "CHANGE_INPUT_MODE"),
        entry(.switchKana, "かな入力へ", "SwitchToKana", "SwitchToKana"),
        entry(.switchEnglish, "英語入力へ", "SwitchToEnglish", "SwitchToEnglish"),
        entry(.switchNumber, "数字入力へ", "SwitchToNumber", "SwitchToNumber"),
        entry(.switchDirect, "直接入力を切り替え", "SwitchDirectMode", "SwitchDirectMode"),
        entry(.switchRomaji, "ローマ字入力を切り替え", "SwitchRomajiEnglish", "SwitchRomajiEnglish"),
        entry(.openSymbols, "記号キーボード", "^_^", "ShowEmojiKeyboard", "絵"),
        entry(.nextKeyboard, "次のキーボード", "SwitchToNextIme", "SWITCH_TO_NEXT_IME"),
        entry(.moveCustomKeyboardTab, "次のカスタム配列", "MoveCustomKeyboardTab", "MoveCustomKeyboardTab", "⇄")
    ]
    /// NewLine is an imported compatibility alias of Enter in the reference UI.
    public static var selectableEntries: [Entry] { entries.filter { $0.command != .newLine } }
    public static let inputTextTokens = SumireFlickMarker.allCases.map(\.rawValue) + ["^_^", ":", "-"]
    public static func tapSelection(_ raw: String) -> String {
        if raw.hasPrefix("Text:") { return "Text" }
        if raw.hasPrefix("InputText:") { return "InputText" }
        if raw.hasPrefix("MoveToCustomKeyboard:") { return "SwitchLayout" }
        if case .command(let command) = CustomKeyAction.tap(raw, targets: CustomLayoutTargets(layouts: [])),
           let entry = selectableEntries.first(where: { $0.command == (command == .newLine ? .enter : command) }) { return entry.tapRaw }
        return raw
    }
    public static func flickSelection(_ raw: String) -> String {
        if case .command(let command) = CustomKeyAction.flick(type: raw, value: nil, targets: CustomLayoutTargets(layouts: [])),
           let entry = selectableEntries.first(where: { $0.command == (command == .newLine ? .enter : command) }) { return entry.flickType }
        return raw
    }
    private static func entry(_ command: CustomKeyAction.Command, _ title: String, _ tap: String,
                              _ flick: String, _ value: String? = nil) -> Entry {
        Entry(command: command, title: title, tapRaw: tap, flickType: flick, flickValue: value)
    }
}
