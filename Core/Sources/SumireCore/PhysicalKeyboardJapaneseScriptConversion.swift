import Foundation

/// Prepares a composing source for Android-compatible F6–F8 script conversion.
public enum PhysicalKeyboardJapaneseScriptConversion {
    /// Android converts an all-ASCII-letter source through its default romaji map
    /// before F6–F8. Mixed text and non-ASCII sources retain their Latin portions.
    public static func source(_ source: String, using converter: RomajiConverter?) -> String {
        guard !source.isEmpty,
              source.unicodeScalars.allSatisfy(isASCIIEnglishLetter),
              let converter else {
            return source
        }
        return convertAndroidDefaultMap(source.lowercased(), using: converter)
    }

    /// Mirrors the pinned Android `RomajiKanaConverter.convertCustomLayout` path
    /// used for its non-deletable default romaji map. That path applies doubled
    /// consonants and literal map lookup, without the editable-map auto-N rule.
    private static func convertAndroidDefaultMap(
        _ source: String,
        using converter: RomajiConverter
    ) -> String {
        let input = Array(source.utf16)
        let sokuonConsonants = Set("kstcpbdfghjmqrvwz".utf16)
        let maxKeyLength = converter.rules.keys.map { $0.utf16.count }.max() ?? 1
        var output: [UInt16] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let current = input[index]
            if index + 1 < input.count,
               current == input[index + 1],
               sokuonConsonants.contains(current) {
                output.append(contentsOf: "っ".utf16)
                index += 1
                continue
            }

            var matched = false
            let remaining = input.count - index
            for length in stride(from: min(maxKeyLength, remaining), through: 1, by: -1) {
                let key = String(decoding: input[index..<(index + length)], as: UTF16.self)
                guard let rule = converter.rules[key] else { continue }
                output.append(contentsOf: rule.first.utf16)
                index += min(max(rule.second, 1), remaining)
                matched = true
                break
            }
            if !matched {
                output.append(current)
                index += 1
            }
        }

        return String(decoding: output, as: UTF16.self)
    }

    private static func isASCIIEnglishLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }
}
