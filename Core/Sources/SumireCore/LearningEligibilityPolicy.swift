import Foundation

/// Mirrors the pinned Android policy's UTF-16 `Char` classification when deciding
/// whether a completed learning entry is stored.
public enum LearningEligibilityPolicy {
    public static func isEligible(
        input: String,
        output: String,
        allowJapaneseWithSymbolsAndNumbers: Bool
    ) -> Bool {
        guard !isBlank(input), !isBlank(output) else { return false }
        guard output.utf16.contains(where: isNumberOrPunctuationOrSymbol) else { return true }
        guard allowJapaneseWithSymbolsAndNumbers else { return false }
        return output.utf16.contains(where: isLetter)
    }

    private static func scalar(for codeUnit: UInt16) -> Unicode.Scalar? {
        // Java's Char overload sees supplementary characters as two surrogate code units.
        Unicode.Scalar(UInt32(codeUnit))
    }

    private static func isBlank(_ value: String) -> Bool {
        value.utf16.allSatisfy { codeUnit in
            switch codeUnit {
            case 0x0009...0x000D, 0x001C...0x001F:
                return true
            default:
                guard let scalar = scalar(for: codeUnit) else { return false }
                switch scalar.properties.generalCategory {
                case .spaceSeparator:
                    // Kotlin Char.isWhitespace also includes Java isSpaceChar,
                    // which includes non-breaking space separators.
                    return true
                case .lineSeparator, .paragraphSeparator:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private static func isNumberOrPunctuationOrSymbol(_ codeUnit: UInt16) -> Bool {
        guard let scalar = scalar(for: codeUnit) else { return false }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private static func isLetter(_ codeUnit: UInt16) -> Bool {
        guard let scalar = scalar(for: codeUnit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }
}
