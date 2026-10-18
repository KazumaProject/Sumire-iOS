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
        let seed = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO learned SELECT 'r'||x,'text',1,x,10 FROM n; UPDATE learning_state SET sequence=10000"
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
}
