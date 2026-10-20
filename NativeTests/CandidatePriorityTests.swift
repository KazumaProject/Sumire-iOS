import XCTest

/// Real bundled generation through the production Swift/C ABI bridge. Expected
/// standalone values are from fixed Android 9506 with its packed provider ON,
/// non-bunsetsu mode, prediction/omission/user/learning OFF, not independent gold.
final class CandidatePriorityTests: XCTestCase {
    private let cases: [(String, Int64)] = [
        ("しろ", 5309), ("ごと", 4560), ("なら", 3800), ("みた", 4806),
        ("したい", 4076), ("なにか", 5792), ("はいる", 5816)
    ]
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64) throws -> ConversionResponse {
        let finished = expectation(description: "Priority conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, includeBunsetsu: true) {
            response = $0; finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        return try XCTUnwrap(response).get()
    }
    func testBundledTableAndProductionBridgePrioritiesAndConsumedRanges() throws {
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("standalone.sud").path))
        for mask: UInt32 in [0, 0x3fff_ffff] {
            let service = ConversionService(categoryMask: mask)
            for (index, entry) in cases.enumerated() {
                let response = try convert(service, entry.0, generation: UInt64(index + 1))
                let candidate = try XCTUnwrap(response.candidates.first)
                XCTAssertEqual(candidate.text, entry.0)
                XCTAssertEqual(candidate.score, entry.1)
                XCTAssertEqual(candidate.range, NSRange(location: 0, length: entry.0.utf16.count))
                XCTAssertEqual(candidate.bunsetsu.map(\.text).joined(), candidate.text)
                XCTAssertTrue(response.complete)
                XCTAssertNil(response.warning)
            }
        }
    }
    func testCategoryOriginsReachSwiftAndLegacyGenerationReportsMissingPriority() throws {
        let all = try convert(ConversionService(categoryMask: 0x3fff_ffff), "とうきょう", generation: 1)
        XCTAssertTrue(all.candidates.contains { $0.text == "Tokyo" && $0.classifiedCategories.contains("place") })
        let source = try XCTUnwrap(ConversionService.bundledDictionary)
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacy) }
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where file.lastPathComponent != "standalone.sud" {
            try FileManager.default.createSymbolicLink(at: legacy.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
        }
        let response = try convert(ConversionService(directory: legacy), "しろ", generation: 1)
        XCTAssertEqual(response.candidates.first?.text, "白")
        XCTAssertTrue(response.warning?.contains("優先候補辞書がありません") == true)
        XCTAssertTrue(response.complete)
    }
}
