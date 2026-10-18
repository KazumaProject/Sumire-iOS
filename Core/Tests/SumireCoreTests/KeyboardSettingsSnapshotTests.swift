import XCTest
@testable import SumireCore

final class KeyboardSettingsSnapshotTests: XCTestCase {
    func testRoundTripIncludesPerKeyboardGroupsOrientationsAndLibraries() throws {
        let name = "SumireSettingsBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3, forKey: "candidateRowCount")
        defaults.set(false, forKey: "englishReadingEnabled")
        defaults.set(0x3fff_ffff, forKey: "categoryMask")
        defaults.set("flick", forKey: "sumire.keyArrangement")
        defaults.set(true, forKey: "qwerty.english.flickUp")
        defaults.set(0.2, forKey: "theme.hue")
        defaults.set("dark", forKey: "theme.mode")
        defaults.set(0.35, forKey: "theme.saturation")
        defaults.set(0.65, forKey: "theme.brightness")
        for kind in KeyboardKind.allCases {
            var appearance = KeyboardAppearance.load(kind, defaults: defaults)
            appearance.keyFontSize = 23; appearance.guideFontSize = 14
            appearance.guidesVisible = true; appearance.keyScale = 0.85
            appearance.save(kind, group: .normal, defaults: defaults)
            appearance.keyFontSize = 16; appearance.guidesVisible = false
            appearance.save(kind, group: .special, defaults: defaults)
        }
        try KeyboardSizingStore(defaults: defaults).save(KeyboardSize(height: 350, width: 0.8, alignment: 0), for: .portrait)
        try KeyboardSizingStore(defaults: defaults).save(KeyboardSize(height: 180, width: 0.6, alignment: 1), for: .landscape)
        var romaji = RomajiLibrary()
        romaji.profiles = [RomajiProfile(name: "Test", rules: ["ka": RomajiRule("か", 2)])]
        romaji.activeID = romaji.profiles[0].id
        try romaji.save(defaults: defaults)
        try CustomKeyboardLibrary().save(defaults: defaults)
        var specialKeys = SumireSpecialKeySettings()
        try specialKeys.set(.doNothing, for: .delete, gesture: .left, arrangement: .toggle, mode: .japanese)
        try specialKeys.save(defaults: defaults)
        defaults.set("must not export", forKey: "unrelated.account")
        let original = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        XCTAssertNil(original.values["unrelated.account"])
        XCTAssertEqual(original.values["theme.saturation"], .number(0.35))
        XCTAssertEqual(original.values["theme.brightness"], .number(0.65))
        let restored = try JSONDecoder().decode(KeyboardSettingsSnapshot.self, from: JSONEncoder().encode(original))
        defaults.removePersistentDomain(forName: name)
        defaults.set("keep", forKey: "unrelated.account")
        defaults.set(true, forKey: "qwerty.english.flickDown")
        try restored.restore(defaults: defaults)
        XCTAssertEqual(try KeyboardSettingsSnapshot.capture(defaults: defaults), original)
        XCTAssertNil(defaults.object(forKey: "qwerty.english.flickDown"))
        XCTAssertEqual(defaults.string(forKey: "unrelated.account"), "keep")
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), romaji)
        XCTAssertEqual(try SumireSpecialKeySettings.load(defaults: defaults), specialKeys)
        XCTAssertEqual(KeyboardSizingStore(defaults: defaults).load(.portrait).height, 350)
        XCTAssertEqual(KeyboardSizingStore(defaults: defaults).load(.landscape).height, 180)
    }

    func testInvalidSettingsNeverPartiallyReplaceCurrentValues() throws {
        let name = "SumireSettingsBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "candidateRowCount")
        let original = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        let invalid: [(String, KeyboardSettingsSnapshot.Value)] = [
            ("candidateRowCount", .number(1.5)), ("categoryMask", .number(-1)),
            ("theme.hue", .number(.nan)), ("theme.saturation", .number(1.1)), ("theme.brightness", .number(-0.1)), ("theme.mode", .text("invalid")),
            ("englishReadingEnabled", .number(0)), ("unknown.key", .boolean(true)),
            ("appearance.english.keyScale", .number(0.1)),
            ("customRomaji.library", .data(Data("{}".utf8))),
            ("customKeyboard.library", .data(Data("{}".utf8))),
            (SumireSpecialKeySettings.storageKey, .data(Data("{}".utf8))),
            ("keyboardSize.portrait", .data(try JSONEncoder().encode(KeyboardSize(height: 100))))
        ]
        for (key, value) in invalid {
            var snapshot = KeyboardSettingsSnapshot()
            snapshot.values["candidateRowCount"] = .number(3)
            snapshot.values[key] = value
            XCTAssertThrowsError(try snapshot.restore(defaults: defaults), key)
            XCTAssertEqual(try KeyboardSettingsSnapshot.capture(defaults: defaults), original)
        }
        defaults.set("false", forKey: "englishReadingEnabled")
        XCTAssertThrowsError(try KeyboardSettingsSnapshot.capture(defaults: defaults))
    }
}
