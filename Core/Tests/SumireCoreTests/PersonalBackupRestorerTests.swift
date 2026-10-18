import XCTest
import SQLite3
@testable import SumireCore

final class PersonalBackupRestorerTests: XCTestCase {
    func testFailedLearningWriteRetainsJournalAndRetries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "backup-retry-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = PersonalLexiconStore(directory: root.appendingPathComponent("personal"))
        let url = root.appendingPathComponent("learning.sqlite")
        let journal = root.appendingPathComponent("pending.json")
        let learning = try LearningStore(url: url)
        try learning.record(reading: "old", text: "Old")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_restore BEFORE INSERT ON learned BEGIN SELECT RAISE(ABORT,'test failure'); END", nil, nil, nil), SQLITE_OK)
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: [.init(reading: "new", text: "New", count: 7)])
        let restorer = PersonalBackupRestorer(lexiconStore: store, defaults: defaults, learningURL: url, journalURL: journal)
        XCTAssertThrowsError(try restorer.restore(contents))
        XCTAssertEqual(try PersonalBackup.readContents(journal), contents)
        XCTAssertEqual(try learning.snapshot(), [.init(reading: "old", text: "Old", count: 1)])
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_restore", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try restorer.recover())
        XCTAssertEqual(try learning.snapshot(), contents.learning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testInterruptedRestoreReplaysSettingsLexiconAndLearning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "backup-restore-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PersonalLexiconStore(directory: root.appendingPathComponent("personal"))
        let learningURL = root.appendingPathComponent("learning.sqlite")
        let journal = root.appendingPathComponent("pending.json")
        let restorer = PersonalBackupRestorer(lexiconStore: store, defaults: defaults, learningURL: learningURL, journalURL: journal)
        var lexicon = PersonalLexicon()
        lexicon.words = [PersonalWord(word: "菫", reading: "すみれ")]
        var settings = KeyboardSettingsSnapshot()
        settings.values["candidateRowCount"] = .number(3)
        let contents = PersonalBackup.Contents(lexicon: lexicon, settings: settings,
                                              learning: [.init(reading: "iph", text: "iPhone", count: 5)])
        // Simulate termination after dictionary publication but before settings/learning.
        try store.save(lexicon)
        defaults.set(1, forKey: "candidateRowCount")
        try LearningStore(url: learningURL).record(reading: "old", text: "Old")
        try PersonalBackup.encode(contents).write(to: journal, options: .atomic)
        XCTAssertTrue(try restorer.recover())
        XCTAssertEqual(try store.load().lexicon, lexicon)
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 3)
        XCTAssertEqual(try LearningStore(url: learningURL).snapshot(), contents.learning)
        XCTAssertFalse(try restorer.recover())
        // A legacy backup replaces dictionaries only.
        try restorer.restore(.init(lexicon: PersonalLexicon()))
        XCTAssertEqual(defaults.integer(forKey: "candidateRowCount"), 3)
        XCTAssertEqual(try LearningStore(url: learningURL).snapshot(), contents.learning)
        // A malformed journal prevents mutation and remains available for diagnosis.
        try Data("broken".utf8).write(to: journal)
        XCTAssertThrowsError(try restorer.recover())
        XCTAssertThrowsError(try restorer.restore(contents))
        XCTAssertTrue(try store.load().lexicon.words.isEmpty)
        XCTAssertEqual(try Data(contentsOf: journal), Data("broken".utf8))
    }
}
