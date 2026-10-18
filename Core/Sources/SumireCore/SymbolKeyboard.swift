import Foundation

public enum SymbolKeyboardMode: String, CaseIterable, Codable {
    case emoji, emoticon, symbol, clipboard
    public var title: String {
        switch self {
        case .emoji: return "絵文字"
        case .emoticon: return "顔文字"
        case .symbol: return "記号"
        case .clipboard: return "クリップボード"
        }
    }
    public static let initialModeKey = "symbol.initialMode"
    public static func initialMode(defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: initialModeKey) ?? "") ?? .emoji
    }
    public func saveAsInitialMode(defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.initialModeKey) }
}

public struct SymbolKeyboardCategory: Decodable, Equatable {
    public let mode: SymbolKeyboardMode
    public let id: String
    public let title: String
    public let symbols: [String]
    public init(mode: SymbolKeyboardMode, id: String, title: String, symbols: [String]) {
        self.mode = mode; self.id = id; self.title = title; self.symbols = symbols
    }
}

public enum SymbolKeyboardCatalog {
    public static func load() throws -> [SymbolKeyboardCategory] {
        guard let url = Bundle.module.url(forResource: "SymbolCatalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([SymbolKeyboardCategory].self, from: Data(contentsOf: url))
    }
    public static var noticeURL: URL? { Bundle.module.url(forResource: "SymbolCatalogNotice", withExtension: "txt") }
    public static var dataLicenseURL: URL? { Bundle.module.url(forResource: "SymbolDataLicenses", withExtension: "html") }
}

/// Symbol usage only. Clipboard contents are managed separately by the host.
public struct SymbolKeyboardHistory {
    public static let storageKey = "symbol.history"
    private var entries: [String: [String]]
    public init(defaults: UserDefaults) {
        entries = [:]
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 1_000_000,
           let values = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for mode in SymbolKeyboardMode.allCases where mode != .clipboard {
                var seen = Set<String>()
                entries[mode.rawValue] = Array((values[mode.rawValue] ?? []).filter {
                    !$0.isEmpty && $0.utf8.count <= 4096 && seen.insert($0).inserted
                }.prefix(100))
            }
        }
    }
    public func symbols(for mode: SymbolKeyboardMode) -> [String] { entries[mode.rawValue] ?? [] }
    public mutating func record(_ symbol: String, mode: SymbolKeyboardMode, defaults: UserDefaults) {
        guard mode != .clipboard, !symbol.isEmpty, symbol.utf8.count <= 4096 else { return }
        var values = symbols(for: mode); values.removeAll { $0 == symbol }; values.insert(symbol, at: 0)
        entries[mode.rawValue] = Array(values.prefix(100)); save(defaults)
    }
    public mutating func remove(_ symbol: String, mode: SymbolKeyboardMode, defaults: UserDefaults) {
        entries[mode.rawValue]?.removeAll { $0 == symbol }; save(defaults)
    }
    private func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
    }
}
