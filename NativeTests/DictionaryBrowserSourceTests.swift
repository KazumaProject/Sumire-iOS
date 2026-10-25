import XCTest
import SumireCore
@testable import Sumire

final class DictionaryBrowserSourceTests: XCTestCase {
    func testSharedCurrentThenPreviousThenBundledAreOrderedWithPerDictionaryProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("base system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("base connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try Data("bundled system".utf8).write(to: bundled.appendingPathComponent("system.sud"))

        let previous = try store.publish(importedFiles: [:], from: base)
        let incoming = root.appendingPathComponent("incoming-system.sud")
        try Data("current system".utf8).write(to: incoming)
        let current = try store.publish(importedFiles: ["system.sud": incoming], from: previous.directory)
        let sources = DictionaryBrowserSource.candidates(
            name: "system", generations: store.loadCandidates(), bundled: bundled)

        XCTAssertEqual(sources.map(\.directory), [current.directory, previous.directory, bundled])
        XCTAssertEqual(sources.compactMap(\.generation), [current.generation, previous.generation])
        XCTAssertEqual(sources.map(\.title), ["共有辞書（現行世代）", "共有辞書（前世代）", "同梱辞書"])
        XCTAssertEqual(sources[0].sourceRevision, "unknown-or-mixed")
        XCTAssertNotNil(sources[0].dictionarySHA256)
        XCTAssertEqual(sources[2].origin, .bundled)
    }

    func testMissingSharedDictionaryFallsBackToBundledAndRejectsUnknownNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("base system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("base connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try Data("bundled person".utf8).write(to: bundled.appendingPathComponent("person.sud"))
        let generation = try store.publish(importedFiles: [:], from: base)

        let sources = DictionaryBrowserSource.candidates(
            name: "person", generations: [generation], bundled: bundled)
        XCTAssertEqual(sources.map(\.directory), [bundled])
        XCTAssertEqual(sources.first?.origin, .bundled)
        XCTAssertTrue(DictionaryBrowserSource.candidates(
            name: "../outside", generations: [generation], bundled: bundled).isEmpty)
    }

    func testBrowserOpenSkipsCorruptCurrentGenerationAndUsesPreviousBeforeBundled() throws {
        guard let bundled = ConversionService.bundledDictionary else {
            throw XCTSkip("Bundled native dictionary is unavailable in this test host")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let previous = try store.publish(importedFiles: [:], from: bundled)
        let corrupt = root.appendingPathComponent("corrupt-system.sud")
        try Data("not a native dictionary".utf8).write(to: corrupt)
        let current = try store.publish(importedFiles: ["system.sud": corrupt], from: previous.directory)
        let candidates = DictionaryBrowserSource.candidates(
            name: "system", generations: store.loadCandidates(), bundled: bundled)
        XCTAssertEqual(candidates.first?.generation, current.generation)

        let opened = try DictionaryBrowserSource.open(name: "system", query: "", mode: 2,
                                                      candidates: candidates)
        defer { sumire_dictionary_browser_close(opened.cursor) }
        XCTAssertEqual(opened.source.generation, previous.generation)
        XCTAssertEqual(opened.source.title, "共有辞書（前世代）")
    }
}
