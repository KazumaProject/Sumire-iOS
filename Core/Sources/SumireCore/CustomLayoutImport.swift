import Foundation

/// Preserve external fields (including actions not executable on iOS) for review
/// and later editing. Integer IDs remain Int64, never rounded through Double.
public enum LayoutJSON: Codable, Equatable {
    case object([String: LayoutJSON]), array([LayoutJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw PersonalDataError("配列JSONの入れ子が深すぎます") }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LayoutJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LayoutJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> LayoutJSON? { if case .object(let v) = self { return v[key] }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    public var array: [LayoutJSON]? { if case .array(let v) = self { return v }; return nil }
}

public struct ImportedCustomLayout: Codable, Equatable, Identifiable {
    public struct Placement: Codable, Equatable {
        public let id: String
        /// Half-cell units, matching Android rowUnits/columnUnits.
        public let row: Int, column: Int, height: Int, width: Int
        public let isSpacer: Bool
        public let source: LayoutJSON
    }
    public let id: String
    public let originalLayoutID: Int64?
    public let name: String
    public let rows: Int, columns: Int
    public let placements: [Placement]
    public let source: LayoutJSON
}
public struct CustomLayoutImportPreview {
    public let schemaVersion: Int
    public let layouts: [ImportedCustomLayout]
    public let errors: [String]
    public let warnings: [String]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw PersonalDataError("配列ファイルは8 MiBまでです") }
        let root = try JSONDecoder().decode(LayoutJSON.self, from: data)
        let version: Int
        let rows: [LayoutJSON]
        if let array = root.array { version = 0; rows = array }
        else {
            if let raw = root["schemaVersion"], raw != .null {
                guard let n = raw.integer, (1...4).contains(n) else { throw PersonalDataError("未対応の配列schemaVersionです") }
                version = Int(n)
                guard let array = root["layouts"]?.array else { throw PersonalDataError("layouts配列がありません") }
                rows = array
            } else {
                version = 0
                if let array = root["layouts"]?.array { rows = array }
                else if root["layout"] != nil || root["keysWithFlicks"] != nil { rows = [root] }
                else { throw PersonalDataError("配列バックアップの形式ではありません") }
            }
        }
        guard !rows.isEmpty, rows.count <= 100 else { throw PersonalDataError("配列は1〜100件にしてください") }
        var layouts: [ImportedCustomLayout] = [], errors: [String] = [], warnings: [String] = []
        var ids = Set<String>()
        for (index, source) in rows.enumerated() {
            do {
                guard let metadata = source["layout"], case .object = metadata,
                      let keys = source["keysWithFlicks"]?.array, keys.count <= 4096 else {
                    throw PersonalDataError("layoutまたはkeysWithFlicksが不正です")
                }
                if let rawID = metadata["layoutId"], rawID != .null, rawID.integer == nil {
                    throw PersonalDataError("layoutIdは64ビット整数にしてください")
                }
                func integer(_ object: LayoutJSON, _ name: String, _ fallback: Int) throws -> Int {
                    guard let raw = object[name], raw != .null else { return fallback }
                    guard let number = raw.integer, let value = Int(exactly: number), (0...128).contains(value) else {
                        throw PersonalDataError("\(name)の値が不正です")
                    }
                    return value
                }
                var placements: [ImportedCustomLayout.Placement] = []
                var keyIDs = Set<String>()
                let spacerSource = source["spacers"]
                guard spacerSource == nil || spacerSource == .null || spacerSource?.array != nil else { throw PersonalDataError("spacersが配列ではありません") }
                let spacers = spacerSource?.array ?? []
                guard keys.count + spacers.count <= 4096 else { throw PersonalDataError("キー・空白領域が多すぎます") }
                for (itemIndex, item) in (keys + spacers).enumerated() {
                    let spacer = itemIndex >= keys.count
                    guard let definition = spacer ? item : item["key"], case .object = definition else { throw PersonalDataError("キー定義が不正です") }
                    let idField = spacer ? "itemIdentifier" : "keyIdentifier"
                    let rawID = definition[idField]?.string ?? ""
                    let id = rawID.isEmpty ? UUID().uuidString : rawID
                    guard id.utf8.count <= 256, keyIDs.insert(id).inserted else { throw PersonalDataError("キー識別子が重複または長すぎます") }
                    let row = try integer(definition, "rowUnits", integer(definition, "row", 0) * 2)
                    let column = try integer(definition, "columnUnits", integer(definition, "column", 0) * 2)
                    let height = try integer(definition, "rowSpanUnits", spacer ? 1 : integer(definition, "rowSpan", 1) * 2)
                    let width = try integer(definition, "columnSpanUnits", spacer ? 1 : integer(definition, "colSpan", 1) * 2)
                    guard height > 0, width > 0, row + height <= 128, column + width <= 128 else { throw PersonalDataError("配置範囲が不正です") }
                    placements.append(.init(id: id, row: row, column: column, height: height, width: width, isSpacer: spacer, source: item))
                }
                let endRow = placements.map { $0.row + $0.height }.max() ?? 2
                let endColumn = placements.map { $0.column + $0.width }.max() ?? 2
                let height = try integer(metadata, "rowCount", (endRow + 1) / 2)
                let width = try integer(metadata, "columnCount", (endColumn + 1) / 2)
                guard (1...64).contains(height), (1...64).contains(width) else { throw PersonalDataError("配列寸法が不正です") }
                var occupied = Set<Int>()
                for placement in placements {
                    guard placement.row + placement.height <= height * 2, placement.column + placement.width <= width * 2 else { throw PersonalDataError("配列の外にキーまたは空白領域があります") }
                    for r in placement.row..<(placement.row + placement.height) {
                        for c in placement.column..<(placement.column + placement.width) {
                            guard occupied.insert(r * width * 2 + c).inserted else { throw PersonalDataError("キーまたは空白領域が重なっています") }
                        }
                    }
                }
                let rawID = metadata["stableId"]?.string ?? ""
                let id = rawID.isEmpty ? UUID().uuidString : rawID
                guard id.utf8.count <= 256, !ids.contains(id) else { throw PersonalDataError("配列識別子が重複または長すぎます") }
                if rawID.isEmpty { warnings.append("\(index + 1)件目: stableIdを生成しました") }
                let name = metadata["name"]?.string ?? "取り込み配列\(index + 1)"
                guard name.utf8.count <= 256 else { throw PersonalDataError("配列名が長すぎます") }
                ids.insert(id)
                layouts.append(.init(id: id, originalLayoutID: metadata["layoutId"]?.integer, name: name, rows: height, columns: width, placements: placements, source: source))
            } catch { errors.append("\(index + 1)件目: \(error.localizedDescription)") }
        }
        return Self(schemaVersion: version, layouts: layouts, errors: errors, warnings: warnings)
    }
}
