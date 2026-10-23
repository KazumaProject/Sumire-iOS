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
            entry("clipboard_preview_enable_preference", "boolean", false),
            entry("android.only.setting", "string", "kept out of iOS settings")
        ]))

        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.importedSettingCount, 5)
        XCTAssertEqual(backup.unsupportedEntryCount, 2)
        XCTAssertEqual(backup.settings.values["liveConversion"], .boolean(true))
        XCTAssertEqual(backup.settings.values["omissionSearch"], .boolean(false))
        XCTAssertEqual(backup.settings.values["bunsetsuSeparation"], .boolean(true))
        XCTAssertEqual(backup.settings.values["learningEnabled"], .boolean(false))
        XCTAssertEqual(backup.settings.values["learnFirstCandidate"], .boolean(true))

        let suite = "AndroidPreferenceBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "englishReadingEnabled")
        defaults.set(3, forKey: "candidateRowCount")
        try backup.apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: "liveConversion"))
        XCTAssertFalse(defaults.bool(forKey: "omissionSearch"))
        XCTAssertTrue(defaults.bool(forKey: "bunsetsuSeparation"))
        XCTAssertFalse(defaults.bool(forKey: "learningEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "learnFirstCandidate"))
        XCTAssertTrue(defaults.bool(forKey: "englishReadingEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 3)
        XCTAssertNil(defaults.object(forKey: "clipboardAutomaticPreview"))
    }

    func testNullRemovesOnlyMappedPreferenceAndVersionTwoRetainsNoToolbarMutation() throws {
        let data = json([
            ["key": "live_conversion_preference", "type": "null"],
            entry("learn_dictionary_preference", "boolean", true)
        ], version: 2, shortcutIDs: ["symbols", "emoji"])
        let backup = try AndroidPreferenceBackup.decode(data)
        XCTAssertEqual(backup.shortcutIDs, ["symbols", "emoji"])
        XCTAssertEqual(backup.removingKeys, ["liveConversion"])

        let suite = "AndroidPreferenceBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "liveConversion")
        defaults.set(2, forKey: "candidateRowCount")
        try backup.apply(to: defaults)
        XCTAssertNil(defaults.object(forKey: "liveConversion"))
        XCTAssertTrue(defaults.bool(forKey: "learningEnabled"))
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 2)
    }

    func testMalformedAndAmbiguousMappedEntriesAreRejected() throws {
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(json([
            entry("live_conversion_preference", "string", "true")
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
