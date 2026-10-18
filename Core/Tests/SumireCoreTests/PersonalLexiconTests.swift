import XCTest
@testable import SumireCore

final class PersonalLexiconTests: XCTestCase {
    func testAndroidPreviewStagesValidRowsAndReportsFailures() throws {
        let input = #"[{"id":7,"word":"菫","reading":"すみれ","posIndex":0,"posScore":4000},{"word":"bad","reading":"","posIndex":0,"posScore":0},{"word":"菫","reading":"すみれ","posIndex":0,"posScore":3000},{"word":"bad","reading":"あ","posIndex":true,"posScore":0}]"#
        let preview = try PersonalImportPreview.parse(Data(input.utf8))
        XCTAssertEqual(preview.entries.count, 1)
        XCTAssertEqual(preview.entries[0].posScore, 3000)
        XCTAssertEqual(preview.rejected, 2)
        XCTAssertEqual(preview.duplicates, 1)
        XCTAssertEqual(preview.errors.count, 2)
        XCTAssertThrowsError(try PersonalImportPreview.parse(Data("{bad".utf8)))
        XCTAssertThrowsError(try PersonalImportPreview.parse(Data("{}".utf8)))
    }
    func testImmutableGenerationsRecoverAndFailedSavePreservesData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLexiconStore(directory: directory)
        XCTAssertEqual(try store.load().lexicon, PersonalLexicon())
        var original = PersonalLexicon()
        original.words = [.init(word: "菫", reading: "すみれ")]
        let first = try store.save(original)
        var newer = original
        newer.templates = [.init(word: "お世話になっております。\nよろしくお願いします。", reading: "めーる", posScore: -1000)]
        let second = try store.save(newer)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(try store.load().lexicon, newer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.generation).path))
        var invalid = newer
        invalid.words.append(.init(word: "", reading: "あ"))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load().lexicon, newer)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(second.generation))
        let recovered = try store.load()
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.lexicon, original)
        try Data("corrupt pointer".utf8).write(to: directory.appendingPathComponent("current.json"))
        XCTAssertEqual(try store.load().lexicon, original)
        // Saving after recovery must preserve the validated fallback, not copy a broken pointer.
        let third = try store.save(newer)
        try Data("corrupt again".utf8).write(to: directory.appendingPathComponent(third.generation))
        XCTAssertEqual(try store.load().lexicon, original)
    }
    func testUnsupportedVersionDuplicatesAndLimitsRejectWithoutTruncation() throws {
        var data = PersonalLexicon()
        data.formatVersion = 99
        XCTAssertThrowsError(try data.validate())
        data.formatVersion = 1
        data.words = [.init(word: "表記", reading: String(repeating: "あ", count: 8193))]
        XCTAssertThrowsError(try data.validate())
        data.words = [.init(word: "菫", reading: "すみれ"), .init(word: "菫", reading: "すみれ")]
        XCTAssertThrowsError(try data.validate())
    }
}
