import XCTest
@testable import SumireCore

final class SumireSpecialKeySettingsTests: XCTestCase {
    func testReferenceDefaultDirectionsAndDynamicStates() {
        let defaults = SumireSpecialKeySettings()
        func action(_ key: SumireSpecialKeyID, _ gesture: SumireSpecialKeyGesture, _ arrangement: SumireKeyArrangement = .toggle,
                    _ mode: TenKeyMode = .japanese, composing: Bool = false) -> SumireSpecialKeyAction {
            defaults.action(for: key, gesture: gesture, arrangement: arrangement, mode: mode, hasComposition: composing)
        }
        XCTAssertEqual(action(.cursorLeft, .tap), .cursorLeft)
        XCTAssertEqual(action(.cursorLeft, .right), .cursorRight)
        XCTAssertEqual(action(.cursorLeft, .left), .none)
        XCTAssertEqual(action(.cursorLeft, .up), .none)
        XCTAssertEqual(action(.cursorLeft, .up, .cursor), .cursorUp)
        XCTAssertEqual(action(.cursorLeft, .down, .toggle, .english), .cursorDown)
        XCTAssertEqual(action(.cursorRight, .left, .flick), .cursorLeft)
        XCTAssertEqual(action(.cursorRight, .up, .flick), .none)
        XCTAssertEqual(action(.delete, .left), .deleteUntilBoundary)
        XCTAssertEqual(action(.delete, .up), .none)
        XCTAssertEqual(action(.delete, .down), .none)
        XCTAssertEqual(action(.paste, .up), .selectAll)
        XCTAssertEqual(action(.paste, .right), .copy)
        XCTAssertEqual(action(.spaceConvert, .tap), .space)
        XCTAssertEqual(action(.spaceConvert, .tap, composing: true), .convert)
        XCTAssertEqual(action(.spaceConvert, .left, composing: true), .none)
        XCTAssertEqual(action(.enter, .tap, composing: true), .confirm)
        XCTAssertEqual(action(.katakanaToggle, .tap, .cursor), .switchNumber)
        XCTAssertEqual(action(.katakanaToggle, .tap, .cursor, composing: true), .toggleKatakana)
        XCTAssertEqual(action(.keyboardSwitch, .longPress), .keyboardMenu)
        XCTAssertEqual(action(.delete, .longPress), .deleteBackward)
        XCTAssertEqual(action(.paste, .longPress), .none)
    }

    func testOverridesPersistIndependentlyAndResetRestoresDynamicDefault() throws {
        let name = "SpecialKeySettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = try SumireSpecialKeySettings.load(defaults: defaults)
        try settings.set(.undoDelete, for: .delete, gesture: .down, arrangement: .toggle, mode: .japanese)
        try settings.set(SumireSpecialKeyAction.none, for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese)
        try settings.set(.cursorRight, for: .delete, gesture: .longPress, arrangement: .toggle, mode: .japanese)
        try settings.set(.copy, for: .spaceConvert, gesture: .tap, arrangement: .cursor, mode: .english)
        try settings.save(defaults: defaults)
        settings = try SumireSpecialKeySettings.load(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(settings.action(for: .delete, gesture: .down, arrangement: .toggle, mode: .japanese), .undoDelete)
        XCTAssertEqual(settings.action(for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese), .none)
        XCTAssertEqual(settings.action(for: .delete, gesture: .left, arrangement: .flick, mode: .japanese), .deleteUntilBoundary)
        XCTAssertEqual(settings.action(for: .delete, gesture: .left, arrangement: .toggle, mode: .english), .deleteUntilBoundary)
        XCTAssertEqual(settings.action(for: .delete, gesture: .longPress, arrangement: .toggle, mode: .japanese), .cursorRight)
        settings.reset(key: .delete, arrangement: .toggle, mode: .japanese)
        XCTAssertEqual(settings.action(for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese), .deleteUntilBoundary)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .tap, arrangement: .cursor, mode: .english), .copy)
        try settings.set(nil, for: .spaceConvert, gesture: .tap, arrangement: .cursor, mode: .english)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .tap, arrangement: .cursor, mode: .english, hasComposition: true), .convert)
    }

    func testLongPressFollowsTapOverrideOnlyForRepeatableActions() throws {
        var settings = SumireSpecialKeySettings()
        try settings.set(.cursorRight, for: .delete, gesture: .tap, arrangement: .toggle, mode: .japanese)
        XCTAssertEqual(settings.action(for: .delete, gesture: .longPress, arrangement: .toggle, mode: .japanese), .cursorRight)
        try settings.set(.paste, for: .delete, gesture: .tap, arrangement: .toggle, mode: .japanese)
        XCTAssertEqual(settings.action(for: .delete, gesture: .longPress, arrangement: .toggle, mode: .japanese), .none)
    }

    func testCorruptionUnknownActionsDuplicatesAndVersionsDoNotOverwriteSavedData() throws {
        let name = "InvalidSpecialKeysTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = SumireSpecialKeySettings()
        try settings.set(.copy, for: .paste, gesture: .tap, arrangement: .toggle, mode: .japanese)
        try settings.save(defaults: defaults)
        let original = try XCTUnwrap(defaults.data(forKey: SumireSpecialKeySettings.storageKey))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let entries = try XCTUnwrap(payload["overrides"] as? [[String: Any]])
        var invalids: [[String: Any]] = []
        payload["version"] = 2; invalids.append(payload); payload["version"] = 1
        payload["overrides"] = entries + entries; invalids.append(payload)
        for (field, value) in [("action", "AndroidOnlyAction"), ("gesture", "bad"), ("key", "unknown"), ("arrangement", "unknown"), ("inputMode", 99)] as [(String, Any)] {
            var entry = entries[0]; entry[field] = value
            payload["overrides"] = [entry]; invalids.append(payload)
        }
        // The modifier is a normal key; arbitrary IDs cannot create editable keys.
        var unavailable = entries[0]; unavailable["key"] = SumireSpecialKeyID.cursorRight.rawValue
        payload["overrides"] = [unavailable]; invalids.append(payload)
        for invalid in invalids {
            XCTAssertThrowsError(try SumireSpecialKeySettings.decode(JSONSerialization.data(withJSONObject: invalid)))
            XCTAssertEqual(defaults.data(forKey: SumireSpecialKeySettings.storageKey), original)
        }
        XCTAssertThrowsError(try SumireSpecialKeySettings.decode(Data(repeating: 32, count: SumireSpecialKeySettings.maximumBytes + 1)))
        defaults.set("broken", forKey: SumireSpecialKeySettings.storageKey)
        XCTAssertThrowsError(try SumireSpecialKeySettings.load(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: SumireSpecialKeySettings.storageKey), "broken")
    }

    func testCurrentLayoutAliasesAndReferenceKeyLists() {
        XCTAssertEqual(SumireSpecialKeyID.resolve("number_mode", arrangement: .cursor, mode: .japanese), .katakanaToggle)
        XCTAssertEqual(SumireSpecialKeyID.resolve("number_mode", arrangement: .cursor, mode: .english), .numberMode)
        XCTAssertEqual(SumireSpecialKeyID.resolve("kana_mode", arrangement: .flick, mode: .number), .kanaMode)
        XCTAssertNil(SumireSpecialKeyID.resolve("dakuten_toggle_key", arrangement: .toggle, mode: .japanese))
        for arrangement in SumireKeyArrangement.allCases {
            for mode in TenKeyMode.allCases {
                let keys = SumireSpecialKeySettings.keys(arrangement: arrangement, mode: mode)
                XCTAssertEqual(Set(keys).count, keys.count)
                XCTAssertTrue(keys.contains(.keyboardSwitch))
                XCTAssertTrue(keys.contains(.delete))
            }
        }
    }
}
