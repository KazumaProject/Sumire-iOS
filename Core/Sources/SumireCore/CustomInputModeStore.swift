import Foundation

public struct CustomInputMode: Codable, Equatable {
    public var direct: Bool
    public var romaji: Bool
    public init(direct: Bool, romaji: Bool) { self.direct = direct; self.romaji = romaji }
}

/// Per-stable-layout input mode memory. Callers opt into remembering explicitly;
/// neither mode transitions nor preference toggles are inferred by this store.
public struct CustomInputModeStore: Codable, Equatable {
    public static let storageKey = "customKeyboard.inputModes"
    public static let rememberKey = "customKeyboard.rememberInputMode"
    public static let replaceKey = "customKeyboard.replaceComposingOnDirectInput"
    public static let maximumBytes = 1024 * 1024
    private var version = 1
    private var states: [String: CustomInputMode] = [:]
    public init() {}

    public func state(for layout: ImportedCustomLayout, remember: Bool) -> CustomInputMode {
        if remember, let stored = states[layout.id] { return stored }
        return CustomInputMode(direct: layout.source["layout"]?["isDirectMode"] == .bool(true),
                               romaji: layout.source["layout"]?["isRomaji"] == .bool(true))
    }
    public mutating func set(state: CustomInputMode, for id: String) throws {
        var next = self
        next.states[id] = state
        try next.validate()
        self = next
    }
    /// Remove memory for deleted layouts before an explicit remembered-mode save.
    public mutating func retain(layoutIDs: Set<String>) {
        states = states.filter { layoutIDs.contains($0.key) }
    }
    public func validate() throws {
        guard version == 1, states.count <= 100,
              states.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              try JSONEncoder().encode(self).count <= Self.maximumBytes else {
            throw PersonalDataError("カスタム配列の入力モード保存データが不正です")
        }
    }
    public func save(defaults: UserDefaults) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PersonalDataError("入力モード保存データが大きすぎます") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    public static func load(defaults: UserDefaults) throws -> Self {
        guard let raw = defaults.object(forKey: storageKey) else { return Self() }
        guard let data = raw as? Data else { throw PersonalDataError("入力モード保存データの型が不正です") }
        return try decode(data)
    }
}
