import XCTest
import SumireCore

/// Real bundled dictionaries through the production Swift/C ABI bridge.
/// This tests owned metadata, not keyboard rendering or host marked text.
final class BunsetsuServiceTests: XCTestCase {
    private func convert(_ service: ConversionService, _ reading: String,
                         generation: UInt64, english: Bool = false) throws -> ConversionResponse {
        let completed = expectation(description: "Bunsetsu conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: english) {
            response = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(response).get()
    }

    func testWholeCandidatePathRemainsOwnedAfterSnapshotAndSessionRelease() throws {
        var service: ConversionService? = ConversionService()
        let response = try convert(service!, "きょうはとうきょうにいきます", generation: 1)
        let candidate = try XCTUnwrap(response.candidates.first { $0.text == "今日は東京に行きます" })
        _ = try convert(service!, "あした", generation: 2)
        service = nil
        XCTAssertEqual(candidate.bunsetsu.map(\.text), ["今日は", "東京に", "行きます"])
        XCTAssertEqual(candidate.bunsetsu.map(\.reading), ["きょうは", "とうきょうに", "いきます"])
        XCTAssertEqual(candidate.bunsetsu.map(\.readingRange), [
            NSRange(location: 0, length: 4), NSRange(location: 4, length: 6), NSRange(location: 10, length: 4)])
        for value in response.candidates {
            XCTAssertEqual(value.bunsetsu.map(\.text).joined(), value.text)
            XCTAssertEqual(value.bunsetsu.reduce(0) { $0 + $1.readingRange.length }, value.range.length)
        }
    }

    func testPartialCandidateProjectsOnlyConsumedPrefix() throws {
        let response = try convert(ConversionService(), "とうきょうに", generation: 1)
        let prefix = try XCTUnwrap(response.candidates.first { $0.text == "東京" && $0.range.length == 5 })
        XCTAssertEqual(prefix.bunsetsu.map(\.text), ["東京"])
        XCTAssertEqual(prefix.bunsetsu.map(\.reading), ["とうきょう"])
        XCTAssertEqual(prefix.bunsetsu.first?.readingRange, NSRange(location: 0, length: 5))
    }

    func testEnglishCompletionIsOneSegmentConsumingTypedInput() throws {
        let response = try convert(ConversionService(), "iph", generation: 1, english: true)
        let candidate = try XCTUnwrap(response.candidates.first { $0.text == "iPhone" })
        XCTAssertEqual(candidate.bunsetsu.map(\.text), ["iPhone"])
        XCTAssertEqual(candidate.bunsetsu.map(\.reading), ["iph"])
        XCTAssertEqual(candidate.bunsetsu.first?.readingRange, NSRange(location: 0, length: 3))
    }

    func testSupplementaryUnicodeUsesUTF16Ranges() throws {
        let response = try convert(ConversionService(), "😀", generation: 1)
        let candidate = try XCTUnwrap(response.candidates.first { $0.text == "😀" })
        XCTAssertEqual(candidate.bunsetsu.map(\.reading), ["😀"])
        XCTAssertEqual(candidate.bunsetsu.first?.readingRange, NSRange(location: 0, length: 2))
    }
}
