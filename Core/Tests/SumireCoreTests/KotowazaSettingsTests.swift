import XCTest
@testable import SumireCore

final class KotowazaSettingsTests: XCTestCase {
    func testDefaultAndroidImportAndPortableSettingsRoundTrip() throws {
        let name = "KotowazaSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(KotowazaSettings.isEnabled(defaults: defaults))
        let data = Data(#"{"version":1,"entries":[{"key":"proverb_prediction_enable_preference","type":"boolean","value":false}]}"#.utf8)
        let imported = try AndroidPreferenceBackup.decode(data)
        XCTAssertEqual(imported.settings.values[KotowazaSettings.enabledKey], .boolean(false))
        try imported.settings.restore(defaults: defaults)
        XCTAssertFalse(KotowazaSettings.isEnabled(defaults: defaults))
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        let decoded = try JSONDecoder().decode(KeyboardSettingsSnapshot.self, from: JSONEncoder().encode(snapshot))
        defaults.removePersistentDomain(forName: name)
        try decoded.restore(defaults: defaults)
        XCTAssertFalse(KotowazaSettings.isEnabled(defaults: defaults))
        let omitted = try AndroidPreferenceBackup.decode(Data(#"{"version":1,"entries":[]}"#.utf8))
        XCTAssertEqual(omitted.settings.values[KotowazaSettings.enabledKey], .boolean(true))
    }
}
