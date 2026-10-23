import XCTest
@testable import SumireCore

final class AndroidPreferenceBackupTests: XCTestCase {
    func testMapsSupportedAndroidSettingsAndPreservesUnrepresentedIOSSettings() throws {
        let backup = try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "boolean", true),
            entry("omission_search_preference", "boolean", false),
            entry("conversion_bunsetsu_separation_preference", "boolean", true),
            entry("learn_dictionary_preference", "boolean", false),
            entry("learn_first_candidate_dictionary_preference", "boolean", true),
            entry("clipboard_history_preference", "boolean", true),
            entry("clipboard_delete_unpinned_after_hours_preference", "boolean", true),
            entry("clipboard_unpinned_retention_hours_preference", "int", 24),
            entry("custom_direct_input_replace_composing_preference", "boolean", true),
            entry("symbol_mode_preference", "string", "CLIPBOARD"),
            entry("default_emoji_skin_tone_preference", "string", "1F3FD"),
            entry("clipboard_preview_enable_preference", "boolean", false),
            entry("android.only.setting", "string", "kept out of iOS settings")
        ]))

        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.importedSettingCount, 11)
        XCTAssertEqual(backup.unsupportedEntryCount, 2)
        XCTAssertEqual(backup.settings.values["liveConversion"], .boolean(true))
        XCTAssertEqual(backup.settings.values["omissionSearch"], .boolean(false))
        XCTAssertEqual(backup.settings.values["bunsetsuSeparation"], .boolean(true))
        XCTAssertEqual(backup.settings.values["learningEnabled"], .boolean(false))
        XCTAssertEqual(backup.settings.values["learnFirstCandidate"], .boolean(true))
        XCTAssertEqual(backup.settings.values[ClipboardHistorySettings.enabledKey], .boolean(true))
        XCTAssertEqual(backup.settings.values["clipboard.expirationEnabled"], .boolean(true))
        XCTAssertEqual(backup.settings.values["clipboard.retentionHours"], .number(24))
        XCTAssertEqual(backup.settings.values[CustomInputModeStore.replaceKey], .boolean(true))
        XCTAssertEqual(backup.settings.values[SymbolKeyboardMode.initialModeKey], .text("clipboard"))
        XCTAssertEqual(backup.settings.values[EmojiSkinTone.settingsKey], .text("1F3FD"))

        let suite = "AndroidPreferenceBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "englishReadingEnabled")
        defaults.set(true, forKey: "omissionSearch")
        defaults.set(false, forKey: "clipboard.expirationEnabled")
        defaults.set(1, forKey: "clipboard.retentionHours")
        defaults.set(3, forKey: "candidateRowCount")
        try backup.apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: "liveConversion"))
        XCTAssertFalse(defaults.bool(forKey: "omissionSearch"))
        XCTAssertTrue(defaults.bool(forKey: "bunsetsuSeparation"))
        XCTAssertFalse(defaults.bool(forKey: "learningEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "learnFirstCandidate"))
        XCTAssertTrue(defaults.bool(forKey: ClipboardHistorySettings.enabledKey))
        XCTAssertTrue(defaults.bool(forKey: "clipboard.expirationEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "clipboard.retentionHours"), 24)
        XCTAssertTrue(defaults.bool(forKey: CustomInputModeStore.replaceKey))
        XCTAssertEqual(SymbolKeyboardMode.initialMode(defaults: defaults), .clipboard)
        XCTAssertEqual(EmojiSkinTone.load(defaults: defaults), .medium)
        XCTAssertTrue(defaults.bool(forKey: "englishReadingEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 3)
        XCTAssertNil(defaults.object(forKey: "clipboardAutomaticPreview"))
    }

    func testMapsEveryAndroidSymbolModeAndEmojiSkinTone() throws {
        let symbolModes = [
            ("EMOJI", SymbolKeyboardMode.emoji.rawValue),
            ("EMOTICON", SymbolKeyboardMode.emoticon.rawValue),
            ("SYMBOL", SymbolKeyboardMode.symbol.rawValue),
            ("CLIPBOARD", SymbolKeyboardMode.clipboard.rawValue)
        ]
        for (androidValue, iosValue) in symbolModes {
            let backup = try AndroidPreferenceBackup.decode(json([
                entry("symbol_mode_preference", "string", androidValue)
            ]))
            XCTAssertEqual(backup.settings.values[SymbolKeyboardMode.initialModeKey], .text(iosValue))
        }

        for skinTone in ["default", "1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"] {
            let backup = try AndroidPreferenceBackup.decode(json([
                entry("default_emoji_skin_tone_preference", "string", skinTone)
            ]))
            XCTAssertEqual(backup.settings.values[EmojiSkinTone.settingsKey], .text(skinTone))
        }
    }

    func testEnabledClipboardExpiryUsesAndroidDefaultWhenRetentionIsOmitted() throws {
        let backup = try AndroidPreferenceBackup.decode(json([
            entry("clipboard_delete_unpinned_after_hours_preference", "boolean", true)
        ]))

        XCTAssertEqual(backup.enabledClipboardExpiryRetentionHours, 1)
        XCTAssertEqual(backup.settings.values["clipboard.retentionHours"], .number(1))
        XCTAssertEqual(backup.importedSettingCount, 2)
        XCTAssertEqual(backup.importedKeys, ["clipboard_delete_unpinned_after_hours_preference"])

        let suite = "AndroidPreferenceBackupDefaultRetention." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(48, forKey: "clipboard.retentionHours")
        try backup.apply(to: defaults)
        XCTAssertTrue(defaults.bool(forKey: "clipboard.expirationEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "clipboard.retentionHours"), 1)
    }

    func testDisabledClipboardExpiryDoesNotImportAnOmittedRetentionDefault() throws {
        let backup = try AndroidPreferenceBackup.decode(json([
            entry("clipboard_delete_unpinned_after_hours_preference", "boolean", false)
        ]))

        XCTAssertNil(backup.enabledClipboardExpiryRetentionHours)
        XCTAssertNil(backup.settings.values["clipboard.retentionHours"])
        XCTAssertEqual(backup.importedSettingCount, 1)
    }

    func testClipboardExpiryWarningCoversNewDeletionRiskWithoutOverwarning() throws {
        func warning(
            _ entries: [[String: Any]],
            currentExpiryEnabled: Bool,
            currentRetentionHours: Int?
        ) throws -> Int? {
            let suite = "AndroidPreferenceBackupWarning." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(currentExpiryEnabled, forKey: "clipboard.expirationEnabled")
            if let currentRetentionHours {
                defaults.set(currentRetentionHours, forKey: "clipboard.retentionHours")
            }
            let backup = try AndroidPreferenceBackup.decode(json(entries))
            return backup.clipboardExpiryDeletionWarningHours(currentDefaults: defaults)
        }

        XCTAssertEqual(try warning([
            entry("clipboard_unpinned_retention_hours_preference", "int", 1)
        ], currentExpiryEnabled: true, currentRetentionHours: 24), 1)
        XCTAssertNil(try warning([
            entry("clipboard_unpinned_retention_hours_preference", "int", 24)
        ], currentExpiryEnabled: true, currentRetentionHours: 24))
        XCTAssertNil(try warning([
            entry("clipboard_unpinned_retention_hours_preference", "int", 24)
        ], currentExpiryEnabled: true, currentRetentionHours: 1))
        XCTAssertEqual(try warning([
            entry("clipboard_delete_unpinned_after_hours_preference", "boolean", true)
        ], currentExpiryEnabled: false, currentRetentionHours: 48), 1)
        XCTAssertNil(try warning([
            entry("clipboard_unpinned_retention_hours_preference", "int", 1)
        ], currentExpiryEnabled: false, currentRetentionHours: 24))
        XCTAssertNil(try warning([
            entry("live_conversion_preference", "boolean", true)
        ], currentExpiryEnabled: true, currentRetentionHours: 24))
        XCTAssertEqual(try warning([
            ["key": "clipboard_unpinned_retention_hours_preference", "type": "null"]
        ], currentExpiryEnabled: true, currentRetentionHours: 24), 1)
        XCTAssertNil(try warning([
            ["key": "clipboard_delete_unpinned_after_hours_preference", "type": "null"]
        ], currentExpiryEnabled: true, currentRetentionHours: 24))
    }

    func testClipboardRetentionAcceptsBothAndroidRangeBoundaries() throws {
        for hours in [1, 72] {
            let backup = try AndroidPreferenceBackup.decode(json([
                entry("clipboard_unpinned_retention_hours_preference", "int", hours)
            ]))
            XCTAssertEqual(backup.settings.values["clipboard.retentionHours"], .number(Double(hours)))
        }
    }

    func testNullRemovesOnlyMappedPreferenceAndVersionTwoRetainsNoToolbarMutation() throws {
        let data = json([
            ["key": "live_conversion_preference", "type": "null"],
            ["key": "clipboard_history_preference", "type": "null"],
            ["key": "clipboard_delete_unpinned_after_hours_preference", "type": "null"],
            ["key": "clipboard_unpinned_retention_hours_preference", "type": "null"],
            ["key": "symbol_mode_preference", "type": "null"],
            entry("learn_dictionary_preference", "boolean", true)
        ], version: 2, shortcutIDs: ["symbols", "emoji"])
        let backup = try AndroidPreferenceBackup.decode(data)
        XCTAssertEqual(backup.shortcutIDs, ["symbols", "emoji"])
        XCTAssertEqual(backup.removingKeys, [
            "liveConversion", ClipboardHistorySettings.enabledKey, "clipboard.expirationEnabled",
            "clipboard.retentionHours", SymbolKeyboardMode.initialModeKey
        ])

        let suite = "AndroidPreferenceBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "liveConversion")
        defaults.set(true, forKey: ClipboardHistorySettings.enabledKey)
        defaults.set(true, forKey: "clipboard.expirationEnabled")
        defaults.set(24, forKey: "clipboard.retentionHours")
        defaults.set("symbol", forKey: SymbolKeyboardMode.initialModeKey)
        defaults.set(2, forKey: "candidateRowCount")
        try backup.apply(to: defaults)
        XCTAssertNil(defaults.object(forKey: "liveConversion"))
        XCTAssertNil(defaults.object(forKey: ClipboardHistorySettings.enabledKey))
        XCTAssertNil(defaults.object(forKey: "clipboard.expirationEnabled"))
        XCTAssertNil(defaults.object(forKey: "clipboard.retentionHours"))
        XCTAssertNil(defaults.object(forKey: SymbolKeyboardMode.initialModeKey))
        XCTAssertTrue(defaults.bool(forKey: "learningEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 2)
    }

    func testImportedSharedSettingsRemainVisibleWithSharedWritesDisabled() throws {
        let sharedName = "AndroidPreferenceBackupShared." + UUID().uuidString
        let localName = "AndroidPreferenceBackupLocal." + UUID().uuidString
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        let local = try XCTUnwrap(UserDefaults(suiteName: localName))
        defer {
            shared.removePersistentDomain(forName: sharedName)
            local.removePersistentDomain(forName: localName)
        }

        shared.set(false, forKey: ClipboardHistorySettings.enabledKey)
        shared.set(false, forKey: "clipboard.expirationEnabled")
        shared.set(1, forKey: "clipboard.retentionHours")
        shared.set(EmojiSkinTone.standard.rawValue, forKey: EmojiSkinTone.settingsKey)
        let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
        local.set(false, forKey: ClipboardHistorySettings.enabledKey)
        local.set(false, forKey: "clipboard.expirationEnabled")
        local.set(1, forKey: "clipboard.retentionHours")
        local.set(EmojiSkinTone.standard.rawValue, forKey: EmojiSkinTone.settingsKey)
        access.didWrite([ClipboardHistorySettings.enabledKey, EmojiSkinTone.settingsKey])

        let backup = try AndroidPreferenceBackup.decode(json([
            entry("clipboard_history_preference", "boolean", true),
            entry("clipboard_delete_unpinned_after_hours_preference", "boolean", true),
            entry("clipboard_unpinned_retention_hours_preference", "int", 24),
            entry("custom_direct_input_replace_composing_preference", "boolean", true),
            entry("symbol_mode_preference", "string", "EMOTICON"),
            entry("default_emoji_skin_tone_preference", "string", EmojiSkinTone.medium.rawValue)
        ]))
        try backup.apply(to: shared)
        let sharedAfterImport = shared.dictionaryRepresentation() as NSDictionary

        access.reload()

        XCTAssertFalse(access.writesSharedSettings)
        XCTAssertTrue(access.readDefaults.bool(forKey: ClipboardHistorySettings.enabledKey))
        XCTAssertTrue(access.readDefaults.bool(forKey: "clipboard.expirationEnabled"))
        XCTAssertEqual(access.readDefaults.integer(forKey: "clipboard.retentionHours"), 24)
        XCTAssertEqual(access.readDefaults.string(forKey: EmojiSkinTone.settingsKey), EmojiSkinTone.medium.rawValue)
        XCTAssertEqual(access.readDefaults.string(forKey: SymbolKeyboardMode.initialModeKey), SymbolKeyboardMode.emoticon.rawValue)
        XCTAssertTrue(access.readDefaults.bool(forKey: CustomInputModeStore.replaceKey))
        XCTAssertNil(local.object(forKey: ClipboardHistorySettings.enabledKey))
        XCTAssertNil(local.object(forKey: EmojiSkinTone.settingsKey))
        XCTAssertEqual(shared.dictionaryRepresentation() as NSDictionary, sharedAfterImport)
    }

    func testMalformedAndAmbiguousMappedEntriesAreRejected() throws {
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "string", "true")
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_history_preference", "string", "true")
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_delete_unpinned_after_hours_preference", "int", 1)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("custom_direct_input_replace_composing_preference", "integer", 1)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_unpinned_retention_hours_preference", "boolean", true)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_unpinned_retention_hours_preference", "int", 0)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_unpinned_retention_hours_preference", "int", 73)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("clipboard_unpinned_retention_hours_preference", "int", 1.5)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("symbol_mode_preference", "boolean", true)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("symbol_mode_preference", "string", "UNKNOWN")
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("default_emoji_skin_tone_preference", "string", "1F3FA")
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "boolean", true),
            entry("live_conversion_preference", "boolean", false)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "boolean", true)
        ], version: 3)))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "null", true)
        ])))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "boolean", true)
        ], version: 1, shortcutIDs: ["symbols"])))
    }

    func testImporterRecognizesAndroidShapeWithoutClaimingNativeEnvelope() throws {
        XCTAssertNotNil(try AndroidPreferenceBackup.decodeIfMatching(json([
            entry("live_conversion_preference", "boolean", true)
        ])))
        XCTAssertNil(try AndroidPreferenceBackup.decodeIfMatching(PersonalBackup.encode(PersonalLexicon())))
        XCTAssertNil(try AndroidPreferenceBackup.decodeIfMatching(Data("{}".utf8)))
        XCTAssertThrowsError(try AndroidPreferenceBackup.decodeIfMatching(json([], version: 99)))
    }

    private func entry(_ key: String, _ type: String, _ value: Any) -> [String: Any] {
        ["key": key, "type": type, "value": value]
    }

    private func json(_ entries: [[String: Any]], version: Int = 1, shortcutIDs: [String]? = nil) -> Data {
        var object: [String: Any] = ["version": version, "entries": entries]
        if let shortcutIDs { object["shortcutIds"] = shortcutIDs }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
