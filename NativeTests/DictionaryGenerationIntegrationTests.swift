import XCTest
import SumireCore

final class DictionaryGenerationIntegrationTests: XCTestCase {
    func testNativeLoaderValidatesGenerationBeforePointerSwitch() throws {
        guard let base = ConversionService.bundledDictionary else {
            throw XCTSkip("Bundled native dictionary is unavailable in this test host")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try store.publish(importedFiles: [:], from: base) { directory in
            try Self.validateAllDictionaries(at: directory)
        }
        XCTAssertEqual(store.loadCurrent()?.generation, first.generation)

        let invalidSystem = incoming.appendingPathComponent("system.sud")
        try Data("not a native dictionary".utf8).write(to: invalidSystem)
        XCTAssertThrowsError(try store.publish(importedFiles: ["system.sud": invalidSystem], from: first.directory) { directory in
            try Self.validateAllDictionaries(at: directory)
        })
        XCTAssertEqual(store.loadCurrent()?.generation, first.generation)
    }

    func testNativeOpenerFallsBackWhenActiveGenerationIsCorrupted() throws {
        guard let base = ConversionService.bundledDictionary else {
            throw XCTSkip("Bundled native dictionary is unavailable in this test host")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }

        let previous = try store.publish(importedFiles: [:], from: base)
        let current = try store.publish(importedFiles: [:], from: previous.directory)
        try Data("corrupted native dictionary".utf8)
            .write(to: current.directory.appendingPathComponent("system.sud"), options: .atomic)

        var rejected = Set<URL>()
        let opened = try NativeDictionaryEngineOpener.open(
            directories: store.loadCandidates().map(\.directory), mask: 0x3fff_ffff,
            english: true, englishReading: true, rejecting: &rejected)
        defer { sumire_engine_close(opened.engine) }

        XCTAssertEqual(opened.directory, previous.directory.standardizedFileURL)
        XCTAssertTrue(rejected.contains(current.directory.standardizedFileURL))
    }

    private nonisolated static func validateAllDictionaries(at directory: URL) throws {
        var engine: OpaquePointer?
        var error = [CChar](repeating: 0, count: 1024)
        let status = directory.path.withCString { path in
            sumire_engine_open_with_dictionaries(path, 0x3fff_ffff, 3, &engine, &error, error.count)
        }
        guard status == 0, let engine else {
            throw NSError(domain: "DictionaryGenerationIntegrationTests", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
        }
        sumire_engine_close(engine)
    }
}
