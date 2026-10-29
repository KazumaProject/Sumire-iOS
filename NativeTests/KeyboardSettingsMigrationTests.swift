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
        source.set(["medical"], forKey: DictionaryCategoryCatalog.selectionKey)
        source.set(["paste", "clipboard"], forKey: KeyboardToolbarPreferences.storageKey)
        var physicalShortcuts = PhysicalKeyboardShortcutStore()
        try physicalShortcuts.ensureDefaultShortcuts()
        try physicalShortcuts.save(defaults: source)
        let physicalShortcutData = try XCTUnwrap(source.data(forKey: PhysicalKeyboardShortcutStore.storageKey))
        var specialKeys = SumireSpecialKeySettings()
        try specialKeys.set(.doNothing, for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese)
        try specialKeys.save(defaults: source)
        target.set(2, forKey: "candidateRowCount")
        KeyboardSettings.migrateSettings(from: source, to: target)
        XCTAssertEqual(target.string(forKey: "sumire.keyArrangement"), "flick")
        XCTAssertEqual(target.integer(forKey: "candidateRowCount"), 2)
        XCTAssertEqual(target.integer(forKey: "appearance.tenKey.keyFontSize"), 30)
        XCTAssertEqual(target.stringArray(forKey: DictionaryCategoryCatalog.selectionKey), ["medical"])
        XCTAssertEqual(target.stringArray(forKey: KeyboardToolbarPreferences.storageKey), ["paste", "clipboard"])
        XCTAssertEqual(target.data(forKey: PhysicalKeyboardShortcutStore.storageKey), physicalShortcutData)
        XCTAssertEqual(try SumireSpecialKeySettings.load(defaults: target), specialKeys)
        target.removeObject(forKey: "sumire.keyArrangement")
        target.removeObject(forKey: "appearance.tenKey.keyFontSize")
        target.removeObject(forKey: DictionaryCategoryCatalog.selectionKey)
        target.removeObject(forKey: KeyboardToolbarPreferences.storageKey)
        target.removeObject(forKey: PhysicalKeyboardShortcutStore.storageKey)
        target.removeObject(forKey: SumireSpecialKeySettings.storageKey)
        KeyboardSettings.migrateSettings(from: source, to: target)
        XCTAssertNil(target.object(forKey: "sumire.keyArrangement"))
        XCTAssertNil(target.object(forKey: "appearance.tenKey.keyFontSize"))
        XCTAssertNil(target.object(forKey: DictionaryCategoryCatalog.selectionKey))
        XCTAssertNil(target.object(forKey: KeyboardToolbarPreferences.storageKey))
        XCTAssertNil(target.object(forKey: PhysicalKeyboardShortcutStore.storageKey))
        XCTAssertNil(target.object(forKey: SumireSpecialKeySettings.storageKey))
    }
}
