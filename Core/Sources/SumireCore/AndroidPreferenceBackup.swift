import Foundation
import CoreFoundation

/// Reader for Android Sumire's `PrefBackup` JSON. Only settings with a
/// confirmed iOS equivalent are imported; Android-only values and toolbar IDs
/// are reported but never written into unrelated iOS preferences.
public struct AndroidPreferenceBackup: Equatable {
    public let version: Int
    public let settings: KeyboardSettingsSnapshot
    public let removingKeys: Set<String>
    public let importedKeys: [String]
    public let unsupportedEntryCount: Int
    public let shortcutIDs: [String]

    public var importedSettingCount: Int { importedKeys.count }

    private static let maximumBytes = 128 * 1024 * 1024
    private static let maximumEntries = 100_000
    private static let maximumKeyBytes = 512
    private static let maximumShortcutIDBytes = 512
    private enum Mapping {
        case boolean(String)
        case integer(String, range: ClosedRange<Int>)
        case text(String, values: [String: String])

        var targetKey: String {
            switch self {
            case .boolean(let key), .integer(let key, _), .text(let key, _): return key
            }
        }
    }
    private static let mappings: [String: Mapping] = [
        "live_conversion_preference": .boolean("liveConversion"),
        "omission_search_preference": .boolean("omissionSearch"),
        "conversion_bunsetsu_separation_preference": .boolean("bunsetsuSeparation"),
        "learn_dictionary_preference": .boolean("learningEnabled"),
        "learn_first_candidate_dictionary_preference": .boolean("learnFirstCandidate"),
        "clipboard_history_preference": .boolean(ClipboardHistorySettings.enabledKey),
        "clipboard_delete_unpinned_after_hours_preference": .boolean("clipboard.expirationEnabled"),
        "clipboard_unpinned_retention_hours_preference": .integer("clipboard.retentionHours", range: 1...72),
        "custom_direct_input_replace_composing_preference": .boolean(CustomInputModeStore.replaceKey),
        "symbol_mode_preference": .text(SymbolKeyboardMode.initialModeKey, values: [
            "EMOJI": SymbolKeyboardMode.emoji.rawValue,
            "EMOTICON": SymbolKeyboardMode.emoticon.rawValue,
            "SYMBOL": SymbolKeyboardMode.symbol.rawValue,
            "CLIPBOARD": SymbolKeyboardMode.clipboard.rawValue
        ]),
        "default_emoji_skin_tone_preference": .text(EmojiSkinTone.settingsKey, values:
            Dictionary(uniqueKeysWithValues: EmojiSkinTone.allCases.map { ($0.rawValue, $0.rawValue) })
        )
    ]

    /// Returns nil for a JSON document that is not shaped like Android
    /// `PrefBackup`; malformed documents that claim that shape throw.
    public static func decodeIfMatching(_ data: Data) throws -> Self? {
        guard data.count <= maximumBytes else { throw PersonalDataError("バックアップが大きすぎます") }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              root["format"] == nil,
              root.keys.contains("entries") else { return nil }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersion = root["version"] as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
              rawVersion.doubleValue.rounded() == rawVersion.doubleValue,
              let entries = root["entries"] as? [Any],
              entries.count <= maximumEntries else {
            throw PersonalDataError("Android設定バックアップの形式が不正です")
        }
        let version = rawVersion.intValue
        guard version == 1 || version == 2 else {
            throw PersonalDataError("未対応のAndroid設定バックアップ形式です")
        }

        let shortcutIDs: [String]
        if let rawShortcuts = root["shortcutIds"], !(rawShortcuts is NSNull) {
            guard version >= 2,
                  let values = rawShortcuts as? [String],
                  values.count <= maximumEntries,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumShortcutIDBytes }) else {
                throw PersonalDataError("Android設定バックアップのツールバー項目が不正です")
            }
            shortcutIDs = values
        } else {
            shortcutIDs = []
        }

        var snapshot = KeyboardSettingsSnapshot()
        var removals = Set<String>()
        var imported = [String]()
        var unsupported = 0
        var seenKeys = Set<String>()

        for rawEntry in entries {
            guard let entry = rawEntry as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty, key.utf8.count <= maximumKeyBytes,
                  let type = entry["type"] as? String,
                  seenKeys.insert(key).inserted else {
                throw PersonalDataError("Android設定バックアップの項目が不正です")
            }

            guard let mapping = mappings[key] else {
                unsupported += 1
                continue
            }
            switch type {
            case "null":
                // Default Gson omits null-valued object members, so Android's
                // PrefEntry(key, "null", null) may have no value field.
                guard entry["value"] == nil || entry["value"] is NSNull else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                removals.insert(mapping.targetKey)
            case "boolean":
                guard case .boolean(let targetKey) = mapping else {
                    throw PersonalDataError("Android設定バックアップの対応項目の型が一致しません")
                }
                guard let value = entry["value"] else {
                    throw PersonalDataError("Android設定バックアップの対応項目に値がありません")
                }
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                snapshot.values[targetKey] = .boolean(number.boolValue)
            case "int":
                guard case .integer(let targetKey, let range) = mapping,
                      let number = entry["value"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(range.lowerBound),
                      number.doubleValue <= Double(range.upperBound) else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                snapshot.values[targetKey] = .number(number.doubleValue)
            case "string":
                guard case .text(let targetKey, let values) = mapping,
                      let value = entry["value"] as? String,
                      let translatedValue = values[value] else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                snapshot.values[targetKey] = .text(translatedValue)
            default:
                throw PersonalDataError("Android設定バックアップの対応項目の型が一致しません")
            }
            imported.append(key)
        }

        try snapshot.validate()
        return Self(version: version, settings: snapshot, removingKeys: removals,
                    importedKeys: imported.sorted(), unsupportedEntryCount: unsupported,
                    shortcutIDs: shortcutIDs)
    }

    /// Merges the compatible Android settings into the app's current settings.
    /// Unrepresented iOS settings are deliberately preserved.
    public func apply(to defaults: UserDefaults) throws {
        try settings.applyImportedValues(to: defaults, removingKeys: removingKeys)
    }
}
