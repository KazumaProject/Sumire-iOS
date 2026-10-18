import Foundation

public struct CustomKeyboardLibrary: Codable, Equatable {
    public var version = 1
    public var sources: [LayoutJSON] = []
    public var activeID: String?
    public init() {}
    public static let storageKey = "customKeyboard.library"
    public static let maximumBytes = 8 * 1024 * 1024
    public func layouts() throws -> [ImportedCustomLayout] {
        guard version == 1, sources.count <= 100 else { throw PersonalDataError("未対応のカスタム配列保存形式です") }
        if sources.isEmpty {
            guard activeID == nil else { throw PersonalDataError("選択した配列がありません") }
            return []
        }
        guard sources.allSatisfy({ !($0["layout"]?["stableId"]?.string ?? "").isEmpty }) else {
            throw PersonalDataError("保存配列にstableIdがありません")
        }
        let preview = try CustomLayoutImportPreview.parse(JSONEncoder().encode(sources))
        guard preview.errors.isEmpty else { throw PersonalDataError(preview.errors.joined(separator: "\n")) }
        guard activeID == nil || preview.layouts.contains(where: { $0.id == activeID }) else { throw PersonalDataError("選択した配列がありません") }
        return preview.layouts
    }
    public mutating func append(_ layouts: [ImportedCustomLayout]) throws {
        var next = self
        next.sources += layouts.map(Self.canonicalSource)
        _ = try next.layouts()
        guard try JSONEncoder().encode(next).count <= Self.maximumBytes else { throw PersonalDataError("カスタム配列が大きすぎます") }
        self = next
    }
    public mutating func replace(_ layout: ImportedCustomLayout) throws {
        var next = self
        guard let index = next.sources.firstIndex(where: { $0["layout"]?["stableId"]?.string == layout.id }) else {
            throw PersonalDataError("編集対象の配列が見つかりません")
        }
        next.sources[index] = Self.canonicalSource(layout)
        _ = try next.layouts()
        guard try JSONEncoder().encode(next).count <= Self.maximumBytes else { throw PersonalDataError("カスタム配列が大きすぎます") }
        self = next
    }
    public mutating func remove(id: String) throws {
        var next = self
        next.sources.removeAll { $0["layout"]?["stableId"]?.string == id }
        if next.activeID == id { next.activeID = nil }
        _ = try next.layouts()
        self = next
    }
    public func save(defaults: UserDefaults) throws {
        _ = try layouts()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw PersonalDataError("カスタム配列が大きすぎます") }
        defaults.set(data, forKey: Self.storageKey)
    }
    public static func load(defaults: UserDefaults) throws -> Self {
        guard let raw = defaults.object(forKey: storageKey) else { return Self() }
        guard let data = raw as? Data, data.count <= maximumBytes else { throw PersonalDataError("カスタム配列の保存データが不正です") }
        let library = try JSONDecoder().decode(Self.self, from: data)
        _ = try library.layouts()
        return library
    }
    static func canonicalSource(_ layout: ImportedCustomLayout) -> LayoutJSON {
        func set(_ source: LayoutJSON, _ key: String, _ value: LayoutJSON) -> LayoutJSON {
            guard case .object(var fields) = source else { return source }
            fields[key] = value
            return .object(fields)
        }
        var source = layout.source
        if let metadata = source["layout"] { source = set(source, "layout", set(metadata, "stableId", .string(layout.id))) }
        let keys = layout.placements.filter { !$0.isSpacer }.map { item -> LayoutJSON in
            guard let definition = item.source["key"] else { return item.source }
            return set(item.source, "key", set(definition, "keyIdentifier", .string(item.id)))
        }
        let spacers = layout.placements.filter(\.isSpacer).map { set($0.source, "itemIdentifier", .string($0.id)) }
        source = set(source, "keysWithFlicks", .array(keys))
        return set(source, "spacers", .array(spacers))
    }
}
