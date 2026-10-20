import Foundation

/// Edits only selected fields; imported gestures and unknown fields stay intact.
public struct CustomLayoutEditor {
    public private(set) var source: LayoutJSON
    public init(layout: ImportedCustomLayout) { source = CustomKeyboardLibrary.canonicalSource(layout) }
    public init(name: String = "新しい配列", rows: Int = 4, columns: Int = 5) {
        source = .object([
            "layout": .object(["stableId": .string(UUID().uuidString), "name": .string(name),
                               "rowCount": .integer(Int64(rows)), "columnCount": .integer(Int64(columns))]),
            "keysWithFlicks": .array([]), "spacers": .array([])
        ])
    }
    private func setting(_ object: LayoutJSON, _ fields: [String: LayoutJSON]) -> LayoutJSON {
        guard case .object(var values) = object else { return object }
        values.merge(fields) { _, new in new }
        return .object(values)
    }
    public mutating func configure(name: String, rows: Int, columns: Int) {
        guard let metadata = source["layout"] else { return }
        source = setting(source, ["layout": setting(metadata, ["name": .string(name),
            "rowCount": .integer(Int64(rows)), "columnCount": .integer(Int64(columns))])])
    }
    public mutating func setInputMode(romaji: Bool, direct: Bool) {
        guard let metadata = source["layout"] else { return }
        source = setting(source, ["layout": setting(metadata, ["isRomaji": .bool(romaji), "isDirectMode": .bool(direct)])])
    }
    public mutating func putKey(id: String, label: String, action: String, special: Bool,
                                row: Int, column: Int, height: Int, width: Int) {
        var keys = source["keysWithFlicks"]?.array ?? []
        let index = keys.firstIndex { $0["key"]?["keyIdentifier"]?.string == id }
        var item = index.map { keys[$0] } ?? .object(["key": .object(["keyType": .string("NORMAL")])])
        let fields: [String: LayoutJSON] = ["keyIdentifier": .string(id), "label": .string(label),
            "action": .string(action), "isSpecialKey": .bool(special), "rowUnits": .integer(Int64(row)),
            "columnUnits": .integer(Int64(column)), "rowSpanUnits": .integer(Int64(height)), "columnSpanUnits": .integer(Int64(width))]
        item = setting(item, ["key": setting(item["key"] ?? .object([:]), fields)])
        if let index { keys[index] = item } else { keys.append(item) }
        source = setting(source, ["keysWithFlicks": .array(keys)])
    }
    public mutating func setKeyType(id: String, type: String) throws {
        guard ["NORMAL", "STANDARD_FLICK"].contains(type) else { throw PersonalDataError("この入力方式の編集は未対応です") }
        var keys = source["keysWithFlicks"]?.array ?? []
        guard let index = keys.firstIndex(where: { $0["key"]?["keyIdentifier"]?.string == id }), let definition = keys[index]["key"] else {
            throw PersonalDataError("編集対象のキーがありません")
        }
        keys[index] = setting(keys[index], ["key": setting(definition, ["keyType": .string(type)])])
        source = setting(source, ["keysWithFlicks": .array(keys)])
    }
    public mutating func setDoubleTap(id: String, enabled: Bool, action: String) throws {
        guard !enabled || !action.isEmpty else { throw PersonalDataError("ダブルタップの操作を指定してください") }
        var keys = source["keysWithFlicks"]?.array ?? []
        guard let index = keys.firstIndex(where: { $0["key"]?["keyIdentifier"]?.string == id }),
              let definition = keys[index]["key"] else { throw PersonalDataError("編集対象のキーがありません") }
        let promote = definition["action"]?.string == "ShiftKeyPressed" && action == "CapLockKey"
        keys[index] = setting(keys[index], ["key": setting(definition, [
            "doubleTapEnabled": .bool(enabled), "doubleTapAction": .string(action),
            "doubleTapPolicy": .string(promote ? "PROMOTE" : "EXCLUSIVE")])])
        source = setting(source, ["keysWithFlicks": .array(keys)])
    }
    public mutating func setStandardFlick(id: String, values: [String]) throws {
        guard values.count == 5 else { throw PersonalDataError("標準フリックには5方向の文字を指定してください") }
        var keys = source["keysWithFlicks"]?.array ?? []
        guard let index = keys.firstIndex(where: { $0["key"]?["keyIdentifier"]?.string == id }) else {
            throw PersonalDataError("編集対象のキーがありません")
        }
        let mappings = keys[index]["flicks"]?.array ?? []
        let state = mappings.map { $0["stateIndex"]?.integer ?? 0 }.min() ?? 0
        let current = mappings.filter { ($0["stateIndex"]?.integer ?? 0) == state }
        let directions = ["TAP", "UP_LEFT_FAR", "UP", "UP_RIGHT_FAR", "DOWN"]
        var updated: [LayoutJSON] = []
        for (direction, value) in zip(directions, values) {
            let side = direction == "UP_LEFT_FAR" ? "LEFT" : direction == "UP_RIGHT_FAR" ? "RIGHT" : nil
            let old = current.first { $0["flickDirection"]?.string == direction }
                ?? side.flatMap { side in current.first { $0["flickDirection"]?.string?.contains(side) == true } }
                ?? .object([:])
            updated.append(setting(old, ["stateIndex": .integer(state), "flickDirection": .string(direction),
                                        "actionType": .string("INPUT_TEXT"), "actionValue": .string(value)]))
        }
        updated += mappings.filter { ($0["stateIndex"]?.integer ?? 0) != state }
        keys[index] = setting(keys[index], ["flicks": .array(updated)])
        source = setting(source, ["keysWithFlicks": .array(keys)])
    }
    public mutating func removeKey(id: String) {
        source = setting(source, ["keysWithFlicks": .array((source["keysWithFlicks"]?.array ?? []).filter {
            $0["key"]?["keyIdentifier"]?.string != id
        })])
    }
    public func validated() throws -> ImportedCustomLayout {
        let preview = try CustomLayoutImportPreview.parse(JSONEncoder().encode(source))
        guard preview.errors.isEmpty, let layout = preview.layouts.first else {
            throw PersonalDataError(preview.errors.joined(separator: "\n"))
        }
        return layout
    }
}
