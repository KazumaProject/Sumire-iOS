import Foundation

/// Integer grid shared by built-in layouts and the custom layout editor.
/// Actions are semantic: Android-only actions must be reported by importers,
/// never silently changed to text input.
public struct KeyboardLayout: Codable, Equatable {
    public enum Action: String, Codable {
        case text, paste, cursorLeft, changeMode, nextKeyboard
        case modifier, delete, space, enter
    }
    public struct Key: Codable, Equatable {
        public let id: String
        public let label: String
        public let row: Int
        public let column: Int
        public let rowSpan: Int
        public let columnSpan: Int
        public let action: Action
        public init(id: String, label: String, row: Int, column: Int,
                    rowSpan: Int = 1, columnSpan: Int = 1, action: Action) {
            self.id = id; self.label = label; self.row = row; self.column = column
            self.rowSpan = rowSpan; self.columnSpan = columnSpan; self.action = action
        }
    }
    public let rows: Int
    public let columns: Int
    public let keys: [Key]
    public init(rows: Int, columns: Int, keys: [Key]) {
        self.rows = rows; self.columns = columns; self.keys = keys
    }
    public enum ValidationError: Error, Equatable {
        case invalidDimensions, invalidKey(String), duplicateID(String), overlap(String, String)
    }
    public func validate() throws {
        guard (1...64).contains(rows), (1...64).contains(columns), keys.count <= 4096 else {
            throw ValidationError.invalidDimensions
        }
        var ids = Set<String>()
        var occupied = [Int: String]()
        for key in keys {
            guard !key.id.isEmpty, key.id.utf8.count <= 256, key.label.utf8.count <= 4096,
                  key.row >= 0, key.column >= 0, key.row < rows, key.column < columns,
                  key.rowSpan > 0, key.columnSpan > 0,
                  key.rowSpan <= rows - key.row, key.columnSpan <= columns - key.column else {
                throw ValidationError.invalidKey(key.id)
            }
            guard ids.insert(key.id).inserted else { throw ValidationError.duplicateID(key.id) }
            for row in key.row..<(key.row + key.rowSpan) {
                for column in key.column..<(key.column + key.columnSpan) {
                    let cell = row * columns + column
                    if let other = occupied[cell] { throw ValidationError.overlap(other, key.id) }
                    occupied[cell] = key.id
                }
            }
        }
    }

    /// JapaneseKeyboard df1f383: KeyboardDefaultLayouts.createHiraganaToggleLayout.
    /// This is placement and base actions only; gesture maps and dynamic states
    /// are separate and must be applied before exposing a complete Sumire mode.
    public static let sumireKana = KeyboardLayout(rows: 4, columns: 5, keys: [
        Key(id: "paste_key", label: "貼り付け", row: 0, column: 0, action: .paste),
        Key(id: "cursor_left_key", label: "←", row: 1, column: 0, action: .cursorLeft),
        Key(id: "change_input_mode_key", label: "モード", row: 2, column: 0, action: .changeMode),
        Key(id: "switch_next_ime", label: "🌐", row: 3, column: 0, action: .nextKeyboard),
        Key(id: "a", label: "あ", row: 0, column: 1, action: .text),
        Key(id: "ka", label: "か", row: 0, column: 2, action: .text),
        Key(id: "sa", label: "さ", row: 0, column: 3, action: .text),
        Key(id: "ta", label: "た", row: 1, column: 1, action: .text),
        Key(id: "na", label: "な", row: 1, column: 2, action: .text),
        Key(id: "ha", label: "は", row: 1, column: 3, action: .text),
        Key(id: "ma", label: "ま", row: 2, column: 1, action: .text),
        Key(id: "ya", label: "や", row: 2, column: 2, action: .text),
        Key(id: "ra", label: "ら", row: 2, column: 3, action: .text),
        Key(id: "dakuten_toggle_key", label: "^_^", row: 3, column: 1, action: .modifier),
        Key(id: "wa", label: "わ", row: 3, column: 2, action: .text),
        Key(id: "punctuation", label: "、。?!", row: 3, column: 3, action: .text),
        Key(id: "delete_key", label: "削除", row: 0, column: 4, action: .delete),
        Key(id: "space_convert_key", label: "空白", row: 1, column: 4, action: .space),
        Key(id: "enter_key", label: "改行", row: 2, column: 4, rowSpan: 2, action: .enter)
    ])
}

/// Reference layout preference; independent of character input mode and gestures.
public enum SumireKeyArrangement: String, CaseIterable {
    case toggle, flick, cursor = "switch-mode-effective"
    public var title: String {
        switch self { case .toggle: return "トグル"; case .flick: return "フリック"; case .cursor: return "カーソル" }
    }
    public var kanaLayout: KeyboardLayout {
        guard self != .toggle else { return .sumireKana }
        var keys = KeyboardLayout.sumireKana.keys.filter { (1...3).contains($0.column) }
        let left: [(String, String, KeyboardLayout.Action)] = self == .flick ? [
            ("number_mode", "123", .changeMode), ("english_mode", "ABC", .changeMode),
            ("kana_mode", "あいう", .changeMode), ("switch_next_ime", "🌐", .nextKeyboard)] : [
            ("switch_next_ime", "🌐", .nextKeyboard), ("cursor_left_key", "←", .cursorLeft),
            ("number_mode", "123", .changeMode), ("english_mode", "ABC", .changeMode)]
        for (row, item) in left.enumerated() {
            keys.append(.init(id: item.0, label: item.1, row: row, column: 0, action: item.2))
        }
        keys.append(.init(id: "delete_key", label: "削除", row: 0, column: 4, action: .delete))
        keys.append(.init(id: "space_convert_key", label: "空白", row: self == .flick ? 1 : 2, column: 4, action: .space))
        keys.append(.init(id: "cursor_right_key", label: "→", row: self == .flick ? 2 : 1, column: 4, action: .changeMode))
        keys.append(.init(id: "enter_key", label: "改行", row: 3, column: 4, action: .enter))
        return .init(rows: 4, columns: 5, keys: keys)
    }
}
