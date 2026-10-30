import Foundation
import CoreFoundation

/// Reader for Android Sumire's `PrefBackup` JSON. Only settings and toolbar
/// actions with a confirmed iOS equivalent are imported; Android-only values
/// are reported but never written into unrelated iOS preferences.
public struct AndroidPreferenceBackup: Equatable {
    public let version: Int
    public let settings: KeyboardSettingsSnapshot
    /// Android's three-step flick input mode, stored inside the iOS flick-style blob.
    public let threeStepInputMode: FlickStyleSettings.ThreeStepInput
    public let removingKeys: Set<String>
    public let importedKeys: [String]
    public let unsupportedEntryCount: Int
    /// `nil` means Android omitted the field or wrote null; an explicit empty
    /// list remains distinguishable because Android treats it as a request to
    /// replace its own toolbar with its settings fallback.
    public let shortcutIDs: [String]?
    public var toolbarShortcutImport: AndroidToolbarShortcutImport? {
        shortcutIDs.map(AndroidToolbarShortcutImport.init(shortcutIDs:))
    }

    /// Number of iOS setting changes that will be applied, including an
    /// Android effective default synthesized for an omitted preference.
    public var importedSettingCount: Int {
        settings.values.count + removingKeys.count + 1 + (toolbarShortcutImport?.actions.isEmpty == false ? 1 : 0)
    }

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
        case predictionLookahead
        case predictionAggressiveness
        case threeStepInputMode

        var targetKey: String {
            switch self {
            case .boolean(let key), .integer(let key, _), .text(let key, _): return key
            case .predictionLookahead: return JapanesePredictionSettings.lookaheadStorageKey
            case .predictionAggressiveness: return JapanesePredictionSettings.aggressivenessStorageKey
            case .threeStepInputMode: return FlickStyleSettings.storageKey
            }
        }
    }
    private static let mappings: [String: Mapping] = [
        "live_conversion_preference": .boolean("liveConversion"),
        "omission_search_preference": .boolean("omissionSearch"),
        "conversion_bunsetsu_separation_preference": .boolean("bunsetsuSeparation"),
        "learn_dictionary_preference": .boolean("learningEnabled"),
        "learn_first_candidate_dictionary_preference": .boolean("learnFirstCandidate"),
        "proverb_prediction_enable_preference": .boolean(KotowazaSettings.enabledKey),
        "prediction_lookahead_preference": .predictionLookahead,
        "prediction_aggressiveness_preference": .predictionAggressiveness,
        "learn_dictionary_allow_mixed_symbols_numbers_preference": .boolean("learnMixedSymbolsAndNumbers"),
        "user_dictionary_preference": .boolean(UserDictionaryPredictionSettings.enabledKey),
        "user_dictionary_prefix_match_number": .integer(UserDictionaryPredictionSettings.minimumInputLengthKey, range: 2...8),
        "user_dictionary_prediction_candidate_limit_preference": .integer(UserDictionaryPredictionSettings.candidateLimitKey, range: 1...8),
        "enable_prediction_search_learn_dictionary_preference": .boolean(LearnedPredictionSettings.enabledKey),
        "learn_prediction_preference": .integer(LearnedPredictionSettings.minimumInputLengthKey, range: 1...8),
        "learn_dictionary_prediction_candidate_limit_preference": .integer(LearnedPredictionSettings.candidateLimitKey, range: 1...8),
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
        ),
        "sumire_flick_input_mode_preference": .threeStepInputMode,
        "sumire_english_qwerty_preference": .boolean(SumireModePreferences.englishQWERTYKey)
    ]
    /// Defaults returned by Android Sumire when a preference is absent from
    /// SharedPreferences. Android restore replaces the preference store, so an
    /// omitted compatible entry must not leave a stale iOS value behind.
    private static let defaultValues: [String: KeyboardSettingsSnapshot.Value] = [
        "live_conversion_preference": .boolean(false),
        "omission_search_preference": .boolean(false),
        "conversion_bunsetsu_separation_preference": .boolean(false),
        "learn_dictionary_preference": .boolean(true),
        "learn_first_candidate_dictionary_preference": .boolean(false),
        "proverb_prediction_enable_preference": .boolean(true),
        "prediction_lookahead_preference": .number(Double(JapanesePredictionSettings.defaultLookaheadCharacterCount)),
        "prediction_aggressiveness_preference": .text(JapanesePredictionAggressiveness.standard.rawValue),
        "learn_dictionary_allow_mixed_symbols_numbers_preference": .boolean(true),
        "user_dictionary_preference": .boolean(true),
        "user_dictionary_prefix_match_number": .number(2),
        "user_dictionary_prediction_candidate_limit_preference": .number(4),
        "enable_prediction_search_learn_dictionary_preference": .boolean(false),
        "learn_prediction_preference": .number(4),
        "learn_dictionary_prediction_candidate_limit_preference": .number(4),
        "clipboard_history_preference": .boolean(false),
        "clipboard_delete_unpinned_after_hours_preference": .boolean(false),
        "clipboard_unpinned_retention_hours_preference": .number(1),
        "custom_direct_input_replace_composing_preference": .boolean(false),
        "symbol_mode_preference": .text(SymbolKeyboardMode.emoji.rawValue),
        "default_emoji_skin_tone_preference": .text(EmojiSkinTone.standard.rawValue),
        "sumire_english_qwerty_preference": .boolean(false)
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

        let shortcutIDs: [String]?
        if let rawShortcuts = root["shortcutIds"], !(rawShortcuts is NSNull) {
            guard version >= 2,
                  let values = rawShortcuts as? [String],
                  values.count <= maximumEntries,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumShortcutIDBytes }) else {
                throw PersonalDataError("Android設定バックアップのツールバー項目が不正です")
            }
            shortcutIDs = values
        } else {
            shortcutIDs = nil
        }

        var snapshot = KeyboardSettingsSnapshot()
        var removals = Set<String>()
        var imported = [String]()
        var unsupported = 0
        var seenKeys = Set<String>()
        var threeStepInputMode = FlickStyleSettings.ThreeStepInput.all

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
                if case .threeStepInputMode = mapping {
                    // Android's null/removal reads as its default (`all`). Do
                    // not remove the entire iOS blob, which also stores iOS-only settings.
                    threeStepInputMode = .all
                } else {
                    removals.insert(mapping.targetKey)
                }
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
                guard let number = entry["value"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                switch mapping {
                case .integer(let targetKey, let range):
                    guard number.doubleValue >= Double(range.lowerBound),
                          number.doubleValue <= Double(range.upperBound) else {
                        throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                    }
                    snapshot.values[targetKey] = .number(number.doubleValue)
                case .predictionLookahead:
                    snapshot.values[JapanesePredictionSettings.lookaheadStorageKey] = .number(
                        Double(JapanesePredictionSettings.androidLookahead(number.intValue))
                    )
                default:
                    throw PersonalDataError("Android設定バックアップの対応項目の型が一致しません")
                }
            case "string":
                guard let value = entry["value"] as? String else {
                    throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                }
                switch mapping {
                case .text(let targetKey, let values):
                    guard let translatedValue = values[value] else {
                        throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                    }
                    snapshot.values[targetKey] = .text(translatedValue)
                case .predictionLookahead:
                    snapshot.values[JapanesePredictionSettings.lookaheadStorageKey] = .number(
                        Double(JapanesePredictionSettings.androidLookahead(value))
                    )
                case .predictionAggressiveness:
                    let value = JapanesePredictionAggressiveness(rawValue: value)?.rawValue
                        ?? JapanesePredictionAggressiveness.standard.rawValue
                    snapshot.values[JapanesePredictionSettings.aggressivenessStorageKey] = .text(value)
                case .threeStepInputMode:
                    guard let mode = FlickStyleSettings.ThreeStepInput(rawValue: value) else {
                        throw PersonalDataError("Android設定バックアップの対応項目が不正です")
                    }
                    threeStepInputMode = mode
                case .boolean, .integer:
                    throw PersonalDataError("Android設定バックアップの対応項目の型が一致しません")
                }
            default:
                throw PersonalDataError("Android設定バックアップの対応項目の型が一致しません")
            }
            imported.append(key)
        }

        // Android exports only values present in SharedPreferences, then
        // restores with replaceAll=true. Restore omitted compatible settings
        // to Android's effective defaults; explicit nulls still remove keys.
        for (androidKey, mapping) in mappings where !seenKeys.contains(androidKey) {
            if case .threeStepInputMode = mapping {
                // Android restores omitted SharedPreferences to its effective default.
                threeStepInputMode = .all
                continue
            }
            guard let value = defaultValues[androidKey] else {
                throw PersonalDataError("Android設定の既定値がありません: \(androidKey)")
            }
            snapshot.values[mapping.targetKey] = value
        }

        try snapshot.validate()
        return Self(version: version, settings: snapshot, threeStepInputMode: threeStepInputMode,
                    removingKeys: removals,
                    importedKeys: imported.sorted(), unsupportedEntryCount: unsupported,
                    shortcutIDs: shortcutIDs)
    }

    /// Restores compatible Android settings, including Android defaults for
    /// omitted entries. Unrepresented iOS settings are deliberately preserved.
    public func apply(to defaults: UserDefaults) throws {
        var importedSettings = settings
        var flickStyle = try Self.currentFlickStyle(from: defaults)
        flickStyle.threeStepInput = threeStepInputMode
        importedSettings.values[FlickStyleSettings.storageKey] = .data(
            try JSONEncoder().encode(flickStyle.normalized)
        )
        try importedSettings.applyImportedValues(to: defaults, removingKeys: removingKeys)
        if let toolbarShortcutImport, !toolbarShortcutImport.actions.isEmpty {
            KeyboardToolbarPreferences.save(toolbarShortcutImport.actions, defaults: defaults)
        }
    }

    private static func currentFlickStyle(from defaults: UserDefaults) throws -> FlickStyleSettings {
        guard let raw = defaults.object(forKey: FlickStyleSettings.storageKey) else {
            return FlickStyleSettings()
        }
        guard let data = raw as? Data, data.count <= 4096,
              let style = try? JSONDecoder().decode(FlickStyleSettings.self, from: data) else {
            throw PersonalDataError("保存済みのフリック設定が不正です")
        }
        return style.normalized
    }
}
