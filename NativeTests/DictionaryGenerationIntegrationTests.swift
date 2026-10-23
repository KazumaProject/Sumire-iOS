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
        // Pin dictionary bytes independently of the supplied manifest's label.
        // Sorting makes this insensitive to JSON formatting/key iteration order.
        let pins = manifest.outputSHA256.keys.sorted().map {
            "\($0)=\(manifest.outputSHA256[$0]!)\n"
        }.joined()
        let digest = SHA256.hash(data: Data(pins.utf8)).map { String(format: "%02x", $0) }.joined()
        guard manifest.outputSHA256.count == 44,
              digest == "2326a2865968479168411258dcc22b5e2cc475e7ba8ae263edaf017c120c643f" else {
            XCTFail("Reference output hashes differ from the pinned df1f383 app generation")
            return
        }

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
        let bundled = try XCTUnwrap(ConversionService.bundledDictionary)
        // Exercise the app's publication path: converted word dictionaries
        // replace the bundled base while its support groups survive.
        let published = try store.publish(importedFiles: importedFiles, from: bundled,
                                          supportFallback: bundled) { directory in
            try Self.validateAllDictionaries(at: directory)
        }
        XCTAssertEqual(store.loadCurrent()?.generation, published.generation)
        for (name, expected) in manifest.outputSHA256 {
            try autoreleasepool {
                let data = try Data(contentsOf: published.directory.appendingPathComponent(name), options: .mappedIfSafe)
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected, name)
            }
        }

        var rejected = Set<URL>()
        let opened = try NativeDictionaryEngineOpener.open(
            directories: store.loadCandidates().map(\.directory), mask: 0x3fff_ffff,
            english: true, englishReading: true, rejecting: &rejected)
        defer { sumire_engine_close(opened.engine) }
        XCTAssertEqual(opened.directory, published.directory.standardizedFileURL)
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(sumire_engine_has_standalone_priority(opened.engine), 1)
        let bunsetsu = try convert(directory: published.directory, reading: "きょうはとうきょうにいきます", bunsetsu: true)
        XCTAssertTrue(bunsetsu.complete)
        XCTAssertTrue(bunsetsu.candidates.contains { $0.text == "今日は東京に行きます" })
        let correction = try convert(directory: published.directory, reading: "きしゃ")
        XCTAssertTrue(correction.candidates.contains { $0.text == "着尺" && $0.correctedReading == "きじゃく" })
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

    func testImportRepairsLegacyGenerationAndRetainsBundledConversionFeatures() throws {
        let base = try XCTUnwrap(ConversionService.bundledDictionary, "Bundled dictionaries required")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stripped = root.appendingPathComponent("legacy-stripped")
        try FileManager.default.createDirectory(at: stripped, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Model generations published by the former 34-file-only allowlist.
        for name in DictionaryArchivePlan.categoryIDs + ["system", "connection", "english", "english_reading"] {
            try FileManager.default.copyItem(at: base.appendingPathComponent(name + ".sud"),
                                            to: stripped.appendingPathComponent(name + ".sud"))
        }
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let published = try store.publish(importedFiles: ["person.sud": stripped.appendingPathComponent("person.sud")],
                                          from: stripped, supportFallback: base) { directory in
            try Self.validateAllDictionaries(at: directory)
        }
        let support = ["standalone.sud", "reading_correction.sud", "system_ngram.dat", "system_ngram_unigram.dat",
                       "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat", "single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"]
        for name in support + ["system.sud", "connection.sud", "person.sud", "english.sud", "english_reading.sud"] {
            let original = try Data(contentsOf: base.appendingPathComponent(name), options: .mappedIfSafe)
            let copied = try Data(contentsOf: published.directory.appendingPathComponent(name), options: .mappedIfSafe)
            XCTAssertEqual(SHA256.hash(data: original), SHA256.hash(data: copied), name)
        }
        var engine: OpaquePointer?
        var error = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(sumire_engine_open_with_dictionaries(published.directory.path, 0, 3, &engine, &error, error.count), 0)
        let opened = try XCTUnwrap(engine)
        XCTAssertEqual(sumire_engine_has_standalone_priority(opened), 1)
        sumire_engine_close(opened)
        let bunsetsu = try convert(directory: published.directory, reading: "きょうはとうきょうにいきます", bunsetsu: true)
        XCTAssertTrue(bunsetsu.complete)
        XCTAssertTrue(bunsetsu.candidates.contains { $0.text == "今日は東京に行きます" })
        for name in ["single_kanji", "emoji", "emoticon", "symbol"] {
            let reading = try firstReading(directory: base, name: name)
            let original = try convert(directory: base, reading: reading)
            let copied = try convert(directory: published.directory, reading: reading)
            XCTAssertTrue(original.candidates.contains { $0.dictionaries.contains(name) }, "Fixture must exercise \(name)")
            XCTAssertEqual(original.candidates.map(\.text), copied.candidates.map(\.text), name)
            XCTAssertEqual(original.candidates.map(\.dictionaries), copied.candidates.map(\.dictionaries), name)
        }
    }

    private func convert(directory: URL, reading: String, bunsetsu: Bool = false) throws -> ConversionResponse {
        let service = ConversionService(directory: directory)
        let completed = expectation(description: "Published dictionary conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: 1, editStart: 0, bunsetsuSearch: bunsetsu) {
            response = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        return try XCTUnwrap(response).get()
    }

    private func firstReading(directory: URL, name: String) throws -> String {
        // The product browser deliberately excludes auxiliary names. Browse an
        // unchanged test-only copy through its supported system-dictionary name.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.copyItem(at: directory.appendingPathComponent(name + ".sud"),
                                        to: fixture.appendingPathComponent("system.sud"))
        var browser: OpaquePointer?
        var error = [CChar](repeating: 0, count: 1024)
        guard sumire_dictionary_browser_open(fixture.path, "system", "", 0, &browser, &error, error.count) == 0 else {
            throw NSError(domain: "Auxiliary test fixture browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
        }
        let opened = try XCTUnwrap(browser)
        defer { sumire_dictionary_browser_close(opened) }
        while sumire_dictionary_browser_done(opened) == 0 {
            guard sumire_dictionary_browser_step(opened, 1, &error, error.count) == 0 else {
                throw NSError(domain: "Auxiliary browser failed", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
            }
            if sumire_dictionary_browser_count(opened) > 0 {
                var row = sumire_dictionary_row()
                XCTAssertEqual(sumire_dictionary_browser_row(opened, 0, &row), 0)
                let reading = String(decoding: UnsafeRawBufferPointer(start: row.reading, count: row.reading_bytes), as: UTF8.self)
                if !reading.isEmpty && reading.utf16.count <= 16 { return reading }
            }
        }
        throw NSError(domain: "Missing auxiliary test reading", code: 1)
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
