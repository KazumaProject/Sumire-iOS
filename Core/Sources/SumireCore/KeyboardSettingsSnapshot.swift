import Foundation
import CoreFoundation

/// Portable settings payload. Only named Sumire settings may cross this boundary.
/// Missing values preserve the distinction between defaults and explicit overrides.
public struct KeyboardSettingsSnapshot: Codable, Equatable {
    public enum Value: Codable, Equatable {
        case boolean(Bool), number(Double), text(String), textArray([String]), data(Data)
    }
    public var version = 1
    public var values: [String: Value] = [:]
    public init() {}
    public static let maximumBytes = 20 * 1024 * 1024

    private enum Rule {
        case boolean, number(ClosedRange<Double>, integer: Bool), text(Set<String>), boundedText(Int)
        case textArray(Set<String>, maximumCount: Int, maximumElementBytes: Int), data
    }
    private static var rules: [String: Rule] {
        var result: [String: Rule] = [:]
        for key in ["clipboardAutomaticPreview", "liveConversion", "omissionSearch", "bunsetsuSeparation", "englishReadingEnabled", "learningEnabled", "learnFirstCandidate"] {
            result[key] = .boolean
        }
        result[CustomInputModeStore.rememberKey] = .boolean
        result[CustomInputModeStore.replaceKey] = .boolean
        result[CustomInputModeStore.storageKey] = .data
        result[SymbolKeyboardMode.initialModeKey] = .text(Set(SymbolKeyboardMode.allCases.map(\.rawValue)))
        result[EmojiSkinTone.settingsKey] = .text(Set(EmojiSkinTone.allCases.map(\.rawValue)))
        result[ClipboardHistorySettings.enabledKey] = .boolean
        result["clipboard.expirationEnabled"] = .boolean
        result["clipboard.retentionHours"] = .number(1...72, integer: true)
        result["keyboard.lastUsed"] = .boundedText(256)
        result[KeyboardToolbarPreferences.storageKey] = .textArray(
            Set(KeyboardToolbarAction.allCases.map(\.rawValue) + ["symbols"]),
            maximumCount: KeyboardToolbarAction.allCases.count,
            maximumElementBytes: 64
        )
        result[DeletionBoundary.settingsKey] = .boundedText(4096)
        result["candidateRowCount"] = .number(1...3, integer: true)
        result[JapanesePredictionSettings.lookaheadStorageKey] = .number(1...6, integer: true)
        result[JapanesePredictionSettings.aggressivenessStorageKey] = .text(
            Set(JapanesePredictionAggressiveness.allCases.map(\.rawValue))
        )
        result["categoryMask"] = .number(0...Double(0x3fff_ffff), integer: true)
        result["theme.hue"] = .number(0...1, integer: false)
        result["theme.saturation"] = .number(0...1, integer: false)
        result["theme.brightness"] = .number(0...1, integer: false)
        result["theme.mode"] = .text(Set(KeyboardColorMode.allCases.map(\.rawValue)))
        result["sumire.keyArrangement"] = .text(Set(SumireKeyArrangement.allCases.map(\.rawValue)))
        for kind in KeyboardKind.allCases {
            for group in ["", "special."] {
                let prefix = "appearance.\(kind.rawValue).\(group)"
                result[prefix + "keyFontSize"] = .number(10...40, integer: false)
                result[prefix + "guideFontSize"] = .number(8...22, integer: false)
                result[prefix + "keyScale"] = .number(0.7...1, integer: false)
                result[prefix + "guidesVisible"] = .boolean
            }
        }
        for kind in ["english", "romaji"] {
            for suffix in ["flickUp", "flickDown"] { result["qwerty.\(kind).\(suffix)"] = .boolean }
        }
        for suffix in ["halfWidthNumbers", "halfWidthSymbols"] { result["qwerty.romaji.\(suffix)"] = .boolean }
        for key in [CircularSlotSetting.storageKey, FlickStyleSettings.storageKey, TouchFeedbackSettings.storageKey, SumireSpecialKeySettings.storageKey, KeyboardSelection.storageKey, RomajiLibrary.storageKey, CustomKeyboardLibrary.storageKey, KeyboardSizingStore.key(.portrait), KeyboardSizingStore.key(.landscape)] {
            result[key] = .data
        }
        return result
    }

    public static func capture(defaults: UserDefaults) throws -> Self {
        var snapshot = Self()
        for (key, rule) in rules {
            guard let raw = defaults.object(forKey: key) else { continue }
            switch rule {
            case .boolean:
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw invalid(key) }
                snapshot.values[key] = .boolean(value.boolValue)
            case .number:
                guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw invalid(key) }
                snapshot.values[key] = .number(value.doubleValue)
            case .text, .boundedText:
                guard let value = raw as? String else { throw invalid(key) }
                snapshot.values[key] = .text(value)
            case .textArray(let allowed, let maximumCount, let maximumElementBytes):
                guard let values = raw as? [String], values.count <= maximumCount,
                      values.allSatisfy({ allowed.contains($0) && $0.utf8.count <= maximumElementBytes }) else {
                    throw invalid(key)
                }
                if key == KeyboardToolbarPreferences.storageKey {
                    snapshot.values[key] = .textArray(KeyboardToolbarPreferences.normalize(values).map(\.rawValue))
                } else {
                    snapshot.values[key] = .textArray(values)
                }
            case .data:
                guard let value = raw as? Data else { throw invalid(key) }
                snapshot.values[key] = .data(value)
            }
        }
        try snapshot.validate()
        return snapshot
    }

    public func validate() throws {
        guard version == 1 else { throw PersonalDataError("未対応の設定バックアップ形式です") }
        let rules = Self.rules
        for (key, value) in values {
            guard let rule = rules[key] else { throw Self.invalid(key) }
            switch (rule, value) {
            case (.boolean, .boolean): break
            case (.number(let range, let integer), .number(let number)):
                guard number.isFinite, range.contains(number), !integer || number.rounded() == number else { throw Self.invalid(key) }
            case (.text(let allowed), .text(let text)):
                guard allowed.contains(text) else { throw Self.invalid(key) }
            case (.boundedText(let limit), .text(let text)):
                guard text.utf8.count <= limit else { throw Self.invalid(key) }
            case (.textArray(let allowed, let maximumCount, let maximumElementBytes), .textArray(let values)):
                guard values.count <= maximumCount,
                      values.allSatisfy({ allowed.contains($0) && $0.utf8.count <= maximumElementBytes }),
                      Set(values).count == values.count else { throw Self.invalid(key) }
                if key == KeyboardToolbarPreferences.storageKey,
                   KeyboardToolbarPreferences.normalize(values).map(\.rawValue) != values {
                    throw Self.invalid(key)
                }
            case (.data, .data(let data)):
                if key == CustomInputModeStore.storageKey {
                    _ = try CustomInputModeStore.decode(data)
                } else if key == CircularSlotSetting.storageKey {
                    guard data.count <= 1024 * 1024 else { throw Self.invalid(key) }
                    let slots = try JSONDecoder().decode([CircularSlotSetting].self, from: data)
                    guard slots.count <= 4096, slots.allSatisfy({
                        (0...2).contains($0.mode) && (4...6).contains($0.slot) && !$0.keyIdentifier.isEmpty &&
                        $0.keyIdentifier.utf8.count <= 4096 && $0.value.utf8.count <= 16384
                    }) else { throw Self.invalid(key) }
                } else if key == FlickStyleSettings.storageKey {
                    guard data.count <= 4096 else { throw Self.invalid(key) }
                    let style = try JSONDecoder().decode(FlickStyleSettings.self, from: data)
                    guard style == style.normalized else { throw Self.invalid(key) }
                } else if key == TouchFeedbackSettings.storageKey {
                    guard data.count <= 4096 else { throw Self.invalid(key) }
                    let feedback = try JSONDecoder().decode(TouchFeedbackSettings.self, from: data)
                    guard feedback == feedback.normalized() else { throw Self.invalid(key) }
                } else if key == SumireSpecialKeySettings.storageKey {
                    _ = try SumireSpecialKeySettings.decode(data)
                } else if key == KeyboardSelection.storageKey {
                    guard data.count <= 300_000 else { throw Self.invalid(key) }
                    try JSONDecoder().decode(KeyboardSelection.self, from: data).validate()
                } else if key == RomajiLibrary.storageKey {
                    guard data.count <= RomajiLibrary.maximumBytes else { throw Self.invalid(key) }
                    try JSONDecoder().decode(RomajiLibrary.self, from: data).validate()
                } else if key == CustomKeyboardLibrary.storageKey {
                    guard data.count <= CustomKeyboardLibrary.maximumBytes else { throw Self.invalid(key) }
                    _ = try JSONDecoder().decode(CustomKeyboardLibrary.self, from: data).layouts()
                } else {
                    guard data.count <= 4096 else { throw Self.invalid(key) }
                    let size = try JSONDecoder().decode(KeyboardSize.self, from: data)
                    guard size == size.normalized else { throw Self.invalid(key) }
                }
            default: throw Self.invalid(key)
            }
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw PersonalDataError("設定バックアップが大きすぎます") }
    }

    /// Validation is complete before any mutation. This does not claim a disk
    /// transaction across UserDefaults and the separate dictionary/learning stores.
    public func restore(defaults: UserDefaults) throws {
        try validate()
        for key in Self.rules.keys {
            guard let value = values[key] else { defaults.removeObject(forKey: key); continue }
            switch value {
            case .boolean(let value): defaults.set(value, forKey: key)
            case .number(let value): defaults.set(value, forKey: key)
            case .text(let value): defaults.set(value, forKey: key)
            case .textArray(let value): defaults.set(value, forKey: key)
            case .data(let value): defaults.set(value, forKey: key)
            }
        }
    }

    /// Applies only the values present in this snapshot. This is for importing
    /// another product's partial settings format; absent iOS-only preferences
    /// remain unchanged. `removingKeys` represents explicit null entries from
    /// that source format.
    public func applyImportedValues(to defaults: UserDefaults, removingKeys: Set<String> = []) throws {
        try validate()
        let rules = Self.rules
        guard removingKeys.allSatisfy({ rules[$0] != nil }),
              removingKeys.isDisjoint(with: values.keys) else {
            throw PersonalDataError("設定バックアップの削除対象が不正です")
        }
        for (key, value) in values {
            switch value {
            case .boolean(let value): defaults.set(value, forKey: key)
            case .number(let value): defaults.set(value, forKey: key)
            case .text(let value): defaults.set(value, forKey: key)
            case .textArray(let value): defaults.set(value, forKey: key)
            case .data(let value): defaults.set(value, forKey: key)
            }
        }
        for key in removingKeys { defaults.removeObject(forKey: key) }
    }
    private static func invalid(_ key: String) -> PersonalDataError {
        PersonalDataError("設定バックアップの値またはキーが不正です: \(key.prefix(128))")
    }
}
