import Foundation

/// Decodes the exported v1-v4 fields preserved by CustomLayoutImport. The
/// source remains intact; unsupported actions retain their type and payload.
public enum CustomMultiStageFlick {
    public struct RuntimeDefinition {
        public let gesture: ReferenceFlickDefinition
        /// Directional actions are separate from the labels used by the popup.
        /// This lets UIKit execute commands without pretending they are text.
        public let actions: [MultiFlickDirection: CustomKeyAction]
        public let longPressActions: [MultiFlickDirection: CustomKeyAction]
    }

    /// Decodes only gesture types and fields represented by the pinned custom
    /// layout export. Hierarchical custom maps are not part of that export.
    public static func runtimeDefinition(
        for placement: ImportedCustomLayout.Placement,
        targets: CustomLayoutTargets
    ) throws -> RuntimeDefinition? {
        guard let key = placement.source["key"] else { throw invalid("key") }
        let type = key["keyType"]?.string ?? "NORMAL"
        switch type {
        case "NORMAL": return nil
        case "CIRCULAR_FLICK":
            let maps = try circular(placement)
            guard !maps.isEmpty else { throw invalid("circularFlicks") }
            return RuntimeDefinition(gesture: .circular(maps), actions: [:], longPressActions: [:])
        case "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK":
            let map = try twoStep(placement)
            guard !map.isEmpty else { throw invalid("twoStepFlicks") }
            let alternate = type == "STICKY_TWO_STEP_FLICK" ? [:] : try twoStep(placement, longPress: true)
            return RuntimeDefinition(gesture: .twoStep(map, alternate: alternate,
                sticky: type == "STICKY_TWO_STEP_FLICK"), actions: [:], longPressActions: [:])
        case "FLICK_LONG_PRESS":
            var normal = sameDirectionOutputs(try twoStep(placement))
            let alternate = sameDirectionOutputs(try twoStep(placement, longPress: true))
            var actions = normal.mapValues(CustomKeyAction.text)
            if normal[.tap] == nil, let raw = key["action"]?.string {
                let decoded = CustomKeyAction.tap(raw, targets: targets)
                let fallbackText: String?
                switch decoded {
                case .text(let value), .inputText(let value): fallbackText = value
                default: fallbackText = nil
                }
                if let fallbackText, !fallbackText.isEmpty {
                    normal[.tap] = fallbackText
                    actions[.tap] = decoded
                }
            }
            guard !normal.isEmpty || !alternate.isEmpty else { throw invalid("twoStepFlicks") }
            return RuntimeDefinition(
                gesture: .single(.directionalLongPress, map: normal, alternate: alternate),
                actions: actions,
                longPressActions: alternate.mapValues(CustomKeyAction.text))
        case "STANDARD_FLICK", "PETAL_FLICK", "CENTER_GUIDE_FLICK", "CROSS_FLICK":
            let style: SingleStageFlickEvaluator.Style
            switch type {
            case "STANDARD_FLICK": style = .standard
            case "PETAL_FLICK": style = .petal
            case "CENTER_GUIDE_FLICK": style = .centerGuide
            default: style = .crossAction
            }
            var actions = try singleActions(placement, field: "flicks", targets: targets, stateful: true)
            let alternateActions = try longPressActions(placement)
            if actions[.tap] == nil, let raw = key["action"]?.string {
                actions[.tap] = CustomKeyAction.tap(raw, targets: targets)
            }
            guard !actions.isEmpty || !alternateActions.isEmpty else { throw invalid("flicks") }
            let map = actions.mapValues(label)
            let alternate = alternateActions.mapValues(label)
            return RuntimeDefinition(gesture: .single(style, map: map, alternate: alternate),
                                     actions: actions, longPressActions: alternateActions)
        case "HIERARCHICAL_FLICK":
            throw invalid("hierarchicalFlickMaps are not represented in custom layout schema v1-v4")
        default:
            throw invalid("key.keyType: \(type)")
        }
    }

    public static func twoStep(_ placement: ImportedCustomLayout.Placement, longPress: Bool = false) throws -> TwoStepFlickEvaluator.Map {
        let field = longPress ? "twoStepLongPressFlicks" : "twoStepFlicks"
        var result: TwoStepFlickEvaluator.Map = [:]
        for row in try rows(placement.source, field) {
            guard let first = row["firstDirection"]?.string.flatMap(MultiFlickDirection.init(rawValue:)),
                  let second = row["secondDirection"]?.string.flatMap(MultiFlickDirection.init(rawValue:)),
                  let output = row["output"]?.string else { throw invalid(field) }
            guard result[first]?[second] == nil else { throw invalid(field) }
            result[first, default: [:]][second] = output
        }
        return result
    }
    public static func circular(_ placement: ImportedCustomLayout.Placement) throws -> [CircularFlickEvaluator.Map] {
        let nativeRows = try rows(placement.source, "circularFlicks")
        let mappings = nativeRows.isEmpty ? try rows(placement.source, "flicks") : nativeRows
        let legacySlots: [String: CircularFlickSlot] = ["TAP": .tap, "UP": .slot0, "UP_RIGHT_FAR": .slot1,
            "DOWN": .slot2, "UP_LEFT_FAR": .slot3, "UP_RIGHT": .slot4, "UP_LEFT": .slot5]
        var states: [Int64: CircularFlickEvaluator.Map] = [:]
        for row in mappings {
            let slot: CircularFlickSlot?
            if nativeRows.isEmpty { slot = row["flickDirection"]?.string.flatMap { legacySlots[$0] } }
            else if let raw = row["circularDirection"]?.string {
                slot = raw == "TAP" ? .tap : (raw.hasPrefix("SLOT_") ? Int(raw.dropFirst(5)).flatMap(CircularFlickSlot.init(rawValue:)) : nil)
            } else { slot = nil }
            guard let slot else { throw invalid("circularDirection") }
            let state = row["stateIndex"]?.integer ?? 0
            guard (0...4095).contains(state), states[state]?[slot] == nil else { throw invalid("stateIndex") }
            let type = row["actionType"]?.string ?? "INPUT_TEXT", value = row["actionValue"]?.string
            let action: CircularFlickOutput
            if type == "INPUT_TEXT" { action = .text(value ?? "") }
            else if type == "MoveCustomKeyboardTab" && (value == nil || value == "⇄") { action = .mapSwitch }
            else { action = .action(type, value: value, label: value ?? type) }
            states[state, default: [:]][slot] = action
        }
        // The pinned Android importer groups stateIndex, sorts by the original
        // index, then exposes the values as a dense list. Preserve that
        // observable behavior for sparse exports instead of rejecting a layout
        // Android accepts (or treating stateIndex as a runtime array offset).
        return states.keys.sorted().compactMap { states[$0] }
    }

    private static func singleActions(_ placement: ImportedCustomLayout.Placement, field: String,
                                      targets: CustomLayoutTargets, stateful: Bool) throws -> [MultiFlickDirection: CustomKeyAction] {
        let nativeRows = try rows(placement.source, field)
        let indexed = try nativeRows.map { row -> (Int64, String, CustomKeyAction) in
            let state = row["stateIndex"]?.integer ?? 0
            guard (0...4095).contains(state), let raw = row["flickDirection"]?.string,
                  singleStageDirection(raw) != nil else {
                throw invalid(field)
            }
            let type = row["actionType"]?.string ?? "INPUT_TEXT"
            let value = row["actionValue"]?.string
            return (state, raw, CustomKeyAction.flick(type: type, value: value, targets: targets))
        }
        let selectedState = stateful ? indexed.map(\.0).min() : nil
        var selected: [MultiFlickDirection: (priority: Int, raw: String, action: CustomKeyAction)] = [:]
        for (state, raw, action) in indexed where selectedState == nil || state == selectedState {
            guard let direction = singleStageDirection(raw) else { throw invalid(field) }
            let priority = raw.hasSuffix("_FAR") ? 2 : 1
            if let existing = selected[direction] {
                guard existing.raw != raw, priority != existing.priority else { throw invalid(field) }
                if priority < existing.priority { continue }
            }
            selected[direction] = (priority, raw, action)
        }
        return selected.mapValues(\.action)
    }

    private static func longPressActions(_ placement: ImportedCustomLayout.Placement) throws -> [MultiFlickDirection: CustomKeyAction] {
        var result: [MultiFlickDirection: CustomKeyAction] = [:]
        for row in try rows(placement.source, "longPressFlicks") {
            guard let raw = row["flickDirection"]?.string,
                  let direction = singleStageDirection(raw),
                  let output = row["output"]?.string,
                  result[direction] == nil else { throw invalid("longPressFlicks") }
            result[direction] = .text(output)
        }
        return result
    }

    private static func sameDirectionOutputs(_ map: TwoStepFlickEvaluator.Map) -> [MultiFlickDirection: String] {
        var result: [MultiFlickDirection: String] = [:]
        for direction in MultiFlickDirection.allCases {
            if let output = map[direction]?[direction], !output.isEmpty { result[direction] = output }
        }
        return result
    }

    /// The pinned Android single-stage schema is FlickDirection, not the wider
    /// nine-way TfbiFlickDirection used by two-step gestures.
    private static func singleStageDirection(_ raw: String) -> MultiFlickDirection? {
        switch raw {
        case "TAP": return .tap
        case "UP": return .up
        case "DOWN": return .down
        case "UP_LEFT_FAR", "UP_LEFT": return .left
        case "UP_RIGHT_FAR", "UP_RIGHT": return .right
        default: return nil
        }
    }

    private static func label(for action: CustomKeyAction) -> String {
        switch action {
        case .text(let value), .inputText(let value): return value
        case .command(let command):
            switch command {
            case .doNothing: return ""
            case .delete, .backspace: return "⌫"
            case .space, .halfSpace, .fullSpace, .commitAndSpace: return "空白"
            case .enter, .newLine, .forceNewLine: return "改行"
            case .confirm: return "確定"
            case .convert: return "変換"
            case .paste: return "貼付"
            case .cursorLeft: return "←"
            case .cursorRight: return "→"
            case .deleteUntilBoundary: return "区切削除"
            case .openSymbols: return "記号"
            case .switchKana: return "かな"
            case .switchEnglish: return "ABC"
            case .switchNumber: return "123"
            case .switchDirect: return "直接入力"
            case .switchRomaji: return "ローマ字"
            case .shift: return "Shift"
            case .capsLock: return "Caps Lock"
            case .nextKeyboard: return "🌐"
            case .modifier: return "゛"
            case .toggleCase: return "a/A"
            case .changeMode: return "モード"
            case .moveCustomKeyboardTab: return "配列"
            }
        case .switchLayout: return "切替"
        case .unsupported(let raw, _): return raw
        }
    }

    private static func rows(_ source: LayoutJSON, _ field: String) throws -> [LayoutJSON] {
        guard let value = source[field], value != .null else { return [] }
        guard let rows = value.array, rows.count <= 4096 else { throw invalid(field) }
        return rows
    }
    private static func invalid(_ field: String) -> PersonalDataError {
        PersonalDataError("多段フリックの設定が不正または重複しています: \(field)")
    }
}
