import Foundation

public enum FlickThresholdShape { case radial, rectangular }

public enum FlickDirection: Int { case tap, left, up, right, down
    public static func resolve(dx: Double, dy: Double, threshold: Double = 14,
                               shape: FlickThresholdShape = .rectangular) -> FlickDirection {
        let limit = max(1, threshold)
        let crossed = shape == .radial ? hypot(dx, dy) >= limit : max(abs(dx), abs(dy)) >= limit
        guard crossed else { return .tap }
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
    }
}
public enum KanaInput {
    /// Pinned Gojuon key_1...key_55, five rows per column, left to right.
    public static let gojuonRows: [[String]] = [
        ["「」", "わ", "ら", "や", "ま", "は", "な", "た", "さ", "か", "あ"],
        ["?", "を", "り", "", "み", "ひ", "に", "ち", "し", "き", "い"],
        ["!", "ん", "る", "ゆ", "む", "ふ", "ぬ", "つ", "す", "く", "う"],
        ["、", "ー", "れ", "", "め", "へ", "ね", "て", "せ", "け", "え"],
        ["。", "゛小", "ろ", "よ", "も", "ほ", "の", "と", "そ", "こ", "お"]
    ]
    /// Direction order: tap, left, up, right, down. Pinned Android KeyInfo mappings.
    public static let tenKeyRows = [["あいうえお", "かきくけこ", "さしすせそ"],
                                    ["たちつてと", "なにぬねの", "はひふへほ"],
                                    ["まみむめも", "や（ゆ）よ", "らりるれろ"],
                                    ["゛", "わをんー〜", "、。？！…"]]
    public static func previousJapanese(_ character: Character) -> Character? {
        // Pinned getNextReturnInputChar Japanese cycles, including small kana.
        for group in ["あいうえおぁぃぅぇぉ", "かきくけこ", "さしすせそ", "たちつてとっ",
                      "なにぬねの", "はひふへほ", "まみむめも", "やゆよゃゅょ", "らりるれろ",
                      "わをんゎー〜", "、。？！…・"] {
            let values = Array(group)
            if let index = values.firstIndex(of: character) { return values[(index + values.count - 1) % values.count] }
        }
        return nil
    }
    public static func modified(_ character: Character) -> Character? {
        let groups = ["あぁ", "いぃ", "うぅゔ", "えぇ", "おぉ", "かが", "きぎ", "くぐ", "けげ", "こご",
                      "さざ", "しじ", "すず", "せぜ", "そぞ", "ただ", "ちぢ", "つっづ", "てで", "とど",
                      "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ", "やゃ", "ゆゅ", "よょ", "わゎ"]
        for group in groups {
            let chars = Array(group)
            if let index = chars.firstIndex(of: character) { return chars[(index + 1) % chars.count] }
        }
        return nil
    }
}

/// Repeated taps replace only the character emitted by the preceding tap in the
/// same composition generation. Flicks, edits, commits, and explicit next break it.
public struct KanaTapCycle {
    private var key = ""
    private var index = 0
    private var generation: UInt64 = 0
    private var time: Double = -.infinity
    public init() {}
    public mutating func reset() { key = ""; time = -.infinity }
    public mutating func choose(_ values: String, direction: FlickDirection, generation current: UInt64,
                                time now: Double, enabled: Bool) -> (text: String, replacing: Bool) {
        let chars = Array(values)
        guard !chars.isEmpty else { return ("", false) }
        let replacing = enabled && direction == .tap && key == values && generation == current && now >= time && now - time < 1.0
        index = replacing ? (index + 1) % chars.count : min(direction.rawValue, chars.count - 1)
        key = direction == .tap ? values : ""
        time = now
        generation = current + 1
        return (String(chars[index]), replacing)
    }
}
