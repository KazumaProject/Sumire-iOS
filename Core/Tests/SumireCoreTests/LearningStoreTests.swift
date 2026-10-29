import XCTest
import SQLite3
@testable import SumireCore

final class LearningStoreTests: XCTestCase {
    func testFrequencyPersistenceDeletionAndInvalidRecordPreservesData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        var store: LearningStore? = try LearningStore(url: url)
        try store!.record(reading: "すみれ", text: "菫🌸")
        try store!.record(reading: "すみれ", text: "すみれ")
        try store!.record(reading: "すみれ", text: "菫🌸")
        XCTAssertEqual(try store!.candidates(reading: "すみれ").map(\.text), ["菫🌸", "すみれ"])
        XCTAssertEqual(try store!.candidates(reading: "すみれ")[0].count, 2)
        XCTAssertThrowsError(try store!.record(reading: "", text: "invalid"))
        XCTAssertEqual(try store!.count, 2)
        store = nil
        let restored = try LearningStore(url: url)
        XCTAssertEqual(try restored.count, 2)
        try restored.remove(reading: "すみれ", text: "菫🌸")
        XCTAssertEqual(try restored.candidates(reading: "すみれ").map(\.text), ["すみれ"])
        try restored.clear()
        XCTAssertEqual(try restored.count, 0)
    }
    func testSnapshotRestoresFrequencyRecencyAndRejectsInvalidReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try LearningStore(url: directory.appendingPathComponent("original.sqlite"))
        try original.record(reading: "あ", text: "亜")
        try original.record(reading: "あ", text: "阿")
        try original.record(reading: "iph", text: "iPhone")
        try original.record(reading: "iph", text: "iPhone")
        let snapshot = try original.snapshot()
        let restored = try LearningStore(url: directory.appendingPathComponent("restored.sqlite"))
        try restored.restore(snapshot)
        XCTAssertEqual(try restored.snapshot(), snapshot)
        XCTAssertEqual(try restored.candidates(reading: "あ").map(\.text), ["阿", "亜"])
        XCTAssertEqual(try restored.candidates(reading: "iph").first?.count, 2)
        for invalid in [snapshot + [snapshot[0]], [LearningStore.Entry(reading: "x", text: "X", count: 0)]] {
            XCTAssertThrowsError(try restored.restore(invalid))
            XCTAssertEqual(try restored.snapshot(), snapshot)
        }
        try restored.record(reading: "あ", text: "亜")
        XCTAssertEqual(try restored.candidates(reading: "あ").first?.text, "亜")
        try restored.restore([])
        XCTAssertEqual(try restored.count, 0)
    }
    func testLegacyDatabaseMigratesToAndroidLearningMetadataWithoutLosingEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let setup = """
        CREATE TABLE learned(reading TEXT NOT NULL, text TEXT NOT NULL, frequency INTEGER NOT NULL, last_used INTEGER NOT NULL, byte_count INTEGER NOT NULL, PRIMARY KEY(reading,text));
        CREATE TABLE learning_state(id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL);
        INSERT INTO learned VALUES('わ','輪',3,9,6);
        INSERT INTO learning_state VALUES(1,9);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let migrated = try LearningStore(url: url)
        XCTAssertEqual(try migrated.snapshot(), [
            .init(reading: "わ", text: "輪", count: 3, score: 3_000, usageCount: 3)
        ])
        var versionDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &versionDB), SQLITE_OK)
        defer { sqlite3_close(versionDB) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(versionDB, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
    }
    func testLearningSessionUpsertReinforcesScoreAndMergesAndroidMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))

        try store.upsertLearningEntries([
            .init(input: "あ", output: "亜", score: 8_000, leftID: 12, rightID: 13, lastUsedAt: 100, isPhrase: false)
        ])
        try store.upsertLearningEntries([
            .init(input: "あ", output: "亜", score: 6_000, leftID: nil, rightID: 99, usageCount: 2, lastUsedAt: 200, isPhrase: true)
        ])

        XCTAssertEqual(try store.snapshot(), [
            .init(reading: "あ", text: "亜", count: 3, score: 4_500, leftID: 12, rightID: 99, usageCount: 3, lastUsedAt: 200, isPhrase: true)
        ])
        let snapshot = try store.snapshot()
        let backup = PersonalBackup.Contents(lexicon: PersonalLexicon(), learning: snapshot)
        XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(backup)).learning, snapshot)

        let restored = try LearningStore(url: directory.appendingPathComponent("restored.sqlite"))
        try restored.restore(snapshot)
        XCTAssertEqual(try restored.snapshot(), snapshot)
    }
    func testLearningSessionBatchProcessesDuplicateRowsInOrderLikeAndroidDao() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))

        try store.upsertLearningEntries([
            .init(input: "あ", output: "亜", score: 8_000, leftID: 12, rightID: 13, lastUsedAt: 100, isPhrase: false),
            .init(input: "あ", output: "亜", score: 6_000, leftID: nil, rightID: 99, usageCount: 2, lastUsedAt: 200, isPhrase: true)
        ])

        XCTAssertEqual(try store.snapshot(), [
            .init(reading: "あ", text: "亜", count: 3, score: 4_500, leftID: 12, rightID: 99, usageCount: 3, lastUsedAt: 200, isPhrase: true)
        ])
    }
    func testLearningSessionBatchRollsBackWhenSQLiteRejectsAnyEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: url)
        try store.record(reading: "old", text: "保持")
        let before = try store.snapshot()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_session BEFORE INSERT ON learned WHEN NEW.reading='reject' BEGIN SELECT RAISE(ABORT,'test failure'); END", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try store.upsertLearningEntries([
            .init(input: "new", output: "新規", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false),
            .init(input: "reject", output: "拒否", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false)
        ]))
        XCTAssertEqual(try store.snapshot(), before)
    }
    func testLearningSessionUpsertAppliesAndroidMixedSymbolEligibilityBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))

        try store.upsertLearningEntries([
            .init(input: "れいわ", output: "令和8年", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false),
            .init(input: "ばんごう", output: "123", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false),
            .init(input: "ことば", output: "言葉", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 3, isPhrase: false),
            .init(input: "空", output: "   ", score: 3_000, leftID: nil, rightID: nil, lastUsedAt: 4, isPhrase: false)
        ], allowJapaneseWithSymbolsAndNumbers: false)

        XCTAssertEqual(try store.snapshot().map(\.text), ["言葉"])
    }
    func testMixedSymbolLearningCanBeDisabledAndEnabledWithoutLearningSymbolOnlyRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))
        let mixed = LearningSessionEntry(
            input: "れいわはちねん", output: "令和8年", score: 3_000,
            leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false
        )
        let symbolsOnly = LearningSessionEntry(
            input: "ばんごう", output: "123", score: 3_000,
            leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false
        )

        try store.upsertLearningEntries([mixed, symbolsOnly], allowJapaneseWithSymbolsAndNumbers: false)
        XCTAssertTrue(try store.snapshot().isEmpty)

        try store.upsertLearningEntries([mixed, symbolsOnly], allowJapaneseWithSymbolsAndNumbers: true)
        XCTAssertEqual(try store.snapshot().map(\.text), ["令和8年"])
    }
    func testEntryDecodesLegacyBackupAndSnapshotKeysUseExactUTF8() throws {
        let legacy = Data(#"{"reading":"あ","text":"亜","count":2}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LearningStore.Entry.self, from: legacy),
                       .init(reading: "あ", text: "亜", count: 2, usageCount: 2))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LearningStore(url: directory.appendingPathComponent("learning.sqlite"))
        let composed = "が", decomposed = "か\u{3099}"
        try store.restore([
            .init(reading: composed, text: "我", count: 1),
            .init(reading: decomposed, text: "我", count: 1)
        ])
        XCTAssertEqual(try store.count, 2)
        XCTAssertEqual(try store.candidates(reading: composed).map(\.reading), [composed])
    }
    func testRestoreRollsBackWhenDatabaseRejectsInsert() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: url)
        try store.record(reading: "old", text: "Old")
        let before = try store.snapshot()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_restore BEFORE INSERT ON learned WHEN NEW.reading='reject' BEGIN SELECT RAISE(ABORT,'test failure'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.restore([
            .init(reading: "new", text: "New", count: 2),
            .init(reading: "reject", text: "Rejected", count: 1)
        ]))
        XCTAssertEqual(try store.snapshot(), before)
        try store.record(reading: "old", text: "Old")
        XCTAssertEqual(try store.candidates(reading: "old").first?.count, 2)
    }
    func testUnsupportedAndCorruptDatabaseAreNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("future.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try LearningStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        let bytes = Data("not sqlite".utf8)
        try bytes.write(to: corrupt)
        XCTAssertThrowsError(try LearningStore(url: corrupt))
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
    }
    func testInvalidStoredFrequencyIsRejectedBeforeScoring() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: url)
        try store.record(reading: "あ", text: "亜")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE learned SET frequency=-9223372036854775808", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.candidates(reading: "あ"))
    }
    func testRecordCountBudgetEvictsOldestWholeEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let seed = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO learned(reading,text,frequency,last_used,byte_count) SELECT 'r'||x,'text',1,x,10 FROM n; UPDATE learning_state SET sequence=10000"
        XCTAssertEqual(sqlite3_exec(db, seed, nil, nil, nil), SQLITE_OK)
        try store.record(reading: "latest", text: "新規")
        XCTAssertEqual(try store.count, 10000)
        XCTAssertTrue(try store.candidates(reading: "r1").isEmpty)
        XCTAssertEqual(try store.candidates(reading: "latest").first?.text, "新規")
    }
    func testSeparateConnectionsObserveCommitsAndBoundTextBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let writer = try LearningStore(url: url), reader = try LearningStore(url: url)
        let text = String(repeating: "a", count: 65536)
        for i in 0..<260 { try writer.record(reading: "r\(i)", text: text) }
        XCTAssertLessThanOrEqual(try reader.count, 255)
        XCTAssertTrue(try reader.candidates(reading: "r0").isEmpty)
        XCTAssertEqual(try reader.candidates(reading: "r259").first?.text, text)
        try writer.clear()
        XCTAssertEqual(try reader.count, 0)
    }
    func testLearningMetadataPersistsAcrossReopenAndExactLookupRemainsExact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let expected = LearningStore.Entry(reading: "あ", text: "亜", count: 2, score: 123,
            leftID: Int16.min, rightID: Int16.max, usageCount: 2, lastUsedAt: 456, isPhrase: true)
        do {
            let writer = try LearningStore(url: url)
            try writer.upsertLearningEntries([
                .init(input: expected.reading, output: expected.text, score: expected.score,
                      leftID: expected.leftID, rightID: expected.rightID, usageCount: expected.usageCount,
                      lastUsedAt: expected.lastUsedAt, isPhrase: expected.isPhrase)
            ])
        }
        let reopened = try LearningStore(url: url)
        XCTAssertEqual(try reopened.snapshot(), [expected])
        XCTAssertEqual(try reopened.candidates(reading: "あ"), [expected])
        XCTAssertTrue(try reopened.candidates(reading: "あい").isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(LearningStore.Entry.self,
            from: JSONEncoder().encode(expected)), expected)
    }

    func testMigrationFailureRollsBackEarlierAlterAndPreservesVersionOneRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("learning.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        // A malformed v1 schema already contains left_id: the second ALTER
        // fails after the first ALTER(score) has succeeded inside the transaction.
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE learned(reading TEXT,text TEXT,frequency INTEGER,last_used INTEGER,byte_count INTEGER,left_id INTEGER); INSERT INTO learned VALUES('あ','亜',2,1,6,7); PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try LearningStore(url: url))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT text,frequency,left_id FROM learned", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "亜")
        XCTAssertEqual(sqlite3_column_int(statement, 1), 2)
        XCTAssertEqual(sqlite3_column_int(statement, 2), 7)
        sqlite3_finalize(statement)
        XCTAssertNotEqual(sqlite3_prepare_v2(db, "SELECT score FROM learned", -1, &statement, nil), SQLITE_OK)
        sqlite3_finalize(statement)
    }

}
