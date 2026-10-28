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

    func testEmptyOrWhitespaceQueryPreservesOriginalOrderAndIndexes() {
        let entries = [
            PersonalWord(word: "二番目", reading: "にばんめ"),
            PersonalWord(word: "一番目", reading: "いちばんめ")
        ]

        let results = PersonalDictionarySearch.results(for: entries, query: "  \n ")

        XCTAssertEqual(results.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(results.map(\.word), entries)
    }

    func testNoMatchesReturnsEmptyResults() {
        let entries = [PersonalWord(word: "東京", reading: "とうきょう")]

        XCTAssertTrue(PersonalDictionarySearch.results(for: entries, query: "おおさか").isEmpty)
    }
}
