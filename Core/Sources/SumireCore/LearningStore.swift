import Foundation
import SQLite3

/// Synchronous SQLite storage; call from the conversion queue, not the UI thread.
/// No input is stored unless the caller explicitly records a committed candidate.
public final class LearningStore {
    public struct Entry: Codable, Equatable {
        public let reading: String
        public let text: String
        public let count: Int64
        public init(reading: String, text: String, count: Int64) {
            self.reading = reading; self.text = text; self.count = count
        }
    }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 250)
            try execute("PRAGMA cache_size=-1024")
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw PersonalDataError("未対応の学習データ形式です") }
            if version == 0 {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                    throw PersonalDataError("学習データ以外のデータベースは変更しません")
                }
            }
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS learned(reading TEXT NOT NULL, text TEXT NOT NULL, frequency INTEGER NOT NULL, last_used INTEGER NOT NULL, byte_count INTEGER NOT NULL, PRIMARY KEY(reading,text))")
                try execute("CREATE TABLE IF NOT EXISTS learning_state(id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL)")
                try execute("INSERT OR IGNORE INTO learning_state VALUES(1,0)")
                try execute("PRAGMA user_version=1")
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    public func record(reading: String, text: String) throws {
        let word = PersonalWord(word: text, reading: reading)
        try word.validate()
        try transaction {
            try execute("UPDATE learning_state SET sequence=sequence+1 WHERE id=1")
            let statement = try prepare("INSERT INTO learned VALUES(?,?,1,(SELECT sequence FROM learning_state WHERE id=1),?) ON CONFLICT(reading,text) DO UPDATE SET frequency=min(learned.frequency+1,1000000),last_used=excluded.last_used")
            defer { sqlite3_finalize(statement) }
            try bind(reading, to: statement, at: 1); try bind(text, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(reading.utf8.count + text.utf8.count))
            try stepDone(statement)
            // Retain the most recently used whole records within both budgets.
            try execute("DELETE FROM learned WHERE rowid IN (SELECT rid FROM (SELECT rowid AS rid,row_number() OVER(ORDER BY last_used DESC) AS position,sum(byte_count) OVER(ORDER BY last_used DESC) AS bytes FROM learned) WHERE position>10000 OR bytes>16777216)")
        }
    }
    public func candidates(reading: String, limit: Int = 20) throws -> [Entry] {
        guard (1...100).contains(limit), !reading.contains("\0") else { throw PersonalDataError("学習検索条件が不正です") }
        let statement = try prepare("SELECT text,frequency FROM learned WHERE reading=? ORDER BY frequency DESC,last_used DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try bind(reading, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var entries: [Entry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return entries }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw failure() }
            guard let text = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8) else {
                throw PersonalDataError("学習データの文字コードが不正です")
            }
            let frequency = sqlite3_column_int64(statement, 1)
            guard (1...1000000).contains(frequency) else { throw PersonalDataError("学習データの頻度が不正です") }
            try PersonalWord(word: text, reading: reading).validate()
            entries.append(Entry(reading: reading, text: text, count: frequency))
        }
    }
    /// Entries are oldest first, retaining recency for equal-frequency candidates.
    public func snapshot() throws -> [Entry] {
        let statement = try prepare("SELECT reading,text,frequency FROM learned ORDER BY last_used ASC,rowid ASC")
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        var totalBytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            totalBytes += Int(sqlite3_column_bytes(statement, 0)) + Int(sqlite3_column_bytes(statement, 1))
            guard totalBytes <= 16777216 else { throw PersonalDataError("学習データが大きすぎます") }
            func string(_ column: Int32) throws -> String {
                guard let bytes = sqlite3_column_text(statement, column),
                      let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
                    throw PersonalDataError("学習データの文字コードが不正です")
                }
                return value
            }
            entries.append(Entry(reading: try string(0), text: try string(1), count: sqlite3_column_int64(statement, 2)))
            guard entries.count <= 10000 else { throw PersonalDataError("学習データが多すぎます") }
        }
        try Self.validateSnapshot(entries)
        return entries
    }
    public static func validateSnapshot(_ entries: [Entry]) throws {
        guard entries.count <= 10000 else { throw PersonalDataError("学習データが多すぎます") }
        var keys = Set<String>(), bytes = 0
        for entry in entries {
            try PersonalWord(word: entry.text, reading: entry.reading).validate()
            guard (1...1000000).contains(entry.count),
                  keys.insert("\(entry.reading.utf8.count):" + entry.reading + entry.text).inserted else {
                throw PersonalDataError("学習データの頻度または重複が不正です")
            }
            bytes += entry.reading.utf8.count + entry.text.utf8.count
            guard bytes <= 16777216 else { throw PersonalDataError("学習データが大きすぎます") }
        }
    }
    /// Validation completes before the SQLite transaction replaces any rows.
    public func restore(_ entries: [Entry]) throws {
        try Self.validateSnapshot(entries)
        try transaction {
            try execute("DELETE FROM learned")
            let statement = try prepare("INSERT INTO learned VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            for (index, entry) in entries.enumerated() {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(entry.reading, to: statement, at: 1)
                try bind(entry.text, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, entry.count)
                sqlite3_bind_int64(statement, 4, Int64(index + 1))
                sqlite3_bind_int64(statement, 5, Int64(entry.reading.utf8.count + entry.text.utf8.count))
                try stepDone(statement)
            }
            try execute("UPDATE learning_state SET sequence=\(entries.count) WHERE id=1")
        }
    }
    public func remove(reading: String, text: String) throws {
        let statement = try prepare("DELETE FROM learned WHERE reading=? AND text=?")
        defer { sqlite3_finalize(statement) }
        try bind(reading, to: statement, at: 1); try bind(text, to: statement, at: 2)
        try stepDone(statement)
    }
    public func clear() throws {
        try transaction { try execute("DELETE FROM learned"); try execute("UPDATE learning_state SET sequence=0 WHERE id=1") }
        // Erase obsolete journal pages as well as logical rows when no other reader holds them.
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public var count: Int { get throws { Int(try scalar("SELECT count(*) FROM learned")) } }
    private func failure() -> PersonalDataError {
        PersonalDataError("学習データ: " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "データベースを開けません"))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.utf8CString.withUnsafeBufferPointer {
            sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
        }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
