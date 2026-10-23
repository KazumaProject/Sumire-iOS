import XCTest
@testable import SumireCore

final class KeyboardToolbarPreferencesTests: XCTestCase {
    func testLoadPreservesTheExistingToolbarOrderByDefault() {
        let defaults = makeDefaults()
        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), [.resize, .emoji, .paste])
    }

    func testLegacyIOSSymbolsActionUsesTheAndroidEmojiIdentifier() {
        let defaults = makeDefaults()
        defaults.set(["resize", "symbols", "paste"], forKey: KeyboardToolbarPreferences.storageKey)

        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), [.resize, .emoji, .paste])
        XCTAssertEqual(KeyboardToolbarPreferences.save([.resize, .emoji, .paste], defaults: defaults), [.resize, .emoji, .paste])
        XCTAssertEqual(defaults.stringArray(forKey: KeyboardToolbarPreferences.storageKey), ["resize", "emoji", "paste"])
    }

    func testSavePreservesOrderAndRemovesDuplicates() {
        let defaults = makeDefaults()
        let saved = KeyboardToolbarPreferences.save([.resize, .selectDate, .keyboardPicker, .liveConversionToggle, .learningPause, .emoji, .resize], defaults: defaults)
        XCTAssertEqual(saved, [.resize, .selectDate, .keyboardPicker, .liveConversionToggle, .learningPause, .emoji])
        XCTAssertEqual(defaults.stringArray(forKey: KeyboardToolbarPreferences.storageKey), ["resize", "select_date", "keyboard_picker", "live_conversion_toggle", "learning_pause", "emoji"])
        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), [.resize, .selectDate, .keyboardPicker, .liveConversionToggle, .learningPause, .emoji])
    }

    func testLoadDropsUnknownValuesAndUsesDefaultWhenNothingIsSupported() {
        let defaults = makeDefaults()
        defaults.set(["future_android_action", "paste", "paste"], forKey: KeyboardToolbarPreferences.storageKey)
        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), [.paste])

        defaults.set(["future_android_action"], forKey: KeyboardToolbarPreferences.storageKey)
        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), KeyboardToolbarPreferences.defaultActions)
    }

    func testSavingAnEmptyListKeepsAtLeastOneToolbarAction() {
        let defaults = makeDefaults()
        XCTAssertEqual(KeyboardToolbarPreferences.save([], defaults: defaults), KeyboardToolbarPreferences.defaultActions)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "KeyboardToolbarPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
