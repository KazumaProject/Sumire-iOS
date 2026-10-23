import XCTest
import CryptoKit
@testable import SumireCore

final class DictionaryGenerationStoreTests: XCTestCase {
    func testReadingCorrectionArchiveOutputCanReplaceBundledSupportInGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("base system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("base connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try Data("bundled correction".utf8).write(to: base.appendingPathComponent("reading_correction.sud"))
        let imported = incoming.appendingPathComponent("reading_correction.sud")
        try Data("imported correction".utf8).write(to: imported)

        let generation = try store.publish(importedFiles: ["reading_correction.sud": imported], from: base)

        XCTAssertEqual(try Data(contentsOf: generation.directory.appendingPathComponent("reading_correction.sud")),
                       Data("imported correction".utf8))
        let manifestData = try Data(contentsOf: generation.directory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["imported_files"] as? [String], ["reading_correction.sud"])
        XCTAssertEqual(store.loadCurrent()?.generation, generation.generation)
    }

    func testGenerationsOverlayImmutablyAndRecoverPreviousPointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("base system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("base connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try Data("base person".utf8).write(to: base.appendingPathComponent("person.sud"))
        let correction = Data("immutable reading correction".utf8)
        try correction.write(to: base.appendingPathComponent("reading_correction.sud"))
        let systemImport = incoming.appendingPathComponent("system.sud")
        try Data("imported system".utf8).write(to: systemImport)

        let first = try store.publish(importedFiles: ["system.sud": systemImport], from: base)
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("system.sud")), Data("imported system".utf8))
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("connection.sud")), Data("base connection".utf8))
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("person.sud")), Data("base person".utf8))
        XCTAssertEqual(store.loadCurrent()?.generation, first.generation)
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("reading_correction.sud")), correction)

        let personImport = incoming.appendingPathComponent("person.sud")
        try Data("imported person".utf8).write(to: personImport)
        let second = try store.publish(importedFiles: ["person.sud": personImport], from: first.directory)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("system.sud")), Data("imported system".utf8))
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("person.sud")), Data("imported person".utf8))
        XCTAssertEqual(store.loadCurrent()?.generation, second.generation)
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("reading_correction.sud")), correction)

        try Data("interrupted pointer".utf8).write(to: store.directory.appendingPathComponent("current.json"), options: .atomic)
        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, first.generation)
    }

    func testInvalidImportNamesAndFilesDoNotChangeCurrentGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        let current = try store.publish(importedFiles: [:], from: base)
        let evil = incoming.appendingPathComponent("evil.sud")
        try Data("not a known dictionary".utf8).write(to: evil)

        XCTAssertThrowsError(try store.publish(importedFiles: ["../evil.sud": evil], from: current.directory))
        XCTAssertEqual(store.loadCurrent()?.generation, current.generation)

        let directoryAsFile = incoming.appendingPathComponent("directory.sud", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAsFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.publish(importedFiles: ["system.sud": directoryAsFile], from: current.directory))
        XCTAssertEqual(store.loadCurrent()?.generation, current.generation)
    }

    func testManifestPointerRejectsCorruptionWithoutOverwritingSavedGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("connection".utf8).write(to: base.appendingPathComponent("connection.sud"))

        let generation = try store.publish(importedFiles: [:], from: base)
        let pointer = store.directory.appendingPathComponent("current.json")
        var bytes = try Data(contentsOf: pointer)
        bytes[bytes.startIndex] ^= 1
        try bytes.write(to: pointer, options: .atomic)

        XCTAssertNil(store.loadCurrent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: generation.directory.appendingPathComponent("system.sud").path))
    }

    func testLoadCandidatesReturnsCurrentThenPreviousWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("system v1".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        let first = try store.publish(importedFiles: [:], from: base)

        let replacement = incoming.appendingPathComponent("system.sud")
        try Data("system v2".utf8).write(to: replacement)
        let second = try store.publish(importedFiles: ["system.sud": replacement], from: first.directory)

        XCTAssertEqual(store.loadCandidates().map(\.generation), [second.generation, first.generation])
        XCTAssertEqual(store.loadCandidates().filter(\.recoveredPrevious).count, 1)
    }

    func testValidationFailureDoesNotPublishOrRemoveCurrentGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("system v1".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        let first = try store.publish(importedFiles: [:], from: base)

        let replacement = incoming.appendingPathComponent("system.sud")
        try Data("invalid system".utf8).write(to: replacement)
        XCTAssertThrowsError(try store.publish(importedFiles: ["system.sud": replacement], from: first.directory) { _ in
            throw NSError(domain: "DictionaryGenerationStoreTests", code: 1)
        })

        XCTAssertEqual(store.loadCurrent()?.generation, first.generation)
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("system.sud")), Data("system v1".utf8))
        let generations = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("generation-") }
        XCTAssertEqual(generations.map(\.lastPathComponent), [first.generation])
    }
    private var supportNames: [String] {
        ["standalone.sud", "reading_correction.sud", "system_ngram.dat", "system_ngram_unigram.dat",
         "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat", "single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"]
    }

    func testRepublishRepairsStrippedGenerationWithoutReplacingUserDictionaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("stripped")
        let bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in ["system.sud", "connection.sud", "person.sud", "english.sud", "english_reading.sud"] {
            try Data(("user " + name).utf8).write(to: base.appendingPathComponent(name))
            try Data(("bundled " + name).utf8).write(to: bundled.appendingPathComponent(name))
        }
        for name in supportNames {
            let url = bundled.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: url)
        }
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let stripped = try store.publish(importedFiles: [:], from: base)
        let repaired = try store.publish(importedFiles: [:], from: stripped.directory, supportFallback: bundled)
        for name in ["system.sud", "connection.sud", "person.sud", "english.sud", "english_reading.sud"] {
            XCTAssertEqual(try Data(contentsOf: repaired.directory.appendingPathComponent(name)), Data(("user " + name).utf8))
        }
        let next = try store.publish(importedFiles: [:], from: repaired.directory)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: next.directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let hashes = try XCTUnwrap(manifest["output_sha256"] as? [String: String])
        for name in supportNames {
            let data = try Data(contentsOf: next.directory.appendingPathComponent(name))
            XCTAssertEqual(data, Data(name.utf8))
            XCTAssertEqual(hashes[name], SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: next.directory, supportFallback: bundled) { _ in
            throw NSError(domain: "simulated interruption", code: 1)
        })
        XCTAssertEqual(store.loadCurrent()?.generation, next.generation)
        let moved = root.appendingPathComponent("moved-mozc")
        try FileManager.default.moveItem(at: next.directory.appendingPathComponent("mozc"), to: moved)
        try FileManager.default.createSymbolicLink(at: next.directory.appendingPathComponent("mozc"), withDestinationURL: moved)
        XCTAssertEqual(store.loadCurrent()?.generation, repaired.generation)
        XCTAssertTrue(try XCTUnwrap(store.loadCurrent()).recoveredPrevious)
    }

    func testSupportFilesRejectReplacementTraversalAndSymlinkParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["system.sud", "connection.sud"] { try Data(name.utf8).write(to: base.appendingPathComponent(name)) }
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let original = try store.publish(importedFiles: [:], from: base)
        for name in ["mozc/segmenter.dat", "../system.sud", "mozc/../system.sud", "standalone.sud"] {
            XCTAssertThrowsError(try store.publish(importedFiles: [name: base.appendingPathComponent("system.sud")], from: base))
        }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("unsafe".utf8).write(to: outside.appendingPathComponent("segmenter.dat"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("mozc"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: base))
        let linkedFallback = root.appendingPathComponent("linked-fallback")
        try FileManager.default.createDirectory(at: linkedFallback, withIntermediateDirectories: true)
        for name in supportNames where !name.hasPrefix("mozc/") {
            try Data(name.utf8).write(to: linkedFallback.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: linkedFallback.appendingPathComponent("mozc"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: original.directory, supportFallback: linkedFallback))
        XCTAssertEqual(store.loadCurrent()?.generation, original.generation)
        try FileManager.default.removeItem(at: base.appendingPathComponent("mozc"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("standalone.sud"), withDestinationURL: outside.appendingPathComponent("segmenter.dat"))
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: base))
        XCTAssertEqual(store.loadCurrent()?.generation, original.generation)
        try FileManager.default.removeItem(at: base.appendingPathComponent("standalone.sud"))
        try Data("partial ngram".utf8).write(to: base.appendingPathComponent("system_ngram.dat"))
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: base))
        XCTAssertEqual(store.loadCurrent()?.generation, original.generation)
    }

}
