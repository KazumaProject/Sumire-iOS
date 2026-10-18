import XCTest
import SumireCore

final class KeyboardSettingsMigrationTests: XCTestCase {
    func testMigrationPreservesSumireArrangementAndDoesNotResurrectRemovedOverrides() throws {
        let sourceName = "migration-source-" + UUID().uuidString
        let targetName = "migration-target-" + UUID().uuidString
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        defer {
            source.removePersistentDomain(forName: sourceName)
            target.removePersistentDomain(forName: targetName)
        }
        source.set("flick", forKey: "sumire.keyArrangement")
        source.set(3, forKey: "candidateRowCount")
        source.set(30, forKey: "appearance.tenKey.keyFontSize")
        var specialKeys = SumireSpecialKeySettings()
        try specialKeys.set(.doNothing, for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese)
        try specialKeys.save(defaults: source)
        target.set(2, forKey: "candidateRowCount")
        KeyboardSettings.migrateSettings(from: source, to: target)
        XCTAssertEqual(target.string(forKey: "sumire.keyArrangement"), "flick")
        XCTAssertEqual(target.integer(forKey: "candidateRowCount"), 2)
        XCTAssertEqual(target.integer(forKey: "appearance.tenKey.keyFontSize"), 30)
        XCTAssertEqual(try SumireSpecialKeySettings.load(defaults: target), specialKeys)
        target.removeObject(forKey: "sumire.keyArrangement")
        target.removeObject(forKey: "appearance.tenKey.keyFontSize")
        target.removeObject(forKey: SumireSpecialKeySettings.storageKey)
        KeyboardSettings.migrateSettings(from: source, to: target)
        XCTAssertNil(target.object(forKey: "sumire.keyArrangement"))
        XCTAssertNil(target.object(forKey: "appearance.tenKey.keyFontSize"))
        XCTAssertNil(target.object(forKey: SumireSpecialKeySettings.storageKey))
    }
}
