import Foundation

/// App-level post-processing from CircularSlotActionApplier (9506a0b).
/// Slots 4...6 are independently configured for each mode and normal key.
public struct CircularSlotSetting: Codable, Equatable {
    public enum Action: String, Codable, CaseIterable {
        case none, inputText, showEmoji, nextIME, kana, english, number, switchMap
    }
    public var mode: Int
    public var keyIdentifier: String
    public var slot: Int
    public var action: Action
    public var value: String
    public init(mode: Int, keyIdentifier: String, slot: Int, action: Action = .none, value: String = "") {
        self.mode = mode; self.keyIdentifier = keyIdentifier; self.slot = slot; self.action = action; self.value = value
    }
    public var output: CircularFlickOutput? {
        switch action {
        case .none: return nil
        case .inputText: return value.isEmpty ? nil : .text(value, label: value)
        case .switchMap: return .mapSwitch
        case .showEmoji: return .action("ShowEmojiKeyboard", label: "絵")
        case .nextIME: return .action("SwitchToNextIme", label: "IME")
        case .kana: return .action("SwitchToKanaLayout", label: "かな")
        case .english: return .action("SwitchToEnglishLayout", label: "英")
        case .number: return .action("SwitchToNumberLayout", label: "数")
        }
    }
    public static let storageKey = "sumire.circularSlotActions"
    public static func load(defaults: UserDefaults) -> [Self] {
        guard let data = defaults.data(forKey: storageKey), data.count <= 1024 * 1024,
              let values = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return validated(values)
    }
    @discardableResult public static func save(_ values: [Self], defaults: UserDefaults) -> Bool {
        guard values.count <= 4096, validated(values).count == values.count,
              let data = try? JSONEncoder().encode(values), data.count <= 1024 * 1024 else { return false }
        defaults.set(data, forKey: storageKey); return true
    }
    private static func validated(_ values: [Self]) -> [Self] {
        values.prefix(4096).filter { (0...2).contains($0.mode) && (4...6).contains($0.slot) && !$0.keyIdentifier.isEmpty && $0.keyIdentifier.utf8.count <= 4096 && $0.value.utf8.count <= 16384 }
    }
    public static func apply(_ maps: [CircularFlickEvaluator.Map], settings: [Self], mode: Int,
                             keyIdentifier: String, isSpecialKey: Bool) -> [CircularFlickEvaluator.Map] {
        guard !isSpecialKey, !keyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return maps }
        let applicable = validated(settings).filter { $0.mode == mode && $0.keyIdentifier == keyIdentifier }
        return maps.map { original in
            var map = original
            for slot in [CircularFlickSlot.slot4, .slot5, .slot6] { map.removeValue(forKey: slot) }
            for setting in applicable { if let slot = CircularFlickSlot(rawValue: setting.slot) { map[slot] = setting.output } }
            return map
        }
    }
}
