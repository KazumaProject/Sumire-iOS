import XCTest
import SQLite3
@testable import SumireCore

final class PersonalDictionarySearchTests: XCTestCase {
    func testExactPrefixMatchesPrecedeLongerPrefixMatchesLikeAndroid() {
        let entries = [
            PersonalWord(word: "東京都", reading: "とうきょうと"),
            PersonalWord(word: "東京", reading: "とうきょう"),
            PersonalWord(word: "とうきょう方面", reading: "とおきょうほうめん"),
            PersonalWord(word: "とうきょう", reading: "と")
        ]

        let results = PersonalDictionarySearch.results(for: entries, query: "とうきょう")

        XCTAssertEqual(results.map(\.sourceIndex), [3, 1, 0, 2])
        XCTAssertEqual(results.map(\.word.word), ["とうきょう", "東京", "東京都", "とうきょう方面"])
    }

    func testSearchTrimsQueryAndMatchesSurfaceOrReadingWithoutCaseSensitivity() {
        let entries = [
            PersonalWord(word: "iPhone SE", reading: "あいふぉーん"),
            PersonalWord(word: "Android", reading: "android"),
            PersonalWord(word: "Pixel", reading: "ぴくせる")
        ]

        XCTAssertEqual(PersonalDictionarySearch.results(for: entries, query: "  IPHONE ").map(\.sourceIndex), [0])
        XCTAssertEqual(PersonalDictionarySearch.results(for: entries, query: "AND").map(\.sourceIndex), [1])
    }

    func testEmptyOrWhitespaceQueryUsesAndroidReadingOrderAndPreservesTies() {
        let entries = [
            PersonalWord(word: "supplementary", reading: "\u{10000}"),
            PersonalWord(word: "later", reading: "とう"),
            PersonalWord(word: "bmp-first", reading: "\u{E000}"),
            PersonalWord(word: "earlier", reading: "あい"),
            PersonalWord(word: "bmp-second", reading: "\u{E000}")
        ]

        let results = PersonalDictionarySearch.results(for: entries, query: "  \n ")

        // SQLite BINARY UTF-8 order puts the BMP private-use scalar before U+10000;
        // ties retain source order as a deterministic fallback.
        XCTAssertEqual(results.map(\.sourceIndex), [3, 1, 2, 4, 0])
        XCTAssertEqual(results.map(\.word.word), ["earlier", "later", "bmp-first", "bmp-second", "supplementary"])
        XCTAssertEqual(results.map(\.word.reading), try sqliteOrderedReadings(entries.map(\.reading)))
    }

    func testNoMatchesReturnsEmptyResults() {
        let entries = [PersonalWord(word: "東京", reading: "とうきょう")]

        XCTAssertTrue(PersonalDictionarySearch.results(for: entries, query: "おおさか").isEmpty)
    }

    private func sqliteOrderedReadings(_ readings: [String]) throws -> [String] {
        var databasePointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &databasePointer), SQLITE_OK)
        let database = try XCTUnwrap(databasePointer)
        defer { sqlite3_close(database) }

        XCTAssertEqual(
            sqlite3_exec(database, "CREATE TABLE user_word (reading TEXT NOT NULL)", nil, nil, nil),
            SQLITE_OK
        )

        var insert: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO user_word (reading) VALUES (?)", -1, &insert, nil),
            SQLITE_OK
        )
        let insertStatement = try XCTUnwrap(insert)
        defer { sqlite3_finalize(insertStatement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for reading in readings {
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)
            let bindStatus = reading.utf8CString.withUnsafeBufferPointer { buffer in
                sqlite3_bind_text(insertStatement, 1, buffer.baseAddress, Int32(buffer.count - 1), transient)
            }
            XCTAssertEqual(bindStatus, SQLITE_OK)
            XCTAssertEqual(sqlite3_step(insertStatement), SQLITE_DONE)
        }

        var query: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "SELECT reading FROM user_word ORDER BY reading ASC", -1, &query, nil),
            SQLITE_OK
        )
        let queryStatement = try XCTUnwrap(query)
        defer { sqlite3_finalize(queryStatement) }

        var ordered: [String] = []
        while true {
            let stepStatus = sqlite3_step(queryStatement)
            if stepStatus == SQLITE_DONE { break }
            XCTAssertEqual(stepStatus, SQLITE_ROW)
            guard stepStatus == SQLITE_ROW,
                  let text = sqlite3_column_text(queryStatement, 0) else {
                throw NSError(domain: "PersonalDictionarySearchTests.SQLite", code: Int(stepStatus))
            }
            let byteCount = Int(sqlite3_column_bytes(queryStatement, 0))
            ordered.append(String(decoding: UnsafeBufferPointer(start: text, count: byteCount), as: UTF8.self))
        }
        return ordered
    }
}
