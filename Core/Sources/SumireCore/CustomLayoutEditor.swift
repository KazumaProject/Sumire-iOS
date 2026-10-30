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
        guard ["NORMAL", "STANDARD_FLICK", "PETAL_FLICK", "CENTER_GUIDE_FLICK", "CROSS_FLICK",
               "CIRCULAR_FLICK", "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK", "FLICK_LONG_PRESS"].contains(type) else { throw PersonalDataError("この入力方式の編集は未対応です") }
        var keys = source["keysWithFlicks"]?.array ?? []
        guard let index = keys.firstIndex(where: { $0["key"]?["keyIdentifier"]?.string == id }), let definition = keys[index]["key"] else {
            throw PersonalDataError("編集対象のキーがありません")
        }
        keys[index] = setting(keys[index], ["key": setting(definition, ["keyType": .string(type)])])
        source = setting(source, ["keysWithFlicks": .array(keys)])
    }
    /// Replaces only the selected exported mapping array, preserving row metadata.
    public mutating func setGestureMappings(id: String, field: String, mappings: [LayoutJSON]) throws {
        try setGestureMappings(id: id, fields: [field: mappings])
    }
    /// Multiple arrays are validated and saved together, so an empty normal map
    /// can be replaced atomically by a valid long-press map. Errors leave source intact.
    public mutating func setGestureMappings(id: String, fields: [String: [LayoutJSON]]) throws {
        let allowed: Set<String> = ["flicks", "longPressFlicks", "circularFlicks", "twoStepFlicks", "twoStepLongPressFlicks"]
        guard fields.keys.allSatisfy(allowed.contains), fields.values.allSatisfy({ $0.count <= 4096 }) else {
            throw PersonalDataError("編集するジェスチャーの項目または件数が不正です")
        }
        var keys = source["keysWithFlicks"]?.array ?? []
        guard let index = keys.firstIndex(where: { $0["key"]?["keyIdentifier"]?.string == id }) else {
            throw PersonalDataError("編集対象のキーがありません")
        }
        keys[index] = setting(keys[index], fields.mapValues(LayoutJSON.array))
        var candidate = self
        candidate.source = setting(source, ["keysWithFlicks": .array(keys)])
        let layout = try candidate.validated()
        guard let placement = layout.placements.first(where: { $0.id == id }) else {
            throw PersonalDataError("編集対象のキーがありません")
        }
        if placement.source["key"]?["keyType"]?.string == "CIRCULAR_FLICK",
           fields["circularFlicks"]?.isEmpty == true,
           placement.source["flicks"]?.array?.isEmpty == false {
            throw PersonalDataError("円形フリックを空にすると旧形式の設定が再び有効になります。空にせず割り当てを編集してください")
        }
        let targets = CustomLayoutTargets(layouts: [layout])
        // Validate inactive supplied arrays too; otherwise malformed mappings
        // could remain hidden until the user selects another key type or state.
        for (field, rows) in fields {
            try validateGestureRows(rows, field: field, placement: placement, targets: targets)
        }
        _ = try CustomMultiStageFlick.runtimeDefinition(for: placement, targets: targets)
        source = candidate.source
    }
    private func validateGestureRows(_ rows: [LayoutJSON], field: String,
                                     placement: ImportedCustomLayout.Placement,
                                     targets: CustomLayoutTargets) throws {
        func probe(_ rows: [LayoutJSON], type: String) -> ImportedCustomLayout.Placement {
            let source: LayoutJSON = .object([
                "key": .object(["keyType": .string(type), "action": .string("Text:validation")]),
                field: .array(rows)
            ])
            return ImportedCustomLayout.Placement(id: placement.id, row: placement.row, column: placement.column,
                height: placement.height, width: placement.width, isSpacer: false, source: source)
        }
        switch field {
        case "twoStepFlicks", "twoStepLongPressFlicks":
            _ = try CustomMultiStageFlick.twoStep(probe(rows, type: "TWO_STEP_FLICK"), longPress: field == "twoStepLongPressFlicks")
        case "circularFlicks":
            _ = try CustomMultiStageFlick.circular(probe(rows, type: "CIRCULAR_FLICK"))
        case "flicks":
            for group in Dictionary(grouping: rows, by: { $0["stateIndex"]?.integer ?? 0 }).values {
                _ = try CustomMultiStageFlick.runtimeDefinition(for: probe(group, type: "STANDARD_FLICK"), targets: targets)
            }
        default:
            _ = try CustomMultiStageFlick.runtimeDefinition(for: probe(rows, type: "STANDARD_FLICK"), targets: targets)
        }
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
    /// Exchanges two key placements while keeping each key's definition and
    /// imported metadata attached to its identifier. Spacers stay in place.
    /// The edit is committed only if the complete candidate layout remains valid.
    public mutating func swapKeyPlacements(draggedID: String, targetID: String) throws {
        guard draggedID != targetID else { return }
        let layout = try validated()
        guard let dragged = layout.placements.first(where: { $0.id == draggedID && !$0.isSpacer }),
              let target = layout.placements.first(where: { $0.id == targetID && !$0.isSpacer }) else {
            throw PersonalDataError("交換するキーがありません")
        }

        var keys = source["keysWithFlicks"]?.array ?? []
        let replacements = [draggedID: target, targetID: dragged]
        var updated = Set<String>()
        for index in keys.indices {
            guard let id = keys[index]["key"]?["keyIdentifier"]?.string,
                  let placement = replacements[id],
                  let definition = keys[index]["key"] else { continue }
            let fields: [String: LayoutJSON] = [
                "rowUnits": .integer(Int64(placement.row)),
                "columnUnits": .integer(Int64(placement.column)),
                "rowSpanUnits": .integer(Int64(placement.height)),
                "columnSpanUnits": .integer(Int64(placement.width))
            ]
            keys[index] = setting(keys[index], ["key": setting(definition, fields)])
            updated.insert(id)
        }
        guard updated == Set([draggedID, targetID]) else {
            throw PersonalDataError("交換するキーがありません")
        }

        var candidate = self
        candidate.source = setting(source, ["keysWithFlicks": .array(keys)])
        _ = try candidate.validated()
        source = candidate.source
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
