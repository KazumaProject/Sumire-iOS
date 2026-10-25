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
                  (1...Int(Int32.max)).contains(rule.second) else {
                throw PersonalDataError("規則「\(key.prefix(64))」が不正です。消費文字数は32-bit正数にしてください")
            }
            if rule.second <= key.utf16.count {
                let boundary = key.utf16.index(key.utf16.startIndex, offsetBy: rule.second)
                guard String.Index(boundary, within: key) != nil else {
                    throw PersonalDataError("規則「\(key.prefix(64))」の消費文字数が文字の途中を指しています")
                }
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
        return preview.profiles
    }
}

public struct RomajiImportPreview {
    public let profiles: [RomajiProfile]
    public let errors: [String]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= RomajiLibrary.maximumBytes else { throw PersonalDataError("JSONが大きすぎます") }
        let normalizedData = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        let root = try AndroidRomajiJSONParser.parse(normalizedData)
        let rows: [(Int, AndroidRomajiJSONValue)]
        switch root {
        case .array(let values):
            guard values.count <= 100 else {
                throw PersonalDataError("100件以下のローマ字設定JSON配列を指定してください")
            }
            rows = values.enumerated().compactMap { index, value in
                guard case .object = value else { return nil }
                return (index, value)
            }
        case .object(let fields):
            let wrapperKeys = ["maps", "romajiMaps", "romaji_maps", "items", "list"]
            if let wrapped = wrapperKeys.lazy.compactMap({ key in
                fields.first(where: { $0.0 == key })?.1.arrayValue
            }).first {
                guard wrapped.count <= 100 else {
                    throw PersonalDataError("100件以下のローマ字設定JSON配列を指定してください")
                }
                rows = wrapped.enumerated().compactMap { index, value in
                    guard case .object = value else { return nil }
                    return (index, value)
                }
            } else {
                rows = [(0, root)]
            }
        default:
            throw PersonalDataError("100件以下のローマ字設定JSON配列またはオブジェクトを指定してください")
        }
        guard rows.count <= 100 else {
            throw PersonalDataError("100件以下のローマ字設定JSON配列を指定してください")
        }
        var profiles: [RomajiProfile] = []
        var errors: [String] = []
        for (index, row) in rows {
            do {
                guard case .object(let fields) = row else {
                    throw PersonalDataError("オブジェクトではありません")
                }
                let name = firstString(in: fields, keys: ["name", "mapName", "title"])
                guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PersonalDataError("名前がありません")
                }

                var rules: [String: RomajiRule] = [:]
                for key in ["mapData", "map", "data"] {
                    guard let value = fields.first(where: { $0.0 == key })?.1 else { continue }
                    let parsed = try parseRules(from: value)
                    if !parsed.isEmpty {
                        rules = parsed
                        break
                    }
                }
                guard !rules.isEmpty else { throw PersonalDataError("有効な規則がありません") }

                let profile = RomajiProfile(
                    name: name,
                    rules: rules,
                    autoSokuon: readBoolean(in: fields, key: "autoSokuon") ?? true,
                    autoN: readBoolean(in: fields, key: "autoN") ?? true
                )
                try profile.validate()
                profiles.append(profile)
            } catch { errors.append("\(index + 1)件目: \(error.localizedDescription)") }
        }
        return Self(profiles: profiles, errors: errors)
    }

    private static func firstString(in fields: [(String, AndroidRomajiJSONValue)], keys: [String]) -> String? {
        for key in keys {
            if let value = fields.first(where: { $0.0 == key })?.1.stringValue { return value }
        }
        return nil
    }

    private static func readBoolean(in fields: [(String, AndroidRomajiJSONValue)], key: String) -> Bool? {
        guard let value = fields.first(where: { $0.0 == key })?.1 else { return nil }
        switch value {
        case .boolean(let result): return result
        case .string("true"): return true
        case .string("false"): return false
        default: return nil
        }
    }

    private static func parseRules(from value: AndroidRomajiJSONValue) throws -> [String: RomajiRule] {
        let fields: [(String, AndroidRomajiJSONValue)]
        switch value {
        case .object(let object):
            fields = object
        case .string(let json):
            guard let nested = try? AndroidRomajiJSONParser.parse(Data(json.utf8)) else { return [:] }
            guard case .object(let object) = nested else { return [:] }
            fields = object
        default:
            return [:]
        }

        let parsed = try parseRuleEntries(fields)
        if !parsed.isEmpty { return parsed }

        // Android has a second, compact-map fallback for object-valued maps.
        // It accepts decimal numeric strings here; its normal Room converter
        // only accepts integer strings.
        return try parseCompactRuleEntries(fields)
    }

    private static func parseRuleEntries(_ fields: [(String, AndroidRomajiJSONValue)]) throws -> [String: RomajiRule] {
        var rules: [String: RomajiRule] = [:]
        for (key, value) in fields {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .object(let ruleFields) = value else { continue }
            let kana = firstString(in: ruleFields, keys: ["kana", "first"]) ??
                ruleFields.compactMap { $0.1.stringValue }.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            guard let kana, !kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let consume = readInteger(in: ruleFields, key: "consume") ??
                readInteger(in: ruleFields, key: "second") ??
                ruleFields.compactMap { $0.1.androidIntegerValue(allowDecimalString: false) }.first ??
                key.utf16.count
            rules[key] = RomajiRule(kana, max(consume, 1))
            guard rules.count <= 10_000 else { throw PersonalDataError("ローマ字規則が多すぎます") }
        }
        return rules
    }

    private static func parseCompactRuleEntries(_ fields: [(String, AndroidRomajiJSONValue)]) throws -> [String: RomajiRule] {
        var rules: [String: RomajiRule] = [:]
        for (key, value) in fields {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .object(let ruleFields) = value else { continue }
            let kana = firstString(in: ruleFields, keys: ["c", "kana"])
            guard let kana, !kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let consume = readInteger(in: ruleFields, key: "d", allowDecimalString: true) ??
                readInteger(in: ruleFields, key: "consume", allowDecimalString: true) ?? key.utf16.count
            rules[key] = RomajiRule(kana, max(consume, 1))
            guard rules.count <= 10_000 else { throw PersonalDataError("ローマ字規則が多すぎます") }
        }
        return rules
    }

    private static func readInteger(
        in fields: [(String, AndroidRomajiJSONValue)],
        key: String,
        allowDecimalString: Bool = false
    ) -> Int? {
        fields.first(where: { $0.0 == key })?.1.androidIntegerValue(allowDecimalString: allowDecimalString)
    }
}

/// An ordered JSON tree used to match Android's insertion-ordered Gson objects.
private indirect enum AndroidRomajiJSONValue {
    case object([(String, AndroidRomajiJSONValue)])
    case array([AndroidRomajiJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    var arrayValue: [AndroidRomajiJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    func androidIntegerValue(allowDecimalString: Bool) -> Int? {
        switch self {
        case .number(let value):
            guard value.isFinite else { return nil }
            let wrapped = value.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
            return Int(Int32(truncatingIfNeeded: Int64(wrapped)))
        case .string(let value):
            if let integer = Int32(value) { return Int(integer) }
            guard allowDecimalString, let number = Double(value), number.isFinite else { return nil }
            if number >= Double(Int32.max) { return Int(Int32.max) }
            if number <= Double(Int32.min) { return Int(Int32.min) }
            return Int(Int32(number))
        default:
            return nil
        }
    }

}

private struct AndroidRomajiJSONParser {
    private let bytes: [UInt8]
    private let decoder = JSONDecoder()
    private var index = 0
    private var parsedValueCount = 0
    private static let maximumDepth = 256
    private static let maximumValues = 100_000

    private init(data: Data) { bytes = Array(data) }

    static func parse(_ data: Data) throws -> AndroidRomajiJSONValue {
        var parser = Self(data: data)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw PersonalDataError("JSON形式が不正です") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> AndroidRomajiJSONValue {
        guard depth <= Self.maximumDepth, index < bytes.count else { throw PersonalDataError("JSON形式が不正です") }
        parsedValueCount += 1
        guard parsedValueCount <= Self.maximumValues else {
            throw PersonalDataError("JSONの要素数が多すぎます")
        }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74:
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            return .boolean(true)
        case 0x66:
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            return .boolean(false)
        case 0x6E:
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) throws -> AndroidRomajiJSONValue {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return .object([]) }

        var fields: [(String, AndroidRomajiJSONValue)] = []
        var fieldIndices: [String: Int] = [:]
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw PersonalDataError("JSON形式が不正です") }
            let key = try parseString()
            skipWhitespace()
            guard consume(0x3A) else { throw PersonalDataError("JSON形式が不正です") }
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            if let existing = fieldIndices[key] {
                fields[existing].1 = value
            } else {
                fieldIndices[key] = fields.count
                fields.append((key, value))
            }
            skipWhitespace()
            if consume(0x7D) { return .object(fields) }
            guard consume(0x2C) else { throw PersonalDataError("JSON形式が不正です") }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> AndroidRomajiJSONValue {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return .array([]) }

        var values: [AndroidRomajiJSONValue] = []
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if consume(0x5D) { return .array(values) }
            guard consume(0x2C) else { throw PersonalDataError("JSON形式が不正です") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw PersonalDataError("JSON形式が不正です") }
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                return try decoder.decode(String.self, from: Data(bytes[start..<index]))
            case 0x5C:
                index += 2
            default:
                index += 1
            }
        }
        throw PersonalDataError("JSON形式が不正です")
    }

    private mutating func parseNumber() throws -> AndroidRomajiJSONValue {
        let start = index
        while index < bytes.count && !isValueDelimiter(bytes[index]) { index += 1 }
        guard start < index else { throw PersonalDataError("JSON形式が不正です") }
        let token = Data(bytes[start..<index])
        return .number(try decoder.decode(Double.self, from: token))
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw PersonalDataError("JSON形式が不正です")
        }
        index += literal.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func isValueDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D: return true
        default: return false
        }
    }
}
