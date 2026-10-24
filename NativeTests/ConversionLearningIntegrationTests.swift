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
                       learnFirstCandidate: false, learnMixedSymbolsAndNumbers: true) { message in
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
        XCTAssertEqual(entry.leftID, selected.element.leftID ?? 1851)
        XCTAssertEqual(entry.rightID, selected.element.rightID ?? 1851)
        XCTAssertEqual(entry.count, 1)
        XCTAssertEqual(entry.usageCount, 1)

        let next = try convert(service, reading: reading, generation: 2)
        let selectedSummary = "\(selected.element.text):score=\(selected.element.score):index=\(selected.offset):left=\(entry.leftID.map(String.init) ?? "nil"):right=\(entry.rightID.map(String.init) ?? "nil"):stored=\(entry.score)"
        let returnedSummary = next.candidates.map {
            "\($0.text):score=\($0.score):sources=\($0.dictionaries.joined(separator: ","))"
        }.joined(separator: " | ")
        XCTAssertTrue(next.candidates.contains { $0.text == selected.element.text },
                      "Selected surface disappeared. Selected {\(selectedSummary)}; returned {\(returnedSummary)}")
    }

    func testBunsetsuSegmentsPersistAsOneOriginalPhrase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let service = ConversionService()
        service.setLearning(url: database)

        let originalReading = "わたしはあるく"
        let firstReading = "わたしは"
        let firstResponse = try convert(service, reading: firstReading, generation: 1)
        let first = try XCTUnwrap(firstResponse.candidates.enumerated().first {
            $0.element.text == "私は" && $0.element.range == NSRange(location: 0, length: firstReading.utf16.count)
        })
        service.commit(generation: firstResponse.generation, candidate: first.element.id,
                       candidateIndex: first.offset, learningAllowed: true,
                       learnFirstCandidate: true, learnMixedSymbolsAndNumbers: true,
                       learningSessionReading: originalReading, learningSessionContinues: true) { _ in
            XCTFail("An incomplete bunsetsu session must not be persisted yet")
        }
        service.reset()

        let remainderReading = "あるく"
        let remainderResponse = try convert(service, reading: remainderReading, generation: 2)
        let remainder = try XCTUnwrap(remainderResponse.candidates.enumerated().first {
            $0.element.text == "歩く" && $0.element.range == NSRange(location: 0, length: remainderReading.utf16.count)
        })
        let persisted = expectation(description: "Completed bunsetsu learning session persisted")
        service.commit(generation: remainderResponse.generation, candidate: remainder.element.id,
                       candidateIndex: remainder.offset, learningAllowed: true,
                       learnFirstCandidate: true, learnMixedSymbolsAndNumbers: true,
                       learningSessionReading: originalReading, learningSessionContinues: false) { message in
            XCTAssertEqual(message, "学習しました")
            persisted.fulfill()
        }
        wait(for: [persisted], timeout: 10)

        XCTAssertTrue(try LearningStore(url: database).snapshot().contains {
            $0.reading == originalReading && $0.text == "私は歩く" && $0.isPhrase
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

    func testLearnedDictionaryPredictionIsOptInAndCommitsTheStoredReading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: database)
        try store.upsertLearningEntries([
            .init(input: "あいう", output: "愛優", score: 1_000, leftID: 11, rightID: 12,
                  usageCount: 1, lastUsedAt: 10, isPhrase: false),
            .init(input: "あいえ", output: "愛絵", score: 2_000, leftID: 21, rightID: 22,
                  usageCount: 1, lastUsedAt: 20, isPhrase: false),
        ])

        let service = ConversionService()
        service.setLearning(url: database)

        let disabled = try convert(service, reading: "あい", generation: 1)
        XCTAssertFalse(disabled.candidates.contains { $0.learnedPredictionReading != nil })

        service.setLearnedPredictionSettings(.init(enabled: true, minimumInputLength: 2, candidateLimit: 2))
        let enabled = try convert(service, reading: "あい", generation: 2)
        let selected = try XCTUnwrap(enabled.candidates.first { $0.learnedPredictionReading == "あいえ" })
        XCTAssertEqual(selected.text, "愛絵")
        XCTAssertEqual(selected.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(selected.dictionaries, ["learning"])
        let selectedIndex = try XCTUnwrap(enabled.candidates.firstIndex { $0.id == selected.id })
        XCTAssertGreaterThan(selectedIndex, 0, "The non-first suggestion exercises the normal learning eligibility policy")

        let committed = expectation(description: "Predicted learned entry committed")
        service.commit(generation: enabled.generation, candidate: selected.id, candidateIndex: selectedIndex,
                       learningAllowed: true, learnFirstCandidate: false, learnMixedSymbolsAndNumbers: true) { message in
            XCTAssertEqual(message, "学習しました")
            committed.fulfill()
        }
        wait(for: [committed], timeout: 10)

        let entry = try XCTUnwrap(LearningStore(url: database).snapshot().first {
            $0.reading == "あいえ" && $0.text == "愛絵"
        })
        XCTAssertEqual(entry.usageCount, 2)
        XCTAssertEqual(entry.score, 0)
    }

    func testMissingLearnedEndpointIDsFallBackIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: database)
        try store.upsertLearningEntries([
            .init(input: "しろ", output: "左側学習", score: 1_000, leftID: nil, rightID: 12,
                  lastUsedAt: 1, isPhrase: false),
            .init(input: "しろ", output: "右側学習", score: 1_000, leftID: 11, rightID: nil,
                  lastUsedAt: 2, isPhrase: false),
        ])

        let service = ConversionService()
        service.setLearning(url: database)
        let response = try convert(service, reading: "しろ", generation: 1)
        let leftFallback = try XCTUnwrap(response.candidates.first {
            $0.text == "左側学習" && $0.dictionaries.contains("learning")
        })
        let rightFallback = try XCTUnwrap(response.candidates.first {
            $0.text == "右側学習" && $0.dictionaries.contains("learning")
        })

        XCTAssertEqual(leftFallback.leftID, Int16(1851))
        XCTAssertEqual(leftFallback.rightID, Int16(12))
        XCTAssertEqual(rightFallback.leftID, Int16(11))
        XCTAssertEqual(rightFallback.rightID, Int16(1851))
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
                       learningAllowed: true, learnFirstCandidate: false,
                       learnMixedSymbolsAndNumbers: true) { message in
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
