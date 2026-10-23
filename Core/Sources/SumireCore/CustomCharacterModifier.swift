/// Pinned Android ToggleCase / ToggleDakuten composition action. This changes
/// only a single scalar: decomposed graphemes and committed editor text are not
/// normalized or rewritten as a side effect of a custom modifier command.
public enum CustomCharacterModifier {
    public static func modified(_ character: Character) -> Character? {
        let scalars = String(character).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        if (65...90).contains(scalar.value) { return Character(String(UnicodeScalar(scalar.value + 32)!)) }
        if (97...122).contains(scalar.value) { return Character(String(UnicodeScalar(scalar.value - 32)!)) }
        guard (0x3040...0x309f).contains(scalar.value) else { return nil }
        return KanaInput.modified(character)
    }
}
