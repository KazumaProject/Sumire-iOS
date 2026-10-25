import XCTest
@testable import SumireCore

final class PersonalBackupTests: XCTestCase {
    func testVersionTwoCarriesValidatedSettingsAndVersionOneLeavesThemAbsent() throws {
        var lexicon = PersonalLexicon()
        lexicon.words = [PersonalWord(word: "MyPhone", reading: "iphone")]
        var settings = KeyboardSettingsSnapshot()
        settings.values["englishReadingEnabled"] = .boolean(false)
        settings.values["candidateRowCount"] = .number(3)
        settings.values["appearance.english.special.keyScale"] = .number(0.85)
        settings.values[KeyboardToolbarPreferences.storageKey] = .textArray([
            KeyboardToolbarAction.resize.rawValue,
            KeyboardToolbarAction.selectDate.rawValue,
            KeyboardToolbarAction.keyboardPicker.rawValue,
            KeyboardToolbarAction.liveConversionToggle.rawValue,
            KeyboardToolbarAction.clipboard.rawValue,
            KeyboardToolbarAction.template.rawValue,
            KeyboardToolbarAction.emoji.rawValue,
            KeyboardToolbarAction.paste.rawValue
        ])
        let suite = "ShortcutBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var shortcuts = PhysicalKeyboardShortcutStore()
        try shortcuts.ensureDefaultShortcuts()
        try shortcuts.save(defaults: defaults)
        settings.values[PhysicalKeyboardShortcutStore.storageKey] = .data(
            try XCTUnwrap(defaults.data(forKey: PhysicalKeyboardShortcutStore.storageKey)))
        let contents = PersonalBackup.Contents(lexicon: lexicon, settings: settings)
        let encoded = try PersonalBackup.encode(contents)
        let restored = try PersonalBackup.decodeContents(encoded)
        XCTAssertEqual(restored, contents)
        XCTAssertEqual(restored.settings?.values[KeyboardToolbarPreferences.storageKey], settings.values[KeyboardToolbarPreferences.storageKey])
        guard case .data(let restoredShortcutData)? = restored.settings?.values[PhysicalKeyboardShortcutStore.storageKey] else {
            return XCTFail("The physical keyboard shortcut store was omitted from the personal backup")
        }
        XCTAssertEqual(try PhysicalKeyboardShortcutStore.decode(restoredShortcutData), shortcuts)
        XCTAssertEqual(try PersonalBackup.decode(encoded), lexicon)
        let legacy = try PersonalBackup.decodeContents(PersonalBackup.encode(lexicon))
        XCTAssertEqual(legacy.lexicon, lexicon)
        XCTAssertNil(legacy.settings)
        settings.values["candidateRowCount"] = .number(9)
        XCTAssertThrowsError(try PersonalBackup.encode(PersonalBackup.Contents(lexicon: lexicon, settings: settings)))
        var damaged = encoded; damaged.removeLast()
        XCTAssertThrowsError(try PersonalBackup.decodeContents(damaged))
    }
    func testLearningSnapshotRoundTripAndLegacyPreservation() throws {
        let entries: [LearningStore.Entry] = [
            .init(reading: "iph", text: "iPhone", count: 42),
            .init(reading: "すみれ", text: "菫🌸", count: 3)
        ]
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: entries)
        let encoded = try PersonalBackup.encode(contents)
        XCTAssertEqual(try PersonalBackup.decodeContents(encoded), contents)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 3)
        var downgraded = envelope; downgraded["version"] = 2
        XCTAssertThrowsError(try PersonalBackup.decodeContents(JSONSerialization.data(withJSONObject: downgraded)))
        XCTAssertNil(try PersonalBackup.decodeContents(PersonalBackup.encode(PersonalLexicon())).learning)
        XCTAssertNil(try PersonalBackup.decodeContents(PersonalBackup.encode(PersonalBackup.Contents(lexicon: PersonalLexicon(), settings: KeyboardSettingsSnapshot()))).learning)
        let empty = PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: [])
        XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(empty)).learning, [])
        XCTAssertThrowsError(try PersonalBackup.encode(PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: entries + [entries[0]])))
    }
    func testPortableSnapshotPreservesUnicodeAndRestoresThroughGenerationStore() throws {
        var lexicon = PersonalLexicon()
        lexicon.words = [PersonalWord(word: "菫🌸", reading: "すみれ", posIndex: 3, posScore: -123)]
        lexicon.templates = [PersonalWord(word: "一行目\n二行目👨‍👩‍👧", reading: "てんぷれ")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("backup.json")
        try PersonalBackup.encode(lexicon).write(to: file)
        let restored = try PersonalBackup.read(file)
        XCTAssertEqual(restored, lexicon)
        let store = PersonalLexiconStore(directory: directory.appendingPathComponent("store"))
        try store.save(restored)
        XCTAssertEqual(try store.load().lexicon, lexicon)
    }
    func testExplicitRestoreRecoversUnreadableStoreWithoutDeletingOldGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLexiconStore(directory: directory)
        var original = PersonalLexicon()
        original.words = [PersonalWord(word: "復旧", reading: "ふっきゅう")]
        let backup = try PersonalBackup.encode(original)
        let old = try store.save(original)
        let generation = directory.appendingPathComponent(old.generation)
        let oldBytes = try Data(contentsOf: generation)
        try Data("broken pointer".utf8).write(to: directory.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try store.load())
        try store.save(PersonalBackup.decode(backup))
        XCTAssertEqual(try store.load().lexicon, original)
        XCTAssertEqual(try Data(contentsOf: generation), oldBytes)
    }
    func testInvalidBackupCannotReplaceExistingData() throws {
        var original = PersonalLexicon()
        original.words = [PersonalWord(word: "保持", reading: "ほじ")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLexiconStore(directory: directory)
        try store.save(original)
        let encoded = try PersonalBackup.encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in [("version", 99 as Any), ("format", "other" as Any), ("sha256", "bad" as Any), ("payload", Data("broken".utf8).base64EncodedString() as Any)] {
            var changed = object
            changed[key] = value
            let data = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try store.save(PersonalBackup.decode(data)))
            XCTAssertEqual(try store.load().lexicon, original)
        }
        XCTAssertThrowsError(try PersonalBackup.decode(encoded.dropLast()))
        var invalid = original
        invalid.words.append(original.words[0])
        XCTAssertThrowsError(try PersonalBackup.encode(invalid))
    }
}
