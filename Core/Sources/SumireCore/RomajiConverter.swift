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
    /// Rule insertion order used by reverse alias selection when lengths tie.
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
        let values = try JSONDecoder().decode([String: Pair].self, from: Data(contentsOf: url))
        return RomajiConverter(rules: values.mapValues(\.rule))
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
