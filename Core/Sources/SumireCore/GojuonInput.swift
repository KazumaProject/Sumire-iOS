import Foundation

/// Pinned df1f383 GojuonKeyboardView bindings → KeyMap → KeyInfo; labels from AppCompatButton.
/// Slots are tap/left/up/right/down; empty slots deliberately emit nothing.
public enum GojuonInput {
    /// IMEService's previous key calls CharExtension.getNextReturnInputChar
    /// in Japanese and English modes, and does nothing in number mode.
    public static func previous(_ character: Character, mode: TenKeyMode) -> Character? {
        guard mode != .number else { return nil }
        if let kana = KanaInput.previousJapanese(character) { return kana }
        // Preserve the pinned reference's x/w ordering in its reverse map.
        for text in ["@#&_1", "abcABC2", "defDEF3", "ghiGHI4", "jklJKL5", "mnoMNO6",
                     "pqrsPQRS7", "tuvTUV8", "xwyzXWYZ9", "'\":;0", ".,?!-"] {
            let cycle = Array(text)
            if let index = cycle.firstIndex(of: character) { return cycle[(index + cycle.count - 1) % cycle.count] }
        }
        return nil
    }
    public struct Cell: Equatable, Sendable {
        public let row: Int
        public let sourceColumn: Int
        public let column: Int
        public let columnSpan: Int
    }
    public static func columns(mode: TenKeyMode) -> Int {
        mode == .japanese ? 11 : mode == .english ? 10 : 8
    }
    /// Mirrors handleClickInputModeSwitch: remove hidden columns and merge
    /// the bottom shift/command, case-toggle and full-width keys.
    public static func cells(mode: TenKeyMode) -> [Cell] {
        let sourceColumns = (0..<11).filter {
            mode == .japanese || ($0 != 1 && (mode != .number || ($0 != 3 && $0 != 4)))
        }
        return (0..<5).flatMap { row in
            sourceColumns.enumerated().compactMap { column, source -> Cell? in
                if row == 4 && mode != .japanese {
                    if source == 2 || source == 4 || source == 9 { return nil }
                    if source == 0 || source == 3 { return .init(row: row, sourceColumn: source, column: column, columnSpan: 2) }
                    if source == 10 { return .init(row: row, sourceColumn: source, column: column - 1, columnSpan: 2) }
                }
                return .init(row: row, sourceColumn: source, column: column, columnSpan: 1)
            }
        }
    }
    public static func outputs(row: Int, column: Int, mode: TenKeyMode = .japanese) -> [String] {
        guard (0..<5).contains(row), (0..<11).contains(column) else { return [] }
        let table = mode == .japanese ? japanese : mode == .english ? english : number
        return table[column * 5 + row] ?? []
    }
    /// Display text is independent of tap output (e.g. apostrophe versus backquote).
    public static func label(row: Int, column: Int, mode: TenKeyMode = .japanese) -> String {
        guard (0..<5).contains(row), (0..<11).contains(column) else { return "" }
        if mode == .japanese { return KanaInput.gojuonRows[row][column] }
        return (mode == .english ? englishLabels : numberLabels)[column * 5 + row] ?? ""
    }
    private static let japanese: [Int: [String]] = [
        0: ["「", "「", "」", "(", ")"],
        1: ["？", "", "?", "", ""],
        2: ["！", "", "!", "", ""],
        3: ["、", "", "", "", ""],
        4: ["。", "", "", "", ""],
        5: ["わ", "", "ゎ", "", ""],
        6: ["を", "", "", "", ""],
        7: ["ん", "", "", "", ""],
        8: ["ー", "", "-", "〜", ""],
        10: ["ら", "", "", "", ""],
        11: ["り", "", "", "", ""],
        12: ["る", "", "", "", ""],
        13: ["れ", "", "", "", ""],
        14: ["ろ", "", "", "", ""],
        15: ["や", "", "ゃ", "", ""],
        17: ["ゆ", "", "ゅ", "", ""],
        19: ["よ", "", "ょ", "", ""],
        20: ["ま", "", "", "", ""],
        21: ["み", "", "", "", ""],
        22: ["む", "", "", "", ""],
        23: ["め", "", "", "", ""],
        24: ["も", "", "", "", ""],
        25: ["は", "ば", "", "ぱ", ""],
        26: ["ひ", "び", "", "ぴ", ""],
        27: ["ふ", "ぶ", "", "ぷ", ""],
        28: ["へ", "べ", "", "ぺ", ""],
        29: ["ほ", "ぼ", "", "ぽ", ""],
        30: ["な", "", "", "", ""],
        31: ["に", "", "", "", ""],
        32: ["ぬ", "", "", "", ""],
        33: ["ね", "", "", "", ""],
        34: ["の", "", "", "", ""],
        35: ["た", "だ", "", "", ""],
        36: ["ち", "ぢ", "", "", ""],
        37: ["つ", "づ", "っ", "", ""],
        38: ["て", "で", "", "", ""],
        39: ["と", "ど", "", "", ""],
        40: ["さ", "ざ", "", "", ""],
        41: ["し", "じ", "", "", ""],
        42: ["す", "ず", "", "", ""],
        43: ["せ", "ぜ", "", "", ""],
        44: ["そ", "ぞ", "", "", ""],
        45: ["か", "が", "", "", ""],
        46: ["き", "ぎ", "", "", ""],
        47: ["く", "ぐ", "", "", ""],
        48: ["け", "げ", "", "", ""],
        49: ["こ", "ご", "", "", ""],
        50: ["あ", "", "ぁ", "", ""],
        51: ["い", "", "ぃ", "", ""],
        52: ["う", "ゔ", "ぅ", "", ""],
        53: ["え", "", "ぇ", "", ""],
        54: ["お", "", "ぉ", "", ""]
    ]
    private static let englishLabels: [Int: String] = [
        0: "a",
        1: "k",
        2: "u",
        3: "-",
        4: "⇧",
        10: "b",
        11: "l",
        12: "v",
        13: "_",
        15: "c",
        16: "m",
        17: "w",
        18: "/",
        19: "a/A",
        20: "d",
        21: "n",
        22: "x",
        23: ":",
        25: "e",
        26: "o",
        27: "y",
        28: "&",
        29: ",",
        30: "f",
        31: "p",
        32: "z",
        33: "@",
        34: ".",
        35: "g",
        36: "q",
        37: "(",
        38: "#",
        39: "!",
        40: "h",
        41: "r",
        42: ")",
        43: "*",
        44: "?",
        45: "i",
        46: "s",
        47: "[",
        48: "^",
        50: "j",
        51: "t",
        52: "]",
        53: "'",
        54: "全角"
    ]
    private static let english: [Int: [String]] = [
        0: ["a", "A", "ａ", "Ａ", ""],
        1: ["k", "K", "ｋ", "Ｋ", ""],
        2: ["u", "U", "ｕ", "Ｕ", ""],
        3: ["-", "+", "－", "＋", ""],
        4: ["", "", "", "", ""],
        10: ["b", "B", "ｂ", "Ｂ", ""],
        11: ["l", "L", "ｌ", "Ｌ", ""],
        12: ["v", "V", "ｖ", "Ｖ", ""],
        13: ["_", "~", "＿", "〜", ""],
        15: ["c", "C", "ｃ", "Ｃ", ""],
        16: ["m", "M", "ｍ", "Ｍ", ""],
        17: ["w", "W", "ｗ", "Ｗ", ""],
        18: ["/", "\\", "／", "＼", ""],
        19: ["", "", "", "", ""],
        20: ["d", "D", "ｄ", "Ｄ", ""],
        21: ["n", "N", "ｎ", "Ｎ", ""],
        22: ["x", "X", "ｘ", "Ｘ", ""],
        23: [":", ";", "：", "；", ""],
        25: ["e", "E", "ｅ", "Ｅ", ""],
        26: ["o", "O", "ｏ", "Ｏ", ""],
        27: ["y", "Y", "ｙ", "Ｙ", ""],
        28: ["&", "%", "＆", "％", ""],
        29: [",", "、", "，", "", ""],
        30: ["f", "F", "ｆ", "Ｆ", ""],
        31: ["p", "P", "ｐ", "Ｐ", ""],
        32: ["z", "Z", "ｚ", "Ｚ", ""],
        33: ["@", "|", "＠", "｜", ""],
        34: [".", "。", "．", "", ""],
        35: ["g", "G", "ｇ", "Ｇ", ""],
        36: ["q", "Q", "ｑ", "Ｑ", ""],
        37: ["(", "<", "（", "〈", ""],
        38: ["#", "=", "＃", "＝", ""],
        39: ["!", "", "！", "", ""],
        40: ["h", "H", "ｈ", "Ｈ", ""],
        41: ["r", "R", "ｒ", "Ｒ", ""],
        42: [")", ">", "）", "〉", ""],
        43: ["*", "$", "＊", "＄", ""],
        44: ["?", "", "？", "", ""],
        45: ["i", "I", "ｉ", "Ｉ", ""],
        46: ["s", "S", "ｓ", "Ｓ", ""],
        47: ["[", "{", "［", "｛", ""],
        48: ["^", "'", "＾", "＇", ""],
        50: ["j", "J", "ｊ", "Ｊ", ""],
        51: ["t", "T", "ｔ", "Ｔ", ""],
        52: ["]", "}", "］", "｝", ""],
        53: ["`", "\"", "｀", "＂", ""],
        54: ["", "", "", "", ""]
    ]
    private static let numberLabels: [Int: String] = [
        0: "年",
        1: "×",
        2: "♪",
        3: "→",
        4: "⌘",
        10: "月",
        11: "÷",
        12: "☆",
        13: "~",
        25: "日",
        26: "+",
        27: "%",
        28: "・",
        29: "/",
        30: "時",
        31: "ー",
        32: "￥",
        33: "…",
        34: "(",
        35: "分",
        36: "=",
        37: "〒",
        38: "○",
        39: ")",
        40: "1",
        41: "4",
        42: "7",
        43: ",",
        44: ":",
        45: "2",
        46: "5",
        47: "8",
        48: "0",
        50: "3",
        51: "6",
        52: "9",
        53: ".",
        54: "全角"
    ]
    private static let number: [Int: [String]] = [
        0: ["年", "", "年", "", ""],
        1: ["×", "", "×", "", ""],
        2: ["♪", "", "♪", "", ""],
        3: ["→", "", "→", "", ""],
        4: ["", "", "", "", ""],
        10: ["月", "", "月", "", ""],
        11: ["÷", "", "÷", "", ""],
        12: ["☆", "", "☆", "", ""],
        13: ["~", "", "～", "", ""],
        25: ["日", "", "日", "", ""],
        26: ["+", "", "＋", "", ""],
        27: ["%", "", "％", "", ""],
        28: ["・", "", "・", "", ""],
        29: ["/", "", "／", "", ""],
        30: ["時", "", "時", "", ""],
        31: ["−", "", "－", "", ""],
        32: ["¥", "", "￥", "", ""],
        33: ["…", "", "…", "", ""],
        34: ["(", "", "（", "", ""],
        35: ["分", "", "分", "", ""],
        36: ["=", "", "＝", "", ""],
        37: ["〒", "", "〒", "", ""],
        38: ["○", "", "○", "", ""],
        39: [")", "", "）", "", ""],
        40: ["1", "", "１", "", ""],
        41: ["4", "", "４", "", ""],
        42: ["7", "", "７", "", ""],
        43: [",", "", "，", "", ""],
        44: [":", "", "：", "", ""],
        45: ["2", "", "２", "", ""],
        46: ["5", "", "５", "", ""],
        47: ["8", "", "８", "", ""],
        48: ["0", "", "０", "", ""],
        50: ["3", "", "３", "", ""],
        51: ["6", "", "６", "", ""],
        52: ["9", "", "９", "", ""],
        53: [".", "", "．", "", ""],
        54: ["", "", "", "", ""]
    ]
}
