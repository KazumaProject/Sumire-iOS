import XCTest
import SumireCore

/// Exercises the production ConversionService → C API → SQLite path with the
/// bundled dictionary. This does not cover keyboard UI gestures or App Groups.
final class ConversionLearningIntegrationTests: XCTestCase {
    private func convert(_ service: ConversionService, reading: String, generation: UInt64) throws -> ConversionResponse {
        let completed = expectation(description: "Japanese conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, includeBunsetsu: true) {
            response = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(response).get()
    }

    func testCommittedNonFirstCandidatePersistsAndroidScoreAndAppearsInNextConversion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let service = ConversionService()
        service.setLearning(url: database)

        let reading = "しろ"
        let first = try convert(service, reading: reading, generation: 1)
        let selected = try XCTUnwrap(first.candidates.enumerated().first {
            $0.offset > 0 && $0.element.range == NSRange(location: 0, length: reading.utf16.count)
        })
        let stored = expectation(description: "Committed candidate persisted")
        service.commit(generation: first.generation, candidate: selected.element.id,
                       candidateIndex: selected.offset, learningAllowed: true,
                       learnFirstCandidate: false) { message in
            XCTAssertEqual(message, "学習しました")
            stored.fulfill()
        }
        wait(for: [stored], timeout: 10)

        let entry = try XCTUnwrap(LearningStore(url: database).candidates(reading: reading)
            .first { $0.text == selected.element.text })
        XCTAssertEqual(entry.score, LearningScorePolicy.initial(
            candidateScore: Int32(clamping: selected.element.score),
            candidateIndex: Int32(clamping: selected.offset)
        ))
        XCTAssertEqual(entry.count, 1)
        XCTAssertEqual(entry.usageCount, 1)

        let next = try convert(service, reading: reading, generation: 2)
        XCTAssertTrue(next.candidates.contains {
            $0.text == selected.element.text && $0.dictionaries.contains("learning")
        })
    }

    func testLearnedReadingPrefixCanParticipateAsSegmentInLongerConversion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: database)
        try store.upsertLearningEntries([
            .init(input: "し", output: "詩", score: 1_000, leftID: nil, rightID: nil,
                  lastUsedAt: 1, isPhrase: false)
        ])

        let service = ConversionService()
        service.setLearning(url: database)
        let reading = "しろ"
        let response = try convert(service, reading: reading, generation: 1)

        XCTAssertTrue(response.candidates.contains {
            $0.text == "詩ろ" && $0.range == NSRange(location: 0, length: reading.utf16.count) &&
            $0.dictionaries.contains("learning")
        })
    }

    func testTopCandidateIsNotStoredWithoutLearnFirstPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let service = ConversionService()
        service.setLearning(url: database)

        let reading = "しろ"
        let response = try convert(service, reading: reading, generation: 1)
        let firstIndex = try XCTUnwrap(response.candidates.firstIndex {
            $0.range == NSRange(location: 0, length: reading.utf16.count)
        })
        XCTAssertEqual(firstIndex, 0)
        let firstCandidate = response.candidates[firstIndex]
        let finished = expectation(description: "Top candidate session finished without storage")
        service.commit(generation: response.generation, candidate: firstCandidate.id, candidateIndex: firstIndex,
                       learningAllowed: true, learnFirstCandidate: false) { message in
            XCTFail("No learning notice expected, got: \(message)")
        }
        // A following conversion is serialized behind commit and therefore acts
        // as a barrier even though an ineligible session emits no callback.
        service.convert("しろ", generation: 2, editStart: 0) { result in
            if case .failure(let error) = result { XCTFail("Barrier conversion failed: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        XCTAssertFalse(try LearningStore(url: database).snapshot().contains {
            $0.reading == reading && $0.text == firstCandidate.text
        })
    }
}
