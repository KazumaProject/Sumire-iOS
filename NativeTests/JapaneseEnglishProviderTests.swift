import XCTest
import SumireCore

final class JapaneseEnglishProviderTests: XCTestCase {
    func testLoadQualifierMatchesPinnedOrdinaryJapaneseRoutes() {
        for input in ["a", "Ab", "ABC", "ａｂ", "ＡＢ", "＋", "　", "ａ＋ｂ"] {
            XCTAssertTrue(NativeDictionaryEngineOpener.requiresJapaneseEnglishWords(input), input)
        }
        for input in ["", "a1", "a+b", "a b", "あ", "é", "aあ", "123", "１２３", "😀"] {
            XCTAssertFalse(NativeDictionaryEngineOpener.requiresJapaneseEnglishWords(input), input)
        }
    }

    func testRealEnglishProviderReachesOrdinaryJapaneseWithoutDuplicatingPersonal() throws {
        let service = ConversionService(categoryMask: 0)
        let normal = try convert(service, "ab", generation: 1)
        let wide = try convert(service, "ａｂ", generation: 2)
        func provider(_ response: ConversionResponse) -> [ConversionCandidate] {
            response.candidates.filter { $0.dictionaries.contains("english") }
        }
        let english = provider(normal), fullWidth = provider(wide)
        XCTAssertFalse(english.isEmpty)
        // The final display merger can keep an earlier Japanese candidate's
        // score/ID, so raw provider equality is checked by the separate CLI fixture.
        XCTAssertEqual(Set(english.map(\.text)), Set(fullWidth.map(\.text)))
        XCTAssertTrue(english.allSatisfy { $0.range == NSRange(location: 0, length: 2) })
        XCTAssertTrue(fullWidth.allSatisfy { $0.range == NSRange(location: 0, length: 2) })
        XCTAssertTrue(normal.complete); XCTAssertTrue(wide.complete)
        let mixed = try convert(service, "a1", generation: 3)
        XCTAssertFalse(mixed.candidates.contains { $0.dictionaries.contains("english") })
        var personal = PersonalLexicon()
        personal.words = [PersonalWord(word: "UniquePersonal", reading: "ab", posScore: -10000)]
        service.setPersonal(personal)
        let custom = try convert(service, "ab", generation: 4)
        XCTAssertEqual(custom.candidates.filter { $0.text == "UniquePersonal" }.count, 1)
    }

    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64) throws -> ConversionResponse {
        let completed = expectation(description: "Japanese real English dictionary")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0) { response = $0; completed.fulfill() }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(response).get()
    }
}
