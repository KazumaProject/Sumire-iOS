/// Explicit InputText markers from the pinned reference's CharExtension
/// getDakutenFlickTop/Left/Right. These are operations, never literal text.
public enum SumireFlickMarker: String, CaseIterable {
    case small = "ひらがな小文字", voiced = "濁点", semivoiced = "半濁点"
    public func applying(to character: Character) -> Character? {
        let pairs: [(String, Character)]
        switch self {
        case .small:
            pairs = [("あ", "ぁ"), ("い", "ぃ"), ("うゔ", "ぅ"), ("え", "ぇ"), ("お", "ぉ"),
                     ("つづ", "っ"), ("や", "ゃ"), ("ゆ", "ゅ"), ("よ", "ょ"), ("わ", "ゎ")]
        case .voiced:
            pairs = [("うぅ", "ゔ"), ("か", "が"), ("き", "ぎ"), ("く", "ぐ"), ("け", "げ"), ("こ", "ご"),
                     ("さ", "ざ"), ("し", "じ"), ("す", "ず"), ("せ", "ぜ"), ("そ", "ぞ"),
                     ("た", "だ"), ("ち", "ぢ"), ("つっ", "づ"), ("て", "で"), ("と", "ど"),
                     ("はぱ", "ば"), ("ひぴ", "び"), ("ふぷ", "ぶ"), ("へぺ", "べ"), ("ほぽ", "ぼ")]
        case .semivoiced:
            pairs = [("はば", "ぱ"), ("ひび", "ぴ"), ("ふぶ", "ぷ"), ("へべ", "ぺ"), ("ほぼ", "ぽ")]
        }
        return pairs.first { $0.0.contains(character) }?.1
    }
}
