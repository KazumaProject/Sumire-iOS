import XCTest
import CryptoKit
import SumireCore

final class DictionaryGenerationIntegrationTests: XCTestCase {
    func testPinnedAndroidArchiveConvertsPublishesAndOpensAllDictionaries() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_SOURCE_ZIP"], !archivePath.isEmpty,
              let nativePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_NATIVE_DICTIONARIES"], !nativePath.isEmpty else {
            throw XCTSkip("Set SUMIRE_REFERENCE_SOURCE_ZIP and SUMIRE_REFERENCE_NATIVE_DICTIONARIES for the pinned import integration check")
        }
        struct Manifest: Decodable {
            let sourceRevision: String
            let outputSHA256: [String: String]
            enum CodingKeys: String, CodingKey {
                case sourceRevision = "source_revision"
                case outputSHA256 = "output_sha256"
            }
        }
        let manifestURL = URL(fileURLWithPath: nativePath, isDirectory: true).appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.sourceRevision, "df1f38315bf56d860d32919a3eaed6a75499e91e")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let convertedDirectory = root.appendingPathComponent("converted", isDirectory: true)
        let report = try DictionarySourceArchiveConverter.convert(
            archiveAt: URL(fileURLWithPath: archivePath), into: convertedDirectory)
        XCTAssertEqual(report.convertedFiles.count, 34)
        XCTAssertTrue(report.skippedGroups.isEmpty)
        for name in report.convertedFiles {
            let data = try Data(contentsOf: convertedDirectory.appendingPathComponent(name), options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, manifest.outputSHA256[name], "Converted output differs for \(name)")
        }

        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        let importedFiles = Dictionary(uniqueKeysWithValues: report.convertedFiles.map {
            ($0, convertedDirectory.appendingPathComponent($0))
        })
        let published = try store.publish(importedFiles: importedFiles, from: convertedDirectory) { directory in
            try Self.validateAllDictionaries(at: directory)
        }
        XCTAssertEqual(store.loadCurrent()?.generation, published.generation)

        var rejected = Set<URL>()
        let opened = try NativeDictionaryEngineOpener.open(
            directories: store.loadCandidates().map(\.directory), mask: 0x3fff_ffff,
            english: true, englishReading: true, rejecting: &rejected)
        defer { sumire_engine_close(opened.engine) }
        XCTAssertEqual(opened.directory, published.directory.standardizedFileURL)
        XCTAssertTrue(rejected.isEmpty)
    }

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
