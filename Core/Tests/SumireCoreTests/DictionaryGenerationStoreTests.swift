import XCTest
@testable import SumireCore

final class DictionaryGenerationStoreTests: XCTestCase {
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
}
