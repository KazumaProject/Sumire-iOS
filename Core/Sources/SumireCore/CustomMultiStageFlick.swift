import Foundation

/// Decodes the exported v1-v4 fields preserved by CustomLayoutImport. The
/// source remains intact; unsupported actions retain their type and payload.
public enum CustomMultiStageFlick {
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
        return states.keys.sorted().compactMap { states[$0] }
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
