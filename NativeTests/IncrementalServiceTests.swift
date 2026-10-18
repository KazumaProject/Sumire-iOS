import XCTest

/// Production Swift/C bridge with the shipped dictionaries. Fresh sessions are
/// the oracle for edit-cache invalidation; this is not a keyboard-rendering test.
final class IncrementalServiceTests: XCTestCase {
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64,
                         omission: Bool, english: Bool) throws -> ConversionResponse {
        let finished = expectation(description: "Incremental service conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, omission: omission,
                        english: english, includeBunsetsu: true) {
            response = $0; finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        return try XCTUnwrap(response).get()
    }

    func testEditedReadingsAndModeChangesMatchFreshSessionsWithAllCategories() throws {
        let edited = ConversionService(categoryMask: 0x3fff_ffff)
        let steps: [(String, Bool, Bool)] = [
            ("にほん", false, false), ("にほんご", false, false), ("にほんごに", false, false),
            ("にほんご", false, false), ("にほんの", false, false),
            ("かつこう", true, false), ("かつこうに", true, false),
            ("かっこうに", false, false), ("😀にほん", false, false),
            ("😁にほん", false, false), ("か\u{3099}", false, false),
            ("iph", false, true), ("ipho", false, true), ("にほんご", false, false)]
        for (index, step) in steps.enumerated() {
            let actual = try convert(edited, step.0, generation: UInt64(index + 1), omission: step.1, english: step.2)
            let fresh = try convert(ConversionService(categoryMask: 0x3fff_ffff), step.0,
                                    generation: UInt64(index + 1), omission: step.1, english: step.2)
            XCTAssertEqual(actual.complete, fresh.complete, step.0)
            XCTAssertEqual(actual.candidates.count, fresh.candidates.count, step.0)
            for (a, b) in zip(actual.candidates, fresh.candidates) {
                XCTAssertEqual(a.id, b.id, step.0)
                XCTAssertEqual(a.text, b.text, step.0)
                XCTAssertEqual(a.score, b.score, step.0)
                XCTAssertEqual(a.range, b.range, step.0)
                XCTAssertEqual(a.dictionaries, b.dictionaries, step.0)
                XCTAssertEqual(a.bunsetsu, b.bunsetsu, step.0)
            }
        }
    }
}
