import Foundation

public enum SumireModePreferences {
    public static let englishQWERTYKey = "sumire.englishQwerty"
}

/// Base output slots from df1f383 KeyboardDefaultLayouts. Gesture geometry is
/// separate: these slots represent tap, upper-left, up, upper-right, down.
public enum SumireInput {
    public static func outputs(_ mode: TenKeyMode, arrangement: SumireKeyArrangement, index: Int) -> [String] {
        guard (0..<12).contains(index) else { return [] }
        var result = mode.keys[index]
        if mode == .english {
            if index == 0 { result = ["@", "#", "/", "_", "1"] }
            if index == 10 { result = ["'", "\"", "(", ")", "0"] }
        } else if mode == .number {
            if index == 4 { result[2] = "x" }
            if index == 10 { result = ["0", "〜", "…", "√", ""] }
            if arrangement == .cursor {
                if index == 2 { result[3] = "&" }
                if index == 9 { result = ["@", "/", "~", ";", ""] }
                if index == 11 { result = ["#", ".", "^", ",", ""] }
            }
        }
        return result
    }
    public static func label(_ mode: TenKeyMode, arrangement: SumireKeyArrangement, index: Int) -> String {
        if mode == .english {
            if index == 0 { return "@#/_" }
            if index == 9 { return "a/A" }
            if index == 10 { return "' \" ( )" }
            if index == 11 { return ". , ? !" }
        }
        if mode == .number {
            if index == 4 { return "5\n+x÷" }
            if index == 10 { return "0\n〜…" }
            if arrangement == .cursor {
                if index == 2 { return "3\n%°&" }
                if index == 9 { return "@\n/~;" }
                if index == 11 { return "#\n.^," }
            }
        }
        return mode.restingLabel(at: index)
    }
}

extension SumireKeyArrangement {
    public func layout(mode: TenKeyMode) -> KeyboardLayout {
        let keys = kanaLayout.keys.map { key -> KeyboardLayout.Key in
            var label = key.label, action = key.action, id = key.id
            if (1...3).contains(key.column), mode != .japanese {
                let index = key.row * 3 + key.column - 1
                label = SumireInput.label(mode, arrangement: self, index: index)
                action = index == 9 && mode == .english ? .modifier : .text
            }
            if id == "change_input_mode_key" { label = mode == .japanese ? "ABC" : mode == .english ? "123" : "あいう" }
            if self == .cursor {
                if id == "english_mode", mode == .english { id = "kana_mode"; label = "あいう" }
                if mode == .number {
                    if id == "number_mode" { id = "kana_mode"; label = "あいう" }
                    if id == "cursor_left_key" { id = "colon_key"; label = ":"; action = .changeMode }
                    if id == "cursor_right_key" { id = "hyphen_key"; label = "-"; action = .changeMode }
                }
            }
            return .init(id: id, label: label, row: key.row, column: key.column,
                         rowSpan: key.rowSpan, columnSpan: key.columnSpan, action: action)
        }
        return .init(rows: 4, columns: 5, keys: keys)
    }
}
