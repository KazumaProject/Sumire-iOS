import XCTest
@testable import SumireCore
@testable import Sumire

final class NumericEndpointBoundaryTests: XCTestCase {
    func testActualServiceSuperscriptSubscriptCarryKnownEndpointsIntoCommitFragment() throws {
        let service = ConversionService(categoryMask: 0)
        let done = expectation(description: "current production numeric providers")
        var result: Result<ConversionResponse, Error>?
        service.convert("1", generation: 1, editStart: 0) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let response = try XCTUnwrap(result).get()
        for text in ["¹", "₁"] {
            let rank = try XCTUnwrap(response.candidates.indices.first { response.candidates[$0].text == text })
            let selected = response.candidates[rank]
            XCTAssertEqual(selected.leftID, Int16(2040), text + " actual Service left endpoint")
            XCTAssertEqual(selected.rightID, Int16(2040), text + " actual Service right endpoint")
            let range = try XCTUnwrap(Range(selected.range, in: "1"))
            // Identical DTO initializer/data mapping to enqueueCommit in
            // production ConversionService; no commit/persistence-policy bypass.
            let fragment = LearningFragment(reading: String("1"[range]), output: selected.text,
                candidateScore: Int32(clamping: selected.score), candidateIndex: Int32(clamping: rank),
                leftID: selected.leftID, rightID: selected.rightID)
            XCTAssertEqual(fragment.leftID, Int16(2040), text + " commit DTO left endpoint")
            XCTAssertEqual(fragment.rightID, Int16(2040), text + " commit DTO right endpoint")
        }
    }
    private func convert(_ service: ConversionService, reading: String, generation: UInt64,
                         includeBunsetsu: Bool = false) throws -> ConversionResponse {
        let done = expectation(description: "numeric endpoint bridge")
        var result: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, includeBunsetsu: includeBunsetsu) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
    func testKnownNumericAndTemporalEndpointsReachRealCommitWhileOldNilRowStaysNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: url)
        try store.upsertLearningEntries([.init(input: "べつ", output: "旧行", score: 100,
            leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false)])
        let original = try XCTUnwrap(store.snapshot().first)
        let service = ConversionService(categoryMask: 0)
        service.setLearning(url: url)
        defer {
            service.setLearning(url: nil)
            _ = try? convert(service, reading: "あ", generation: 99)
        }
        for (index, fixture) in [("1", "一", Int16(2040)), ("0101", "01時01分", Int16(1851)), ("0101", "1月1日", Int16(1851))].enumerated() {
            let generation = UInt64(10 + index * 2)
            let response = try convert(service, reading: fixture.0, generation: generation)
            let rank = try XCTUnwrap(response.candidates.indices.first { response.candidates[$0].text == fixture.1 })
            let candidate = response.candidates[rank]
            XCTAssertEqual(candidate.leftID, fixture.2); XCTAssertEqual(candidate.rightID, fixture.2)
            service.commitSelection(generation: generation, candidate: candidate, rank: rank,
                input: fixture.0, remaining: "", learnFirst: true) { _ in }
            _ = try convert(service, reading: "あ", generation: generation + 1)
            let saved = try XCTUnwrap(store.snapshot().first { $0.reading == fixture.0 && $0.text == fixture.1 })
            XCTAssertEqual(saved.leftID, fixture.2); XCTAssertEqual(saved.rightID, fixture.2)
        }
        XCTAssertEqual(try store.snapshot().first { $0.reading == "べつ" }, original)
        XCTAssertNil(original.leftID); XCTAssertNil(original.rightID)
    }
    func testGeneratedEndpointsRemainOwnedInSnapshotAfterReplacementAndServiceRelease() throws {
        var service: ConversionService? = ConversionService(categoryMask: 0)
        let response = try convert(service!, reading: "1", generation: 30, includeBunsetsu: true)
        let snapshot = try XCTUnwrap(response.bunsetsuSnapshot)
        _ = try convert(service!, reading: "2", generation: 31)
        service = nil
        let selected = try XCTUnwrap(snapshot.candidates.first { $0.identity.surface == "¹" })
        XCTAssertEqual(selected.identity.readingUTF16Length, 1)
        XCTAssertNil(selected.tokenPath, "Known endpoints must not invent a dictionary path")
        XCTAssertEqual(selected.leftID, 2040); XCTAssertEqual(selected.rightID, 2040)
        // Keep the existing unsplit-first-candidate contract; display order does
        // not replace native candidate zero with this utility candidate.
        let first = try snapshot.projectedSplitPatterns(reading: "1", requestGeneration: 30,
            orderedDisplayCandidates: [.init(surface: "¹", readingUTF16Length: 1)])
        XCTAssertEqual(first.first?.segments.first?.text, "1")

    }

}
