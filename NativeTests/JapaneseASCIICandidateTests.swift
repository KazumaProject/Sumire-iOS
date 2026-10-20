import XCTest

/// Production Swift/C ABI service projection; this does not exercise physical
/// keyboard touches or the independent flag-2 English dictionary route.
final class JapaneseASCIICandidateTests: XCTestCase {
    func testGeneratedWidthCandidatesHaveFullTypedRangeBadgeAndDisplayDeduplication() throws {
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        for omission in [false, true] {
            let service = ConversionService(directory: directory)
            var generation: UInt64 = 0
            for (reading, expected) in [("a1", ["ａ１", "Ａ１"]), ("Ab", ["ａｂ", "ＡＢ"]),
                                        ("+", ["＋"]), ("a b", ["ａ　ｂ", "Ａ　Ｂ"]), (" ", ["　"])] {
                generation += 1
                let result = try convert(service, reading, generation: generation, omission: omission)
                let generated = result.candidates.filter { $0.score == 30000 && $0.presentationKind == .fullWidth }
                XCTAssertEqual(generated.map(\.text), expected)
                for candidate in generated {
                    XCTAssertEqual(candidate.range, NSRange(location: 0, length: reading.utf16.count))
                    XCTAssertEqual(candidate.displayAnnotation, "[全]")
                    XCTAssertFalse(candidate.isReadingPrefix)
                }
                XCTAssertTrue(result.complete); XCTAssertNil(result.warning)
            }
        }
    }
    func testNumericNonASCIIAndEnglishRoutesDoNotAcquireJapaneseWidthAppender() throws {
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        let service = ConversionService(directory: directory)
        for (index, reading) in ["あ", "aあ", "é", "ＡＢ", "123", "１２３"].enumerated() {
            let result = try convert(service, reading, generation: UInt64(index + 1))
            XCTAssertFalse(result.candidates.contains { $0.score == 30000 && $0.presentationKind == .fullWidth }, reading)
        }
        let result = try convert(service, "ab", generation: 7, english: true)
        XCTAssertFalse(result.candidates.contains { $0.presentationKind == .fullWidth })
    }
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64,
                         omission: Bool = false, english: Bool = false) throws -> ConversionResponse {
        let completed = expectation(description: "ASCII production conversion")
        var value: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, omission: omission, english: english) {
            value = $0; completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(value).get()
    }
}
