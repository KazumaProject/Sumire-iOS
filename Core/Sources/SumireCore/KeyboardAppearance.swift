import Foundation

public enum KeyboardKind: String, CaseIterable, Codable {
    case tenKey, romaji, english, sumire, custom, gojuon
    public var title: String {
        switch self {
        case .tenKey: return "テンキー"
        case .romaji: return "QWERTY 日本語"
        case .english: return "QWERTY 英語"
        case .sumire: return "Sumire"
        case .custom: return "Custom Keyboard"
        case .gojuon: return "50音"
        }
    }
}
public struct KeyboardAppearance: Equatable, Codable {
    public var keyFontSize: Double
    public var guideFontSize: Double
    public var guidesVisible: Bool
    public var keyScale: Double
    public static func load(_ kind: KeyboardKind, defaults: UserDefaults) -> Self {
        let prefix = "appearance." + kind.rawValue + "."
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: prefix + key) != nil else { return fallback }
            let value = defaults.double(forKey: prefix + key)
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        // Pinned JapaneseKeyboard df1f383: ModeKeySizing / KEY_GOJUON_SIZE /
        // qwerty_key_text_size. Android sp values at font scale 1 are used as
        // logical point defaults; cross-platform glyph metrics still differ.
        let defaultFont: Double
        switch kind {
        case .tenKey: defaultFont = 17
        case .sumire, .custom: defaultFont = 16
        case .romaji, .english, .gojuon: defaultFont = 18
        }
        return Self(keyFontSize: number("keyFontSize", fallback: defaultFont, range: 10...40),
                    guideFontSize: number("guideFontSize", fallback: kind == .sumire ? 9 : 11, range: 8...22),
                    guidesVisible: defaults.bool(forKey: prefix + "guidesVisible"),
                    keyScale: number("keyScale", fallback: 1, range: 0.7...1))
    }
    public static func reset(_ kind: KeyboardKind, defaults: UserDefaults) {
        for key in ["keyFontSize", "guideFontSize", "guidesVisible", "keyScale"] {
            defaults.removeObject(forKey: "appearance." + kind.rawValue + "." + key)
        }
    }
    public func save(_ kind: KeyboardKind, defaults: UserDefaults) {
        let prefix = "appearance." + kind.rawValue + "."
        defaults.set(keyFontSize, forKey: prefix + "keyFontSize")
        defaults.set(guideFontSize, forKey: prefix + "guideFontSize")
        defaults.set(guidesVisible, forKey: prefix + "guidesVisible")
        defaults.set(keyScale, forKey: prefix + "keyScale")
    }
}

public enum KeyboardKeyGroup: String, CaseIterable {
    case normal, special
    public var title: String { self == .normal ? "通常キー" : "特殊キー" }
}

extension KeyboardAppearance {
    public static func load(_ kind: KeyboardKind, group: KeyboardKeyGroup, defaults: UserDefaults) -> Self {
        let base = load(kind, defaults: defaults)
        guard group == .special else { return base }
        let prefix = "appearance." + kind.rawValue + ".special."
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: prefix + key) != nil else { return fallback }
            let value = defaults.double(forKey: prefix + key)
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        return Self(keyFontSize: number("keyFontSize", kind == .sumire || kind == .custom ? 12 : 16, 10...40),
                    guideFontSize: number("guideFontSize", 9, 8...22),
                    guidesVisible: defaults.bool(forKey: prefix + "guidesVisible"),
                    keyScale: number("keyScale", 1, 0.7...1))
    }
    public func save(_ kind: KeyboardKind, group: KeyboardKeyGroup, defaults: UserDefaults) {
        if group == .normal { save(kind, defaults: defaults); return }
        let prefix = "appearance." + kind.rawValue + ".special."
        defaults.set(keyFontSize, forKey: prefix + "keyFontSize")
        defaults.set(guideFontSize, forKey: prefix + "guideFontSize")
        defaults.set(guidesVisible, forKey: prefix + "guidesVisible")
        defaults.set(keyScale, forKey: prefix + "keyScale")
    }
    public static func reset(_ kind: KeyboardKind, group: KeyboardKeyGroup, defaults: UserDefaults) {
        if group == .normal { reset(kind, defaults: defaults); return }
        for key in ["keyFontSize", "guideFontSize", "guidesVisible", "keyScale"] {
            defaults.removeObject(forKey: "appearance." + kind.rawValue + ".special." + key)
        }
    }
}
