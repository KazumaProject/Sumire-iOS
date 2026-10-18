import Foundation

public struct RomajiProfile: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var rules: [String: RomajiRule]
    public var autoSokuon: Bool
    public var autoN: Bool
    public init(name: String, rules: [String: RomajiRule], autoSokuon: Bool = true, autoN: Bool = true) {
        self.name = name; self.rules = rules; self.autoSokuon = autoSokuon; self.autoN = autoN
    }
    public var converter: RomajiConverter { RomajiConverter(rules: rules, autoSokuon: autoSokuon, autoN: autoN) }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              rules.count <= 10000 else { throw PersonalDataError("ローマ字設定の名前または規則数が不正です") }
        for (key, rule) in rules {
            guard !key.isEmpty, key.utf16.count <= 64, rule.first.utf8.count <= 4096,
                  !key.contains("\0"), !rule.first.contains("\0"),
                  (1...key.utf16.count).contains(rule.second) else {
                throw PersonalDataError("規則「\(key.prefix(64))」が不正です。消費文字数は入力のUTF-16長以内の正数にしてください")
            }
            let boundary = key.utf16.index(key.utf16.startIndex, offsetBy: rule.second)
            guard String.Index(boundary, within: key) != nil else {
                throw PersonalDataError("規則「\(key.prefix(64))」の消費文字数が文字の途中を指しています")
            }
        }
    }
}
public struct RomajiLibrary: Codable, Equatable {
    public var version = 1
    public var profiles: [RomajiProfile] = []
    public var activeID: UUID?
    public init() {}
    public static let storageKey = "customRomaji.library"
    public static let maximumBytes = 4 * 1024 * 1024
    public func validate() throws {
        guard version == 1, profiles.count <= 100,
              Set(profiles.map(\.id)).count == profiles.count,
              activeID == nil || profiles.contains(where: { $0.id == activeID }) else {
            throw PersonalDataError("ローマ字設定の形式または選択が不正です")
        }
        for profile in profiles { try profile.validate() }
    }
    public func converter() throws -> RomajiConverter {
        try validate()
        return try profiles.first(where: { $0.id == activeID })?.converter ?? RomajiConverter.standard()
    }
    public static func load(defaults: UserDefaults) throws -> Self {
        guard let stored = defaults.object(forKey: storageKey) else { return Self() }
        guard let data = stored as? Data else { throw PersonalDataError("ローマ字設定の保存形式が不正です") }
        guard data.count <= maximumBytes else { throw PersonalDataError("ローマ字設定が大きすぎます") }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }
    public func save(defaults: UserDefaults) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw PersonalDataError("ローマ字設定が大きすぎます") }
        defaults.set(data, forKey: Self.storageKey)
    }
    public static func importAndroid(_ data: Data) throws -> [RomajiProfile] {
        let preview = try RomajiImportPreview.parse(data)
        guard preview.errors.isEmpty else { throw PersonalDataError(preview.errors.joined(separator: "\n")) }
        return preview.profiles
    }
}

public struct RomajiImportPreview {
    public let profiles: [RomajiProfile]
    public let errors: [String]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= RomajiLibrary.maximumBytes else { throw PersonalDataError("JSONが大きすぎます") }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any], rows.count <= 100 else {
            throw PersonalDataError("100件以下のローマ字設定JSON配列を指定してください")
        }
        var profiles: [RomajiProfile] = []
        var errors: [String] = []
        for (index, row) in rows.enumerated() {
            do {
                let data = try JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed])
                let map = try JSONDecoder().decode(RomajiMap.self, from: data)
                let profile = RomajiProfile(name: map.name, rules: map.mapData, autoSokuon: map.autoSokuon, autoN: map.autoN)
                try profile.validate()
                profiles.append(profile)
            } catch { errors.append("\(index + 1)件目: \(error.localizedDescription)") }
        }
        return Self(profiles: profiles, errors: errors)
    }
}
