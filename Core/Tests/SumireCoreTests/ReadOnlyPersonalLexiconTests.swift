import XCTest
@testable import SumireCore

final class ReadOnlyPersonalLexiconTests: XCTestCase {
    func testLoadingMissingAndRecoveredGenerationsDoesNotChangeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLexiconStore(directory: directory)
        XCTAssertEqual(try store.load().lexicon, PersonalLexicon())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var original = PersonalLexicon()
        original.words = [.init(word: "菫", reading: "すみれ")]
        try store.save(original)
        let second = try store.save(PersonalLexicon())
        try Data("corrupted fixture".utf8).write(to: directory.appendingPathComponent(second.generation))
        func contents() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
                ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
            })
        }
        let before = try contents()
        let recovered = try store.load()
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.lexicon, original)
        XCTAssertEqual(try contents(), before)
    }
}
