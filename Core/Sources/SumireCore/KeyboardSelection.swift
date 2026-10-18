import Foundation

/// Ordered enabled layouts. Removing an item never deletes its custom definition.
public struct KeyboardSelection: Codable, Equatable {
    public static let storageKey = "keyboard.selection"
    public private(set) var ids: [String]
    public init(ids: [String]) throws {
        self.ids = ids
        try validate()
    }
    public func validate() throws {
        guard !ids.isEmpty, ids.count <= 1000, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw PersonalDataError("キーボードは最低1つ必要です。重複した項目は保存できません")
        }
    }
    public mutating func remove(_ removed: Set<String>) {
        let remaining = ids.filter { !removed.contains($0) }
        if !remaining.isEmpty { ids = remaining }
    }
    public static func load(defaults: UserDefaults, available: [String]) -> Self {
        precondition(!available.isEmpty)
        if let data = defaults.data(forKey: storageKey), data.count <= 300_000,
           let saved = try? JSONDecoder().decode(Self.self, from: data),
           (try? saved.validate()) != nil {
            let valid = saved.ids.filter { available.contains($0) }
            return try! Self(ids: valid.isEmpty ? [available[0]] : valid)
        }
        return try! Self(ids: available)
    }
    public func save(defaults: UserDefaults) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
