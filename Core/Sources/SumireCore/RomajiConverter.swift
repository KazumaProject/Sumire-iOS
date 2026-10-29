import Foundation

/// Port of Sumire's CustomRomajiScreenConverter at df1f38315bf56d860d32919a3eaed6a75499e91e.
/// Consumption counts are UTF-16 code units, matching Kotlin String indexing.
public struct RomajiRule: Codable, Equatable {
    public let first: String
    public let second: Int
    public init(_ output: String, _ consumption: Int) { first = output; second = consumption }
}
public struct RomajiMap: Decodable {
    public let id: Int64?
    public let name: String
    public let mapData: [String: RomajiRule]
    public let isActive: Bool
    public let isDeletable: Bool
    public let autoSokuon: Bool
    public let autoN: Bool
    enum CodingKeys: String, CodingKey { case id, name, mapData, isActive, isDeletable, autoSokuon, autoN }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mapData = try c.decode([String: RomajiRule].self, forKey: .mapData)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isDeletable = try c.decodeIfPresent(Bool.self, forKey: .isDeletable) ?? true
        autoSokuon = try c.decodeIfPresent(Bool.self, forKey: .autoSokuon) ?? true
        autoN = try c.decodeIfPresent(Bool.self, forKey: .autoN) ?? true
    }
}
public struct RomajiConverter {
    public let rules: [String: RomajiRule]
    /// Rule insertion order used by Android's reverse kana map when aliases
    /// have equal lengths. Dictionary lookup remains keyed by `rules`.
    public let ruleOrder: [String]
    public let autoSokuon: Bool
    public let autoN: Bool
    private let maxKeyLength: Int
    public init(
        rules: [String: RomajiRule],
        autoSokuon: Bool = true,
        autoN: Bool = true,
        ruleOrder: [String]? = nil
    ) {
        self.rules = rules
        self.ruleOrder = Self.completedRuleOrder(ruleOrder, for: rules)
        self.autoSokuon = autoSokuon
        self.autoN = autoN
        maxKeyLength = rules.keys.map { $0.utf16.count }.max() ?? 0
    }
    public static func standard() throws -> RomajiConverter {
        struct Pair: Decodable {
            let rule: RomajiRule
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                rule = RomajiRule(try c.decode(String.self), try c.decode(Int.self))
            }
        }
        let url = Bundle.module.url(forResource: "default-312", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let values = try JSONDecoder().decode([String: Pair].self, from: data)
        let ruleOrder = try TopLevelJSONObjectKeyOrder.keys(in: data)
        return RomajiConverter(rules: values.mapValues(\.rule), ruleOrder: ruleOrder)
    }
    public func convert(_ text: String) -> String {
        let input = Array(text.utf16)
        let sokuon = Set("kstcpbdfghljmqrvwxyz".utf16)
        let excludedN = Set("aiueoyn".utf16)
        var output: [UInt16] = []
        var index = 0
        while index < input.count {
            let current = ascii(input[index])
            let next = index + 1 < input.count ? ascii(input[index + 1]) : nil
            if autoSokuon, sokuon.contains(current), next == current {
                output.append(contentsOf: "っ".utf16); index += 1; continue
            }
            if autoN, current == 110, let next, (97...122).contains(next), !excludedN.contains(next) {
                output.append(contentsOf: "ん".utf16); index += 1; continue
            }
            var matched = false
            let length = min(maxKeyLength, input.count - index)
            if length > 0 {
                for n in stride(from: length, through: 1, by: -1) {
                    let key = String(decoding: input[index..<(index + n)], as: UTF16.self)
                    guard let rule = rules[key] else { continue }
                    output.append(contentsOf: rule.first.utf16)
                    index += min(max(rule.second, 1), input.count - index)
                    matched = true; break
                }
            }
            if !matched { output.append(input[index]); index += 1 }
        }
        return String(decoding: output, as: UTF16.self)
    }
    public func flush(_ text: String) -> String {
        guard autoN, let last = text.utf16.last, ascii(last) == 110 else { return text }
        return String(decoding: text.utf16.dropLast(), as: UTF16.self) + "ん"
    }
    private func ascii(_ unit: UInt16) -> UInt16 { (0xFF41...0xFF5A).contains(unit) ? unit - 0xFEE0 : unit }

    private static func completedRuleOrder(_ requested: [String]?, for rules: [String: RomajiRule]) -> [String] {
        var seen = Set<String>()
        var result = (requested ?? []).filter { rules[$0] != nil && seen.insert($0).inserted }
        let remaining = rules.keys.filter { seen.insert($0).inserted }.sorted {
            Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16))
        }
        result.append(contentsOf: remaining)
        return result
    }
}

/// JSONDecoder correctly decodes the fixed map but intentionally exposes JSON
/// objects as dictionaries, losing key order. Android's RomajiKanaConverter
/// keeps the insertion order restored by Room's JSON adapter, so retain the
/// top-level order from this bundled object for equal-length reverse aliases.
private enum TopLevelJSONObjectKeyOrder {
    static func keys(in data: Data) throws -> [String] {
        let bytes = Array(data)
        var index = 0
        skipWhitespace(bytes, &index)
        guard consume(0x7B, bytes, &index) else { throw malformed() }
        var keys: [String] = []
        skipWhitespace(bytes, &index)
        if consume(0x7D, bytes, &index) {
            skipWhitespace(bytes, &index)
            guard index == bytes.count else { throw malformed() }
            return keys
        }

        while index < bytes.count {
            skipWhitespace(bytes, &index)
            let rawKey = try quotedString(bytes, &index)
            keys.append(try JSONDecoder().decode(String.self, from: Data(rawKey)))
            skipWhitespace(bytes, &index)
            guard consume(0x3A, bytes, &index) else { throw malformed() }
            skipWhitespace(bytes, &index)
            try skipValue(bytes, &index)
            skipWhitespace(bytes, &index)
            if consume(0x2C, bytes, &index) { continue }
            if consume(0x7D, bytes, &index) { break }
            throw malformed()
        }

        skipWhitespace(bytes, &index)
        guard index == bytes.count else { throw malformed() }
        return keys
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) throws {
        guard index < bytes.count else { throw malformed() }
        if bytes[index] == 0x22 {
            _ = try quotedString(bytes, &index)
            return
        }

        var closing: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                _ = try quotedString(bytes, &index)
                continue
            }
            if closing.isEmpty, byte == 0x7D { return }
            if closing.isEmpty, byte == 0x5D { throw malformed() }
            if byte == 0x7B { closing.append(0x7D) }
            else if byte == 0x5B { closing.append(0x5D) }
            else if byte == 0x7D || byte == 0x5D {
                guard closing.last == byte else { throw malformed() }
                closing.removeLast()
            } else if byte == 0x2C && closing.isEmpty {
                return
            }
            index += 1
            if closing.isEmpty && (byte == 0x7D || byte == 0x5D) { return }
        }
        if !closing.isEmpty { throw malformed() }
    }

    private static func quotedString(_ bytes: [UInt8], _ index: inout Int) throws -> [UInt8] {
        guard index < bytes.count, bytes[index] == 0x22 else { throw malformed() }
        let start = index
        index += 1
        while index < bytes.count {
            if bytes[index] == 0x5C {
                index += 2
                continue
            }
            if bytes[index] == 0x22 {
                index += 1
                return Array(bytes[start..<index])
            }
            index += 1
        }
        throw malformed()
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    @discardableResult
    private static func consume(_ byte: UInt8, _ bytes: [UInt8], _ index: inout Int) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func malformed() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid ordered Romaji JSON object"))
    }
}
