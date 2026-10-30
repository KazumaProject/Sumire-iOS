import XCTest
import SQLite3
@testable import SumireCore

final class UserDictionaryPredictionTests: XCTestCase {
    private func word(_ reading: String, _ id: Int64?, score: Int = 100) -> PersonalWord {
        var value = PersonalWord(word: "固有表記\(id.map(String.init) ?? "nil")", reading: reading, posScore: score)
        value.id = id; return value
    }
    private func sqlIDs(_ words: [PersonalWord], prefix: String, limit: Int) throws -> [Int64] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE user_word(id INTEGER, reading TEXT, posScore INTEGER)", nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for word in words {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO user_word VALUES(?,?,?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int64(statement, 1, try XCTUnwrap(word.id))
            _ = word.reading.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
            sqlite3_bind_int64(statement, 3, Int64(word.posScore))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE); sqlite3_finalize(statement)
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT id FROM user_word WHERE reading LIKE ? || '%' ORDER BY posScore ASC,LENGTH(reading) ASC,id DESC LIMIT ?", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        _ = prefix.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
        return result
    }
    func testMatchesFixedSQLLikeWildcardsASCIIAndUnicodeScalarLengthOrdering() throws {
        let words = [word("aa😀", 1), word("aaaa", 9), word("aaか", 2), word("aaa", 3),
            word("a", 5), word("ABxy", 6), word("abxx", 7), word("Äab", 8), word("äab", 10),
            word("a\\b", 11), word("😀あ", 12), word("aa高", 13, score: 200)]
        for prefix in ["aa", "a%", "a_", "AB", "Äa", "äa", "a\\", "😀"] {
            for limit in [1, 4, 8] {
                let actual = try UserDictionaryPredictionPolicy.candidates(in: words, reading: prefix,
                    settings: .init(candidateLimit: limit)).map(\.id)
                XCTAssertEqual(actual, try sqlIDs(words, prefix: prefix, limit: limit).map(Optional.some), prefix)
            }
        }
        XCTAssertEqual(try UserDictionaryPredictionPolicy.candidates(in: words, reading: "aa", settings: .init()).map(\.id), [3,2,1,9])
        // LIKE has no implicit ESCAPE: 'a%' can match stored reading 'a',
        // shorter than the two UTF-16 units entered by the user.
        XCTAssertEqual(try UserDictionaryPredictionPolicy.candidates(in: words, reading: "a%", settings: .init()).first?.id, 5)
    }
    func testNilIDsRetainStablePortableOrderWithoutInventingIdentity() throws {
        var first = word("あいう", nil), second = word("あいえ", nil)
        first.word = "先"; second.word = "後"
        let known = word("あいお", 3)
        let result = try UserDictionaryPredictionPolicy.candidates(in: [first,known,second], reading: "あい", settings: .init())
        XCTAssertEqual(result.map(\.word), [known.word, "先", "後"])
        XCTAssertEqual(result.map(\.id), [3,nil,nil])
    }
    func testSettingsDefaultsBoundsThresholdAndPortableBackup() throws {
        let domain = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(UserDictionaryPredictionSettings.load(defaults: defaults), .init())
        let bounded = UserDictionaryPredictionSettings(enabled: false, minimumInputLength: 1, candidateLimit: 99)
        XCTAssertEqual(bounded.minimumInputLength, 2); XCTAssertEqual(bounded.candidateLimit, 8)
        let words = [word("あいう", 1)]
        XCTAssertEqual(try UserDictionaryPredictionPolicy.candidates(in: words, reading: "あ", settings: .init()), [])
        XCTAssertEqual(try UserDictionaryPredictionPolicy.candidates(in: words, reading: "あい", settings: bounded), [])
        XCTAssertThrowsError(try UserDictionaryPredictionPolicy.candidates(in: words, reading: "あ\0", settings: .init()))
        var snapshot = KeyboardSettingsSnapshot()
        snapshot.values = [UserDictionaryPredictionSettings.enabledKey: .boolean(false),
            UserDictionaryPredictionSettings.minimumInputLengthKey: .number(3),
            UserDictionaryPredictionSettings.candidateLimitKey: .number(7)]
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), settings: snapshot)
        XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(contents)), contents)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(UserDictionaryPredictionSettings.load(defaults: defaults), .init(enabled: false, minimumInputLength: 3, candidateLimit: 7))
        snapshot.values[UserDictionaryPredictionSettings.minimumInputLengthKey] = .number(1)
        XCTAssertThrowsError(try snapshot.validate())
    }
}
