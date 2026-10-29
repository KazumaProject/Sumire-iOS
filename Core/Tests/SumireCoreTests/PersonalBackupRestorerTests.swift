import XCTest
import SQLite3
@testable import SumireCore

final class PersonalBackupRestorerTests: XCTestCase {
    func testCommittedFragmentMetadataSurvivesPortableBackupRestoreAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "backup-metadata-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        var session = ConversionLearningSession()
        XCTAssertTrue(session.append(
            LearningFragment(reading: "あ😀", output: "亜😀", candidateScore: 8_000,
                candidateIndex: 1, leftID: 7, rightID: 11, explicitlySelected: true),
            from: "あ😀う", remainingInput: "う"))
        XCTAssertTrue(session.append(
            LearningFragment(reading: "う", output: "宇", candidateScore: 9_000,
                candidateIndex: 2, leftID: nil, rightID: 23, explicitlySelected: true),
            from: "う", remainingInput: ""))
        let fragments = session.finish(learnFirstCandidate: false, timestamp: 1_000)
        XCTAssertEqual(fragments.count, 3)
        XCTAssertEqual(fragments.map(\.isPhrase), [false, false, true])

        let expected: [LearningStore.Entry] = [
            .init(reading: "あ😀", text: "亜😀", count: 3, score: 6_000,
                  leftID: 7, rightID: 11, usageCount: 3, lastUsedAt: 2_000),
            .init(reading: "う", text: "宇", count: 3, score: 6_500,
                  leftID: nil, rightID: 23, usageCount: 3, lastUsedAt: 2_000),
            .init(reading: "あ😀う", text: "亜😀宇", count: 3, score: 6_250,
                  leftID: 7, rightID: 23, usageCount: 3, lastUsedAt: 2_000, isPhrase: true),
            // Backup preserves stored metadata; it must not invent native
            // fallback IDs, clamp signed costs, or conflate the two counters.
            .init(reading: "き", text: "木", count: 1_000_000, score: Int32.min,
                  leftID: nil, rightID: nil, usageCount: Int32.max, lastUsedAt: Int64.max),
            .init(reading: "き", text: "樹", count: 2, score: Int32.max,
                  leftID: Int16.min, rightID: nil, usageCount: 5, lastUsedAt: 0),
        ]
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let archiveURL = root.appendingPathComponent("personal.sumirebackup")
        do {
            let source = try LearningStore(url: sourceURL)
            try source.upsertLearningEntries(fragments)
            try source.upsertLearningEntries(fragments.map {
                LearningSessionEntry(input: $0.input, output: $0.output, score: $0.score,
                    leftID: $0.leftID, rightID: $0.rightID, usageCount: 2,
                    lastUsedAt: 2_000, isPhrase: $0.isPhrase)
            })
            XCTAssertEqual(try source.snapshot(), Array(expected.prefix(3)))
            try source.restore(try source.snapshot() + Array(expected.suffix(2)))
            let snapshot = try source.snapshot()
            XCTAssertEqual(snapshot, expected)
            try PersonalBackup.encode(.init(lexicon: PersonalLexicon(), learning: snapshot))
                .write(to: archiveURL, options: .atomic)
        }

        let archive = try Data(contentsOf: archiveURL)
        let decoded = try PersonalBackup.decodeContents(archive)
        XCTAssertEqual(try PersonalBackup.readContents(archiveURL), decoded)
        XCTAssertEqual(decoded.learning, expected)
        XCTAssertNil(decoded.settings)

        let destinationURL = root.appendingPathComponent("restored.sqlite")
        do { try LearningStore(url: destinationURL).record(reading: "old", text: "Old") }
        let restorer = PersonalBackupRestorer(
            lexiconStore: PersonalLexiconStore(directory: root.appendingPathComponent("personal")),
            defaults: defaults, learningURL: destinationURL,
            journalURL: root.appendingPathComponent("pending.json"))
        try restorer.restore(decoded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restorer.journalURL.path))
        XCTAssertFalse(try restorer.recover())
        do {
            let reopened = try LearningStore(url: destinationURL)
            XCTAssertEqual(try reopened.snapshot(), expected)
            XCTAssertEqual(try reopened.candidates(reading: "き"), Array(expected.suffix(2)))
            XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(
                .init(lexicon: PersonalLexicon(), learning: reopened.snapshot()))).learning, expected)
        }
        XCTAssertEqual(try LearningStore(url: sourceURL).snapshot(), expected)
    }

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
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: [
            .init(reading: "new", text: "New", count: 7, score: -123, leftID: nil,
                  rightID: 29, usageCount: 11, lastUsedAt: 456, isPhrase: true),
            .init(reading: "nil", text: "Nil", count: 2, score: Int32.max,
                  leftID: nil, rightID: nil, usageCount: 9, lastUsedAt: Int64.max),
        ])
        let restorer = PersonalBackupRestorer(lexiconStore: store, defaults: defaults, learningURL: url, journalURL: journal)
        XCTAssertThrowsError(try restorer.restore(contents))
        XCTAssertEqual(try PersonalBackup.readContents(journal), contents)
        XCTAssertEqual(try learning.snapshot(), [.init(reading: "old", text: "Old", count: 1)])
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_restore", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try restorer.recover())
        XCTAssertEqual(try learning.snapshot(), contents.learning)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), contents.learning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(try restorer.recover())
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
