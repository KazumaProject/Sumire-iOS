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

    func testEnglishLearningPersistsDisablesAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("learning.sqlite")
        var service: ConversionService? = ConversionService()
        service!.setLearning(url: database)
        let first = try convert(service!, "iph", generation: 1)
        let phone = try XCTUnwrap(first.candidates.first { $0.text == "iPhone" })
        let committed = expectation(description: "English learning committed")
        service!.commit(generation: 1, candidate: phone.id, learn: true) {
            XCTAssertEqual($0, "学習しました")
            committed.fulfill()
        }
        wait(for: [committed], timeout: 10)
        service = nil

        service = ConversionService()
        service!.setLearning(url: database)
        let restored = try convert(service!, "iph", generation: 1)
        XCTAssertEqual(restored.candidates.first?.text, "iPhone")
        XCTAssertEqual(restored.candidates.first?.dictionaries, ["learning"])
        XCTAssertNil(restored.warning)

        service!.setLearning(url: nil)
        let disabled = try convert(service!, "iph", generation: 2)
        XCTAssertFalse(disabled.candidates.contains { $0.dictionaries.contains("learning") })
        XCTAssertEqual(disabled.candidates.first?.text, "iph")
        service = nil
        do {
            let store = try LearningStore(url: database)
            XCTAssertEqual(try store.candidates(reading: "iph").first?.text, "iPhone")
            try store.remove(reading: "iph", text: "iPhone")
        }
        service = ConversionService()
        service!.setLearning(url: database)
        let removed = try convert(service!, "iph", generation: 1)
        XCTAssertFalse(removed.candidates.contains { $0.dictionaries.contains("learning") })
        service = nil
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
