import XCTest
@testable import SumireCore

final class JapanesePredictionSettingsTests: XCTestCase {
    func testAndroidDefaultsLegacyValuesAndBounds() throws {
        let suite = "JapanesePredictionSettings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(JapanesePredictionSettings.load(defaults: defaults), JapanesePredictionSettings())
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("short"), 1)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("standard"), 3)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("long"), 6)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("5"), 5)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("99"), 6)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("0"), 1)
        XCTAssertEqual(JapanesePredictionSettings.androidLookahead("unknown"), 3)

        defaults.set(0, forKey: JapanesePredictionSettings.lookaheadStorageKey)
        defaults.set("unknown", forKey: JapanesePredictionSettings.aggressivenessStorageKey)
        XCTAssertEqual(JapanesePredictionSettings.load(defaults: defaults),
                       JapanesePredictionSettings(lookaheadCharacterCount: 1, aggressiveness: .standard))
        defaults.set(true, forKey: JapanesePredictionSettings.lookaheadStorageKey)
        XCTAssertEqual(JapanesePredictionSettings.load(defaults: defaults).lookaheadCharacterCount, 3)
    }

    func testSnapshotIncludesOnlyBoundedPredictionSettings() throws {
        let suite = "JapanesePredictionSettingsSnapshot." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(6, forKey: JapanesePredictionSettings.lookaheadStorageKey)
        defaults.set("aggressive", forKey: JapanesePredictionSettings.aggressivenessStorageKey)
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        XCTAssertEqual(snapshot.values[JapanesePredictionSettings.lookaheadStorageKey], .number(6))
        XCTAssertEqual(snapshot.values[JapanesePredictionSettings.aggressivenessStorageKey], .text("aggressive"))

        var invalid = KeyboardSettingsSnapshot()
        invalid.values[JapanesePredictionSettings.lookaheadStorageKey] = .number(7)
        XCTAssertThrowsError(try invalid.validate())
        invalid = KeyboardSettingsSnapshot()
        invalid.values[JapanesePredictionSettings.aggressivenessStorageKey] = .text("unknown")
        XCTAssertThrowsError(try invalid.validate())
    }
    func testAndroidInt32StringNormalization() {
        for raw in ["2147483648", "-2147483649", "4294967296"] {
            XCTAssertEqual(JapanesePredictionSettings.androidLookahead(raw), 3, "Kotlin toIntOrNull rejects Int32 overflow")
        }
    }

}
