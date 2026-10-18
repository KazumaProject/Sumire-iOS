import Foundation

/// JapaneseKeyboard df1f383 KeyInfo and CharExtension mappings.
/// Empty directional entries mean no output, never a substitute character.
public enum TenKeyMode: Int, CaseIterable {
    case japanese, english, number
    public var next: Self { Self(rawValue: (rawValue + 1) % 3)! }
    public var title: String { ["あ", "a", "1"][rawValue] }
    public var keys: [[String]] {
        switch self {
        case .japanese: return KanaInput.tenKeyRows.flatMap { $0 }.map { $0.map(String.init) }
        case .english: return [["@", "#", "&", "_", "1"], ["a", "b", "c", "", "2"], ["d", "e", "f", "", "3"], ["g", "h", "i", "", "4"], ["j", "k", "l", "", "5"], ["m", "n", "o", "", "6"], ["p", "q", "r", "s", "7"], ["t", "u", "v", "", "8"], ["w", "x", "y", "z", "9"], ["゛"], ["'", "\"", ":", ";", "0"], [".", ",", "?", "!", "-"]]
        case .number: return [["1", "☆", "♪", "→", ""], ["2", "￥", "$", "€", ""], ["3", "%", "°", "#", ""], ["4", "○", "*", "・", ""], ["5", "+", "×", "÷", ""], ["6", "<", "=", ">", ""], ["7", "「", "」", ":", ""], ["8", "〒", "々", "〆", ""], ["9", "^", "|", "\\", ""], ["(", ")", "[", "]", ""], ["0", "~", "…", "@", ""], [".", ",", "-", "/", ""]]
        }
    }
    public func restingLabel(at index: Int) -> String {
        guard keys.indices.contains(index) else { return "" }
        switch self {
        case .japanese: return keys[index].first ?? ""
        case .english: return [" @#&_", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "a A", "'\":;", ".,?!"][index]
        case .number: return ["1\n☆♪→", "2\n￥$€", "3\n%°#", "4\n○ *・", "5\n+×÷", "6\n<=>", "7\n「」:", "8\n〒々〆", "9\n^ | \\", "()[]", "0\n~…@", ".,-/"][index]
        }
    }
    public func tapCycle(at index: Int) -> String {
        guard keys.indices.contains(index) else { return "" }
        switch self {
        case .japanese:
            return ["あいうえおぁぃぅぇぉ", "かきくけこ", "さしすせそ", "たちつてとっ", "なにぬねの", "はひふへほ", "まみむめも", "やゆよゃゅょ", "らりるれろ", "", "わをんゎー〜", "、。？！…・"][index]
        case .english:
            let letters = keys[index].joined().filter { $0.isASCII && $0.isLetter }
            if !letters.isEmpty { return letters + letters.uppercased() + keys[index].last! }
            return keys[index].joined()
        case .number: return keys[index].first ?? ""
        }
    }
    public func previous(_ character: Character) -> Character? {
        guard self != .number else { return nil }
        for index in keys.indices {
            let cycle = Array(tapCycle(at: index))
            if let position = cycle.firstIndex(of: character) { return cycle[(position + cycle.count - 1) % cycle.count] }
        }
        return nil
    }
}
