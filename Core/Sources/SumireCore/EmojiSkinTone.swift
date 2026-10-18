import Foundation

public enum EmojiSkinTone: String, CaseIterable, Codable {
    case standard = "default"
    case light = "1F3FB"
    case mediumLight = "1F3FC"
    case medium = "1F3FD"
    case mediumDark = "1F3FE"
    case dark = "1F3FF"
    public static let settingsKey = "symbol.defaultSkinTone"
    public var title: String {
        switch self {
        case .standard: return "標準"
        case .light: return "明るい肌色"
        case .mediumLight: return "やや明るい肌色"
        case .medium: return "中間の肌色"
        case .mediumDark: return "やや濃い肌色"
        case .dark: return "濃い肌色"
        }
    }
    public static func load(defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: settingsKey) ?? "") ?? .standard
    }
    public func save(defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.settingsKey) }
    public static func tone(in symbol: String) -> Self {
        guard let scalar = symbol.unicodeScalars.first(where: { (0x1F3FB...0x1F3FF).contains($0.value) }) else { return .standard }
        return Self(rawValue: String(scalar.value, radix: 16).uppercased()) ?? .standard
    }
}

/// Only sequences verified against the pinned upstream metadata are available.
/// Multi-person mixed-tone sequences are intentionally absent, matching the upstream single-base rule.
public enum EmojiSkinToneVariants {
    private static let table: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "SymbolSkinTones", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        var normalized: [String: [String]] = [:]
        for key in values.keys.sorted() { normalized[identity(key)] = values[key] }
        return normalized
    }()
    private static func identity(_ symbol: String) -> String {
        String(String.UnicodeScalarView(symbol.unicodeScalars.filter {
            !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0E && $0.value != 0xFE0F
        }))
    }
    public static func variants(for symbol: String) -> [String] { table[identity(symbol)] ?? [] }
    public static func applying(_ tone: EmojiSkinTone, to symbol: String) -> String {
        variants(for: symbol).first { EmojiSkinTone.tone(in: $0) == tone } ?? symbol
    }
    public static var noticeURL: URL? { Bundle.module.url(forResource: "SymbolSkinToneNotice", withExtension: "txt") }
}
