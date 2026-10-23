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

    /// Number of iOS setting changes that will be applied, including an
    /// Android effective default synthesized for an omitted preference.
    public var importedSettingCount: Int { settings.values.count + removingKeys.count }

    /// Android's effective retention default applies when an enabled expiry
    /// preference is exported without its unchanged hour value.
    public var enabledClipboardExpiryRetentionHours: Int? {
        guard case .boolean(true)? = settings.values["clipboard.expirationEnabled"] else { return nil }
        guard case .number(let hours)? = settings.values["clipboard.retentionHours"] else { return 1 }
        return Int(hours)
    }

    /// Returns the post-import expiry threshold when this import newly enables
    /// expiry or shortens its active threshold. The caller can use this to warn
    /// about a later history reload deleting expired, unpinned clipboard entries.
    public func clipboardExpiryDeletionWarningHours(currentDefaults: UserDefaults) -> Int? {
        let expiryKey = "clipboard.expirationEnabled"
        let retentionKey = "clipboard.retentionHours"
        let updatesExpiry = settings.values[expiryKey] != nil || removingKeys.contains(expiryKey)
        let updatesRetention = settings.values[retentionKey] != nil || removingKeys.contains(retentionKey)
        guard updatesExpiry || updatesRetention else { return nil }

        let currentExpiryEnabled = currentDefaults.bool(forKey: expiryKey)
        let expiryEnabled: Bool
        if case .boolean(let value)? = settings.values[expiryKey] {
            expiryEnabled = value
        } else if removingKeys.contains(expiryKey) {
            expiryEnabled = false
        } else {
            expiryEnabled = currentDefaults.bool(forKey: expiryKey)
        }
        guard expiryEnabled else { return nil }

        let importedHours: Int
        if case .number(let value)? = settings.values[retentionKey] {
            importedHours = Int(value)
        } else if removingKeys.contains(retentionKey) {
            importedHours = 1
        } else if currentDefaults.object(forKey: retentionKey) == nil {
            importedHours = 1
        } else {
            importedHours = currentDefaults.integer(forKey: retentionKey)
        }
        let postImportHours = min(72, max(1, importedHours))
        let currentHours = min(72, max(1, currentDefaults.object(forKey: retentionKey) == nil
            ? 1
            : currentDefaults.integer(forKey: retentionKey)))
        guard !currentExpiryEnabled || postImportHours < currentHours else { return nil }
        return postImportHours
    }

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

        // Android exports only values present in SharedPreferences. If expiry
        // is explicitly enabled while its unchanged hours value is omitted,
        // carry Android's effective default (one hour) into the iOS snapshot.
        // An explicit null remains a removal and resolves to the same iOS default.
        if snapshot.values["clipboard.expirationEnabled"] == .boolean(true),
           snapshot.values["clipboard.retentionHours"] == nil,
           !removals.contains("clipboard.retentionHours") {
            snapshot.values["clipboard.retentionHours"] = .number(1)
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
