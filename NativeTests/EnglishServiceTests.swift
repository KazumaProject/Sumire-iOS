import XCTest
import SumireCore

/// Compiles the same ConversionService source used by the app and extension.
/// This covers Swift/C ABI/storage integration, not keyboard UI or App Groups.
final class EnglishServiceTests: XCTestCase {
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64) throws -> ConversionResponse {
        let completed = expectation(description: "English conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: true) {
            response = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(response).get()
    }

    func testEnglishPredictionDoesNotUseOrUpdateLearningRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let store = try LearningStore(url: database)
        try store.record(reading: "iph", text: "iPhone")
        let before = try store.snapshot()

        let service = ConversionService()
        service.setLearning(url: database)
        let response = try convert(service, "iph", generation: 1)
        let phoneIndex = try XCTUnwrap(response.candidates.firstIndex { $0.text == "iPhone" })
        XCTAssertFalse(response.candidates[phoneIndex].dictionaries.contains("learning"))

        service.commit(generation: 1, candidate: response.candidates[phoneIndex].id,
                       candidateIndex: phoneIndex, learningAllowed: true,
                       learnFirstCandidate: true) { _ in
            XCTFail("English predictions must not write learning rows")
        }
        _ = try convert(service, "iph", generation: 2) // Serial queue barrier for commit.
        XCTAssertEqual(try LearningStore(url: database).snapshot(), before)
    }

    func testLearningPauseStopsWritesWhileKeepingExistingLearningAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        let seed = try LearningStore(url: database)
        try seed.record(reading: "iph", text: "iPhone")

        let service = ConversionService()
        service.setLearning(url: database)
        let first = try convert(service, "iph", generation: 1)
        let phone = try XCTUnwrap(first.candidates.first { $0.text == "iPhone" })
        XCTAssertTrue(phone.dictionaries.contains("learning"))

        service.setLearningPaused(true)
        let phoneIndex = try XCTUnwrap(first.candidates.firstIndex { $0.id == phone.id })
        service.commit(generation: 1, candidate: phone.id, candidateIndex: phoneIndex,
                       learningAllowed: true, learnFirstCandidate: true) { _ in
            XCTFail("Paused learning must not report a saved record")
        }
        let whilePaused = try convert(service, "iph", generation: 2)
        XCTAssertTrue(whilePaused.candidates.contains {
            $0.text == "iPhone" && $0.dictionaries.contains("learning")
        })
        XCTAssertEqual(try LearningStore(url: database).snapshot().first?.count, 1)

        service.setLearningPaused(false)
        let afterResume = try convert(service, "iph", generation: 3)
        let resumedPhone = try XCTUnwrap(afterResume.candidates.first { $0.text == "iPhone" })
        let committed = expectation(description: "Learning resumes")
        let resumedIndex = try XCTUnwrap(afterResume.candidates.firstIndex { $0.id == resumedPhone.id })
        service.commit(generation: 3, candidate: resumedPhone.id, candidateIndex: resumedIndex,
                       learningAllowed: true, learnFirstCandidate: true) { message in
            XCTAssertEqual(message, "学習しました")
            committed.fulfill()
        }
        wait(for: [committed], timeout: 10)
        _ = try convert(service, "iph", generation: 4)
        XCTAssertEqual(try LearningStore(url: database).snapshot().first?.count, 2)
    }

    func testEnglishUserWordsAndTemplatesFromPersistedGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLexiconStore(directory: directory)
        var lexicon = PersonalLexicon()
        lexicon.words = [PersonalWord(word: "MyPhone", reading: "iphone", posScore: -1000)]
        lexicon.templates = [PersonalWord(word: "Hello from Sumire", reading: "iph", posScore: -2000)]
        try store.save(lexicon)
        let service = ConversionService()
        service.setPersonal(try PersonalLexiconStore(directory: directory).load().lexicon)
        let exact = try convert(service, "iph", generation: 1)
        XCTAssertEqual(exact.candidates.first?.text, "Hello from Sumire")
        XCTAssertEqual(exact.candidates.first?.dictionaries, ["template"])
        let prefix = try convert(service, "ip", generation: 2)
        XCTAssertEqual(prefix.candidates.first?.text, "MyPhone")
        XCTAssertEqual(prefix.candidates.first?.dictionaries, ["user"])
        XCTAssertFalse(prefix.candidates.contains { $0.dictionaries.contains("template") })
        XCTAssertEqual(prefix.candidates.first?.range, NSRange(location: 0, length: 2))
        service.setPersonal(PersonalLexicon())
        let removed = try convert(service, "ip", generation: 3)
        XCTAssertFalse(removed.candidates.contains { $0.dictionaries.contains("user") || $0.dictionaries.contains("template") })
    }
}
