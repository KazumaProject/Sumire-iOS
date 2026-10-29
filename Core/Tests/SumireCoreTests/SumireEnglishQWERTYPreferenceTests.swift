import XCTest
@testable import SumireCore

final class SumireEnglishQWERTYPreferenceTests: XCTestCase {
    func testSettingsSnapshotCapturesAndRestoresPreference() throws {
        let suite = "SumireEnglishQWERTYPreferenceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: SumireModePreferences.englishQWERTYKey)
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        XCTAssertEqual(snapshot.values[SumireModePreferences.englishQWERTYKey], .boolean(true))

        defaults.set(false, forKey: SumireModePreferences.englishQWERTYKey)
        try snapshot.restore(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: SumireModePreferences.englishQWERTYKey))
    }

    func testAndroidPreferenceImportMapsValueAndUsesAndroidDefaultWhenOmitted() throws {
        let enabled = try AndroidPreferenceBackup.decode(Data(#"{"version":1,"entries":[{"key":"sumire_english_qwerty_preference","type":"boolean","value":true}]}"#.utf8))
        XCTAssertEqual(enabled.settings.values[SumireModePreferences.englishQWERTYKey], .boolean(true))

        let suite = "SumireEnglishQWERTYAndroidImport." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try enabled.apply(to: defaults)
        XCTAssertTrue(defaults.bool(forKey: SumireModePreferences.englishQWERTYKey))

        defaults.set(true, forKey: SumireModePreferences.englishQWERTYKey)
        let omitted = try AndroidPreferenceBackup.decode(Data(#"{"version":1,"entries":[]}"#.utf8))
        try omitted.apply(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: SumireModePreferences.englishQWERTYKey))
    }

    func testAndroidPreferenceRejectsWrongValueType() throws {
        let data = Data(#"{"version":1,"entries":[{"key":"sumire_english_qwerty_preference","type":"string","value":"true"}]}"#.utf8)
        XCTAssertThrowsError(try AndroidPreferenceBackup.decode(data))
    }
}
