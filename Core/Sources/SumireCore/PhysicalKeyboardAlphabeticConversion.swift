import Foundation

/// The alphabet conversion used by Android's physical F9 and F10 shortcuts.
public enum PhysicalKeyboardAlphabeticWidth {
    case full
    case half
}

/// Core behavior for Android's `convert_to_full_alphanumeric` and
/// `convert_to_half_alphanumeric` actions.
///
/// This helper deliberately does not edit a text document. The keyboard
/// surface owns replacement, composition lifetime, and F6-F10 source retention.
public enum PhysicalKeyboardAlphabeticConversion {
    /// Converts ASCII-letter-only input by lowercasing first. All other input
    /// follows Android's kana-to-romaji path using the supplied active map.
    public static func convert(
        _ source: String,
        to width: PhysicalKeyboardAlphabeticWidth,
        using converter: RomajiConverter?
    ) -> String {
        guard !source.isEmpty else { return source }

        let intermediate: String
        if source.unicodeScalars.allSatisfy(isASCIIEnglishLetter) {
            intermediate = reverseWidth(source.lowercased(), to: width)
        } else {
            guard let converter else { return source }
            let hiragana = normalizeToHiragana(source)
            intermediate = reverseWidth(romaji(from: hiragana, using: converter), to: width)
        }
        return intermediate
    }

    private static func isASCIIEnglishLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    /// Mirrors the pinned Android String.toHiragana implementation, including
    /// its explicit half-width voiced/semi-voiced pairs and preserved unknowns.
    private static func normalizeToHiragana(_ source: String) -> String {
        let input = Array(source.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            if index + 1 < input.count {
                let pair = String(input[index]) + String(input[index + 1])
                if let converted = halfWidthKana[pair] {
                    output.append(contentsOf: converted.unicodeScalars)
                    index += 2
                    continue
                }
            }

            let scalar = input[index]
            if let converted = halfWidthKana[String(scalar)] {
                output.append(contentsOf: converted.unicodeScalars)
            } else if (0x30A1...0x30F6).contains(scalar.value) {
                output.append(Unicode.Scalar(scalar.value - 0x60)!)
            } else if scalar.value == 0x30FD {
                output.append(Unicode.Scalar(0x309D)!)
            } else if scalar.value == 0x30FE {
                output.append(Unicode.Scalar(0x309E)!)
            } else {
                output.append(scalar)
            }
            index += 1
        }

        return String(String.UnicodeScalarView(output))
    }

    private static let halfWidthKana: [String: String] = {
        var values: [String: String] = [
            "ｱ": "あ", "ｲ": "い", "ｳ": "う", "ｴ": "え", "ｵ": "お",
            "ｶ": "か", "ｷ": "き", "ｸ": "く", "ｹ": "け", "ｺ": "こ",
            "ｻ": "さ", "ｼ": "し", "ｽ": "す", "ｾ": "せ", "ｿ": "そ",
            "ﾀ": "た", "ﾁ": "ち", "ﾂ": "つ", "ﾃ": "て", "ﾄ": "と",
            "ﾅ": "な", "ﾆ": "に", "ﾇ": "ぬ", "ﾈ": "ね", "ﾉ": "の",
            "ﾊ": "は", "ﾋ": "ひ", "ﾌ": "ふ", "ﾍ": "へ", "ﾎ": "ほ",
            "ﾏ": "ま", "ﾐ": "み", "ﾑ": "む", "ﾒ": "め", "ﾓ": "も",
            "ﾔ": "や", "ﾕ": "ゆ", "ﾖ": "よ",
            "ﾗ": "ら", "ﾘ": "り", "ﾙ": "る", "ﾚ": "れ", "ﾛ": "ろ",
            "ﾜ": "わ", "ｦ": "を", "ﾝ": "ん",
            "ｧ": "ぁ", "ｨ": "ぃ", "ｩ": "ぅ", "ｪ": "ぇ", "ｫ": "ぉ",
            "ｬ": "ゃ", "ｭ": "ゅ", "ｮ": "ょ", "ｯ": "っ", "ｰ": "ー",
            "｡": "。", "､": "、", "｢": "「", "｣": "」", "ﾞ": "゛", "ﾟ": "゜"
        ]

        let voicedRows = [
            ("ｶｷｸｹｺ", "かきくけこ", "がぎぐげご"),
            ("ｻｼｽｾｿ", "さしすせそ", "ざじずぜぞ"),
            ("ﾀﾁﾂﾃﾄ", "たちつてと", "だぢづでど"),
            ("ﾊﾋﾌﾍﾎ", "はひふへほ", "ばびぶべぼ")
        ]
        for (halfWidth, _, voiced) in voicedRows {
            for (source, output) in zip(halfWidth, voiced) {
                values[String(source) + "ﾞ"] = String(output)
            }
        }
        for (source, output) in zip("ﾊﾋﾌﾍﾎ", "ぱぴぷぺぽ") {
            values[String(source) + "ﾟ"] = String(output)
        }
        return values
    }()

    /// Mirrors Android's reverse map: omit blank outputs and sokuon entries,
    /// select the shortest romaji alias for each kana sequence. Android
    /// persists these keys through Gson JsonObject and Room restores their
    /// insertion order, so equal-length aliases use Android's first map entry.
    private static func kanaAliases(using converter: RomajiConverter) -> [String: String] {
        var aliases: [String: String] = [:]
        for romaji in converter.ruleOrder {
            guard let rule = converter.rules[romaji] else { continue }
            let kana = rule.first
            guard kana != "っ", !kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let current = aliases[kana] else {
                aliases[kana] = romaji
                continue
            }

            let candidateLength = romaji.utf16.count
            let currentLength = current.utf16.count
            if candidateLength < currentLength {
                aliases[kana] = romaji
            }
        }
        return aliases
    }

    private static func romaji(from hiragana: String, using converter: RomajiConverter) -> String {
        let aliases = kanaAliases(using: converter)
        let maxKanaLength = aliases.keys.map { $0.utf16.count }.max() ?? 0
        let input = Array(hiragana.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            if input[index] == 0x3063, index + 1 < input.count,
               let next = longestAlias(in: input, at: index + 1, maxLength: maxKanaLength, aliases: aliases),
               let firstRomajiUnit = next.utf16.first {
                output.append(firstRomajiUnit)
                index += 1
                continue
            }

            if input[index] == 0x30FC, let previous = output.last {
                let lowercased = (0x41...0x5A).contains(previous) ? previous + 0x20 : previous
                if [UInt16(0x61), 0x69, 0x75, 0x65, 0x6F].contains(lowercased) {
                    output.append(lowercased)
                    index += 1
                    continue
                }
            }

            if let alias = longestAlias(in: input, at: index, maxLength: maxKanaLength, aliases: aliases) {
                output.append(contentsOf: alias.utf16)
                index += Array(aliasKana(in: input, at: index, maxLength: maxKanaLength, aliases: aliases).utf16).count
            } else {
                output.append(input[index])
                index += 1
            }
        }

        return String(decoding: output, as: UTF16.self)
    }

    private static func longestAlias(
        in input: [UInt16], at index: Int, maxLength: Int, aliases: [String: String]
    ) -> String? {
        let kana = aliasKana(in: input, at: index, maxLength: maxLength, aliases: aliases)
        return kana.isEmpty ? nil : aliases[kana]
    }

    private static func aliasKana(
        in input: [UInt16], at index: Int, maxLength: Int, aliases: [String: String]
    ) -> String {
        guard maxLength > 0, index < input.count else { return "" }
        let upperBound = min(maxLength, input.count - index)
        for length in stride(from: upperBound, through: 1, by: -1) {
            let kana = String(decoding: input[index..<(index + length)], as: UTF16.self)
            if aliases[kana] != nil { return kana }
        }
        return ""
    }

    private static func reverseWidth(_ text: String, to width: PhysicalKeyboardAlphabeticWidth) -> String {
        var output: [UInt16] = []
        output.reserveCapacity(text.utf16.count)
        for unit in text.utf16 {
            switch width {
            case .full:
                if unit == 0x20 {
                    output.append(0x3000)
                } else if (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) {
                    output.append(unit + 0xFEE0)
                } else {
                    output.append(unit)
                }
            case .half:
                if unit == 0x3000 {
                    output.append(0x20)
                } else if (0xFF21...0xFF3A).contains(unit) || (0xFF41...0xFF5A).contains(unit) {
                    output.append(unit - 0xFEE0)
                } else {
                    output.append(unit)
                }
            }
        }
        return String(decoding: output, as: UTF16.self)
    }
}
