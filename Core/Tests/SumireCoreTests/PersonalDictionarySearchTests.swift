import XCTest
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
    }

    func testNoMatchesReturnsEmptyResults() {
        let entries = [PersonalWord(word: "東京", reading: "とうきょう")]

        XCTAssertTrue(PersonalDictionarySearch.results(for: entries, query: "おおさか").isEmpty)
    }
}
