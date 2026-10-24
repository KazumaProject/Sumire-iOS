import Foundation
import SQLite3

/// Synchronous SQLite storage; call from the conversion queue, not the UI thread.
/// No input is stored unless the caller explicitly records a committed candidate.
public final class LearningStore {
    public static let maximumEntryCount = 10_000
    public static let maximumTextBytes = 16 * 1024 * 1024

    public struct Entry: Codable, Equatable {
        public let reading: String
        public let text: String
        public let count: Int64
        public let score: Int32
        public let leftID: Int16?
        public let rightID: Int16?
        public let usageCount: Int32
        public let lastUsedAt: Int64
        public let isPhrase: Bool

        public init(
            reading: String,
            text: String,
            count: Int64,
            score: Int32 = 3_000,
            leftID: Int16? = nil,
            rightID: Int16? = nil,
            usageCount: Int32? = nil,
            lastUsedAt: Int64 = 0,
            isPhrase: Bool = false
        ) {
            self.reading = reading
            self.text = text
            self.count = count
            self.score = score
            self.leftID = leftID
            self.rightID = rightID
            self.usageCount = usageCount ?? Int32(clamping: count)
            self.lastUsedAt = lastUsedAt
            self.isPhrase = isPhrase
        }

        private enum CodingKeys: String, CodingKey {
            case reading, text, count, score, leftID, rightID, usageCount, lastUsedAt, isPhrase
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let count = try values.decode(Int64.self, forKey: .count)
            self.init(
                reading: try values.decode(String.self, forKey: .reading),
                text: try values.decode(String.self, forKey: .text),
                count: count,
                score: try values.decodeIfPresent(Int32.self, forKey: .score) ?? 3_000,
                leftID: try values.decodeIfPresent(Int16.self, forKey: .leftID),
                rightID: try values.decodeIfPresent(Int16.self, forKey: .rightID),
                usageCount: try values.decodeIfPresent(Int32.self, forKey: .usageCount) ?? Int32(clamping: count),
                lastUsedAt: try values.decodeIfPresent(Int64.self, forKey: .lastUsedAt) ?? 0,
                isPhrase: try values.decodeIfPresent(Bool.self, forKey: .isPhrase) ?? false
            )
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(reading, forKey: .reading)
            try values.encode(text, forKey: .text)
            try values.encode(count, forKey: .count)
            try values.encode(score, forKey: .score)
            try values.encodeIfPresent(leftID, forKey: .leftID)
            try values.encodeIfPresent(rightID, forKey: .rightID)
            try values.encode(usageCount, forKey: .usageCount)
            try values.encode(lastUsedAt, forKey: .lastUsedAt)
            try values.encode(isPhrase, forKey: .isPhrase)
        }
    }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var conversionBuckets: [UInt32: [Entry]] = [:]
    private var conversionDataVersion: Int64?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 250)
            try execute("PRAGMA cache_size=-1024")
            let version = try scalar("PRAGMA user_version")
            guard (0...2).contains(version) else { throw PersonalDataError("未対応の学習データ形式です") }
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
                if version < 2 {
                    try execute("ALTER TABLE learned ADD COLUMN score INTEGER NOT NULL DEFAULT 3000")
                    try execute("ALTER TABLE learned ADD COLUMN left_id INTEGER")
                    try execute("ALTER TABLE learned ADD COLUMN right_id INTEGER")
                    try execute("ALTER TABLE learned ADD COLUMN usage_count INTEGER NOT NULL DEFAULT 1")
                    try execute("ALTER TABLE learned ADD COLUMN last_used_at INTEGER NOT NULL DEFAULT 0")
                    try execute("ALTER TABLE learned ADD COLUMN is_phrase INTEGER NOT NULL DEFAULT 0")
                    try execute("UPDATE learned SET usage_count=frequency")
                }
                try execute("PRAGMA user_version=2")
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    public func record(reading: String, text: String) throws {
        let word = PersonalWord(word: text, reading: reading)
        try word.validate()
        try transaction {
            try execute("UPDATE learning_state SET sequence=sequence+1 WHERE id=1")
            let statement = try prepare("INSERT INTO learned(reading,text,frequency,last_used,byte_count,score,left_id,right_id,usage_count,last_used_at,is_phrase) VALUES(?,?,1,(SELECT sequence FROM learning_state WHERE id=1),?,3000,NULL,NULL,1,0,0) ON CONFLICT(reading,text) DO UPDATE SET frequency=min(learned.frequency+1,1000000),last_used=excluded.last_used,usage_count=min(learned.usage_count+1,2147483647)")
            defer { sqlite3_finalize(statement) }
            try bind(reading, to: statement, at: 1); try bind(text, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(reading.utf8.count + text.utf8.count))
            try stepDone(statement)
            try pruneToBudgets()
        }
        invalidateConversionBuckets()
    }

    /// Stores a completed Android-compatible fragment/phrase batch atomically.
    /// Existing records use the same score reinforcement and metadata merge as LearnDao.
    public func upsertLearningEntries(
        _ entries: [LearningSessionEntry],
        allowJapaneseWithSymbolsAndNumbers: Bool = true
    ) throws {
        let eligibleEntries = entries.filter {
            LearningEligibilityPolicy.isEligible(
                input: $0.input,
                output: $0.output,
                allowJapaneseWithSymbolsAndNumbers: allowJapaneseWithSymbolsAndNumbers
            )
        }
        guard eligibleEntries.count <= 100_000 else { throw PersonalDataError("学習データが多すぎます") }
        var validatedEntries: [LearningSessionEntry] = []
        var bytes = 0
        for entry in eligibleEntries {
            try PersonalWord(word: entry.output, reading: entry.input).validate()
            guard entry.usageCount > 0 else { throw PersonalDataError("学習データの使用回数が不正です") }
            bytes += entry.input.utf8.count + entry.output.utf8.count
            guard bytes <= Self.maximumTextBytes else { throw PersonalDataError("学習データが大きすぎます") }
            validatedEntries.append(entry)
        }
        guard !validatedEntries.isEmpty else { return }

        try transaction {
            let statement = try prepare("INSERT INTO learned(reading,text,frequency,last_used,byte_count,score,left_id,right_id,usage_count,last_used_at,is_phrase) VALUES(?,?,min(?,1000000),(SELECT sequence FROM learning_state WHERE id=1),?,?,?, ?,?,?,?) ON CONFLICT(reading,text) DO UPDATE SET frequency=min(learned.frequency+excluded.frequency,1000000),last_used=excluded.last_used,score=max(0,min(learned.score,excluded.score)-1500),left_id=coalesce(excluded.left_id,learned.left_id),right_id=coalesce(excluded.right_id,learned.right_id),usage_count=min(learned.usage_count+excluded.usage_count,2147483647),last_used_at=max(learned.last_used_at,excluded.last_used_at),is_phrase=max(learned.is_phrase,excluded.is_phrase)")
            defer { sqlite3_finalize(statement) }
            // LearnDao processes each incoming entity in order. The conversion
            // session has already removed duplicate (input, output) pairs, but
            // keeping this storage API sequential also preserves DAO behavior
            // for callers that intentionally submit duplicate rows.
            for entry in validatedEntries {
                try execute("UPDATE learning_state SET sequence=sequence+1 WHERE id=1")
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(entry.input, to: statement, at: 1)
                try bind(entry.output, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, Int64(entry.usageCount))
                sqlite3_bind_int64(statement, 4, Int64(entry.input.utf8.count + entry.output.utf8.count))
                sqlite3_bind_int(statement, 5, entry.score)
                try bind(entry.leftID, to: statement, at: 6)
                try bind(entry.rightID, to: statement, at: 7)
                sqlite3_bind_int(statement, 8, entry.usageCount)
                sqlite3_bind_int64(statement, 9, entry.lastUsedAt)
                sqlite3_bind_int(statement, 10, entry.isPhrase ? 1 : 0)
                try stepDone(statement)
            }
            try pruneToBudgets()
        }
        invalidateConversionBuckets()
    }
    /// Returns the best-scored reading-prefix rows before the native overlay's
    /// 100-entry limit is applied. Frequency and recency must not evict a
    /// lower-cost learned row before the engine can compare it.
    public func candidates(reading: String, limit: Int = 100) throws -> [Entry] {
        guard (1...100).contains(limit), !reading.contains("\0") else { throw PersonalDataError("学習検索条件が不正です") }
        guard !reading.isEmpty else { return [] }
        let statement = try prepare("SELECT reading,text,frequency,score,left_id,right_id,usage_count,last_used_at,is_phrase,last_used FROM learned WHERE reading=? ORDER BY score ASC,frequency DESC,last_used DESC")
        defer { sqlite3_finalize(statement) }
        var prefixes = String.UnicodeScalarView()
        var rows: [(entry: Entry, sequence: Int64)] = []
        func string(_ column: Int32) throws -> String {
            guard let bytes = sqlite3_column_text(statement, column),
                  let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
                throw PersonalDataError("学習データの文字コードが不正です")
            }
            return value
        }
        for scalar in reading.unicodeScalars {
            prefixes.append(scalar)
            let prefix = String(prefixes)
            guard sqlite3_reset(statement) == SQLITE_OK,
                  sqlite3_clear_bindings(statement) == SQLITE_OK else { throw failure() }
            try bind(prefix, to: statement, at: 1)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                let storedReading = try string(0)
                let text = try string(1)
                try PersonalWord(word: text, reading: storedReading).validate()
                let entry = try decodeEntry(reading: storedReading, text: text, statement: statement,
                                            countColumn: 2, metadataColumn: 3)
                rows.append((entry, sqlite3_column_int64(statement, 9)))
            }
        }
        rows.sort { lhs, rhs in
            if lhs.entry.score != rhs.entry.score { return lhs.entry.score < rhs.entry.score }
            let lhsLength = lhs.entry.reading.utf16.count, rhsLength = rhs.entry.reading.utf16.count
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            if lhs.entry.count != rhs.entry.count { return lhs.entry.count > rhs.entry.count }
            if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
            if !lhs.entry.reading.utf8.elementsEqual(rhs.entry.reading.utf8) {
                return lhs.entry.reading.utf8.lexicographicallyPrecedes(rhs.entry.reading.utf8)
            }
            return lhs.entry.text.utf8.lexicographicallyPrecedes(rhs.entry.text.utf8)
        }
        return rows.prefix(limit).map(\.entry)
    }
    /// Loads the Android conversion buckets for the distinct first scalars in
    /// the current reading. The native lattice matches each row against every
    /// remaining-input position, as Android's GraphBuilder does.
    public func entriesForConversion(reading: String) throws -> [Entry] {
        guard !reading.contains("\0") else { throw PersonalDataError("学習検索条件が不正です") }
        guard !reading.isEmpty else { return [] }

        let dataVersion = try scalar("PRAGMA data_version")
        if conversionDataVersion != dataVersion {
            conversionBuckets.removeAll(keepingCapacity: false)
            conversionDataVersion = dataVersion
        }
        let firstScalars = Set(reading.unicodeScalars.map(\.value)).sorted()
        let activeScalars = Set(firstScalars)
        conversionBuckets = conversionBuckets.filter { activeScalars.contains($0.key) }
        let missingScalars = firstScalars.filter { conversionBuckets[$0] == nil }

        if !missingScalars.isEmpty {
            let select = "SELECT reading,text,frequency,score,left_id,right_id,usage_count,last_used_at,is_phrase,last_used FROM learned WHERE reading>=?"
            let bounded = try prepare(select + " AND reading<? ORDER BY length(reading) DESC,reading ASC,text ASC")
            defer { sqlite3_finalize(bounded) }
            let unbounded = try prepare(select + " ORDER BY length(reading) DESC,reading ASC,text ASC")
            defer { sqlite3_finalize(unbounded) }

            func string(_ column: Int32, from statement: OpaquePointer) throws -> String {
                guard let bytes = sqlite3_column_text(statement, column),
                      let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
                    throw PersonalDataError("学習データの文字コードが不正です")
                }
                return value
            }

            for scalarValue in missingScalars {
                guard let scalar = Unicode.Scalar(scalarValue) else { throw PersonalDataError("学習検索条件が不正です") }
                let prefix = String(scalar)
                let upperBound = Self.nextUnicodeScalar(after: scalar).map(String.init)
                let statement = upperBound == nil ? unbounded : bounded
                guard sqlite3_reset(statement) == SQLITE_OK,
                      sqlite3_clear_bindings(statement) == SQLITE_OK else { throw failure() }
                try bind(prefix, to: statement, at: 1)
                if let upperBound { try bind(upperBound, to: statement, at: 2) }

                var bucket: [Entry] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw failure() }
                    let storedReading = try string(0, from: statement)
                    let text = try string(1, from: statement)
                    try PersonalWord(word: text, reading: storedReading).validate()
                    bucket.append(try decodeEntry(reading: storedReading, text: text, statement: statement,
                                                  countColumn: 2, metadataColumn: 3))
                    guard bucket.count <= Self.maximumEntryCount else {
                        throw PersonalDataError("学習データが多すぎます")
                    }
                }
                conversionBuckets[scalarValue] = bucket
            }
        }

        let entries = firstScalars.flatMap { conversionBuckets[$0] ?? [] }
        let totalBytes = entries.reduce(0) { $0 + $1.reading.utf8.count + $1.text.utf8.count }
        guard entries.count <= Self.maximumEntryCount, totalBytes <= Self.maximumTextBytes else {
            throw PersonalDataError("学習データが大きすぎます")
        }
        return entries
    }

    private static func nextUnicodeScalar(after scalar: Unicode.Scalar) -> Unicode.Scalar? {
        var value = scalar.value + 1
        if value == 0xD800 { value = 0xE000 }
        return Unicode.Scalar(value)
    }

    /// Smallest scalar-string bound greater than every string beginning with
    /// `prefix`, using SQLite's binary UTF-8 ordering. If the final scalar is
    /// maximal, carry into the preceding scalar; all-maximal prefixes are
    /// safely queried with only a lower bound.
    private static func prefixUpperBound(_ prefix: String) -> String? {
        let scalars = Array(prefix.unicodeScalars)
        for index in scalars.indices.reversed() {
            guard let incremented = nextUnicodeScalar(after: scalars[index]) else { continue }
            var result = String.UnicodeScalarView(scalars[..<index])
            result.append(incremented)
            return String(result)
        }
        return nil
    }

    /// Entries are oldest first, retaining recency for equal-frequency candidates.
    public func snapshot() throws -> [Entry] {
        let statement = try prepare("SELECT reading,text,frequency,score,left_id,right_id,usage_count,last_used_at,is_phrase FROM learned ORDER BY last_used ASC,rowid ASC")
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        var totalBytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            totalBytes += Int(sqlite3_column_bytes(statement, 0)) + Int(sqlite3_column_bytes(statement, 1))
            guard totalBytes <= Self.maximumTextBytes else { throw PersonalDataError("学習データが大きすぎます") }
            func string(_ column: Int32) throws -> String {
                guard let bytes = sqlite3_column_text(statement, column),
                      let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
                    throw PersonalDataError("学習データの文字コードが不正です")
                }
                return value
            }
            entries.append(try decodeEntry(reading: string(0), text: string(1), statement: statement, countColumn: 2, metadataColumn: 3))
            guard entries.count <= Self.maximumEntryCount else { throw PersonalDataError("学習データが多すぎます") }
        }
        try Self.validateSnapshot(entries)
        return entries
    }
    public static func validateSnapshot(_ entries: [Entry]) throws {
        guard entries.count <= maximumEntryCount else { throw PersonalDataError("学習データが多すぎます") }
        var keys = Set<Data>(), bytes = 0
        for entry in entries {
            try PersonalWord(word: entry.text, reading: entry.reading).validate()
            guard (1...1000000).contains(entry.count),
                  (1...Int32.max).contains(entry.usageCount),
                  keys.insert(binaryKey(reading: entry.reading, text: entry.text)).inserted else {
                throw PersonalDataError("学習データの頻度または重複が不正です")
            }
            bytes += entry.reading.utf8.count + entry.text.utf8.count
            guard bytes <= maximumTextBytes else { throw PersonalDataError("学習データが大きすぎます") }
        }
    }
    /// Matches Android's learned-dictionary autocomplete query. The limit is
    /// applied after exact-reading priority, score, recency, reading length,
    /// and insertion order have been considered. The caller may then perform
    /// Android's stable score-only ordering without losing the selected set.
    public func predictiveCandidates(readingPrefix: String, limit: Int = 4) throws -> [Entry] {
        guard (1...8).contains(limit), !readingPrefix.contains("\0") else {
            throw PersonalDataError("学習検索条件が不正です")
        }
        guard !readingPrefix.isEmpty else { return [] }

        let select = "SELECT reading,text,frequency,score,left_id,right_id,usage_count,last_used_at,is_phrase,last_used FROM learned WHERE reading>=?"
        let bounded = try prepare(select + " AND reading<? ORDER BY CASE WHEN reading=? THEN 0 ELSE 1 END,score ASC,last_used_at DESC,length(reading) ASC,rowid DESC LIMIT ?")
        defer { sqlite3_finalize(bounded) }
        let unbounded = try prepare(select + " ORDER BY CASE WHEN reading=? THEN 0 ELSE 1 END,score ASC,last_used_at DESC,length(reading) ASC,rowid DESC LIMIT ?")
        defer { sqlite3_finalize(unbounded) }

        let upperBound = Self.prefixUpperBound(readingPrefix)
        let statement = upperBound == nil ? unbounded : bounded
        try bind(readingPrefix, to: statement, at: 1)
        var exactParameter: Int32 = 2
        if let upperBound {
            try bind(upperBound, to: statement, at: 2)
            exactParameter = 3
        }
        try bind(readingPrefix, to: statement, at: exactParameter)
        sqlite3_bind_int(statement, exactParameter + 1, Int32(limit))
        defer { sqlite3_reset(statement) }

        var entries: [Entry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return entries }
            guard status == SQLITE_ROW,
                  let readingBytes = sqlite3_column_text(statement, 0),
                  let textBytes = sqlite3_column_text(statement, 1),
                  let reading = String(bytes: UnsafeBufferPointer(start: readingBytes, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8),
                  let text = String(bytes: UnsafeBufferPointer(start: textBytes, count: Int(sqlite3_column_bytes(statement, 1))), encoding: .utf8) else {
                throw failure()
            }
            try PersonalWord(word: text, reading: reading).validate()
            entries.append(try decodeEntry(reading: reading, text: text, statement: statement,
                                           countColumn: 2, metadataColumn: 3))
        }
    }
    /// Validation completes before the SQLite transaction replaces any rows.
    public func restore(_ entries: [Entry]) throws {
        try Self.validateSnapshot(entries)
        try transaction {
            try execute("DELETE FROM learned")
            let statement = try prepare("INSERT INTO learned(reading,text,frequency,last_used,byte_count,score,left_id,right_id,usage_count,last_used_at,is_phrase) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            for (index, entry) in entries.enumerated() {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(entry.reading, to: statement, at: 1)
                try bind(entry.text, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, entry.count)
                sqlite3_bind_int64(statement, 4, Int64(index + 1))
                sqlite3_bind_int64(statement, 5, Int64(entry.reading.utf8.count + entry.text.utf8.count))
                sqlite3_bind_int(statement, 6, entry.score)
                try bind(entry.leftID, to: statement, at: 7)
                try bind(entry.rightID, to: statement, at: 8)
                sqlite3_bind_int(statement, 9, entry.usageCount)
                sqlite3_bind_int64(statement, 10, entry.lastUsedAt)
                sqlite3_bind_int(statement, 11, entry.isPhrase ? 1 : 0)
                try stepDone(statement)
            }
            try execute("UPDATE learning_state SET sequence=\(entries.count) WHERE id=1")
        }
        invalidateConversionBuckets()
    }
    public func remove(reading: String, text: String) throws {
        let statement = try prepare("DELETE FROM learned WHERE reading=? AND text=?")
        defer { sqlite3_finalize(statement) }
        try bind(reading, to: statement, at: 1); try bind(text, to: statement, at: 2)
        try stepDone(statement)
        invalidateConversionBuckets()
    }
    public func clear() throws {
        try transaction { try execute("DELETE FROM learned"); try execute("UPDATE learning_state SET sequence=0 WHERE id=1") }
        invalidateConversionBuckets()
        // Erase obsolete journal pages as well as logical rows when no other reader holds them.
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public var count: Int { get throws { Int(try scalar("SELECT count(*) FROM learned")) } }
    private func invalidateConversionBuckets() {
        conversionBuckets.removeAll(keepingCapacity: false)
        conversionDataVersion = nil
    }
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
    private func bind(_ value: Int16?, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.map { sqlite3_bind_int(statement, index, Int32($0)) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw failure() }
    }
    private func decodeEntry(reading: String, text: String, statement: OpaquePointer, countColumn: Int32, metadataColumn: Int32) throws -> Entry {
        let count = sqlite3_column_int64(statement, countColumn)
        let rawScore = sqlite3_column_int64(statement, metadataColumn)
        let rawUsageCount = sqlite3_column_int64(statement, metadataColumn + 3)
        let rawLastUsedAt = sqlite3_column_int64(statement, metadataColumn + 4)
        let rawPhrase = sqlite3_column_int64(statement, metadataColumn + 5)
        guard (1...1_000_000).contains(count),
              let score = Int32(exactly: rawScore),
              let usageCount = Int32(exactly: rawUsageCount), usageCount > 0,
              rawPhrase == 0 || rawPhrase == 1 else {
            throw PersonalDataError("学習データの頻度またはメタデータが不正です")
        }
        func optionalID(_ column: Int32) throws -> Int16? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let value = sqlite3_column_int64(statement, column)
            guard let id = Int16(exactly: value) else { throw PersonalDataError("学習データの接続IDが不正です") }
            return id
        }
        return Entry(
            reading: reading,
            text: text,
            count: count,
            score: score,
            leftID: try optionalID(metadataColumn + 1),
            rightID: try optionalID(metadataColumn + 2),
            usageCount: usageCount,
            lastUsedAt: rawLastUsedAt,
            isPhrase: rawPhrase == 1
        )
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
    private func pruneToBudgets() throws {
        try execute("DELETE FROM learned WHERE rowid IN (SELECT rid FROM (SELECT rowid AS rid,row_number() OVER(ORDER BY last_used DESC) AS position,sum(byte_count) OVER(ORDER BY last_used DESC) AS bytes FROM learned) WHERE position>\(Self.maximumEntryCount) OR bytes>\(Self.maximumTextBytes))")
    }
    private static func binaryKey(reading: String, text: String) -> Data {
        var key = Data()
        var readingByteCount = UInt64(reading.utf8.count).bigEndian
        withUnsafeBytes(of: &readingByteCount) { key.append(contentsOf: $0) }
        key.append(contentsOf: reading.utf8)
        key.append(contentsOf: text.utf8)
        return key
    }
}
