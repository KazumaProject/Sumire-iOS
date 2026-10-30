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

    func testKotowazaArchiveOutputIsPublishedAndChecksummed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("base system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("base connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        let imported = incoming.appendingPathComponent("kotowaza.sud")
        try Data("converted kotowaza".utf8).write(to: imported)

        let generation = try store.publish(importedFiles: ["kotowaza.sud": imported], from: base)
        let published = try Data(contentsOf: generation.directory.appendingPathComponent("kotowaza.sud"))
        XCTAssertEqual(published, Data("converted kotowaza".utf8))
        let manifestData = try Data(contentsOf: generation.directory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["imported_files"] as? [String], ["kotowaza.sud"])
        let hashes = try XCTUnwrap(manifest["output_sha256"] as? [String: String])
        XCTAssertEqual(hashes["kotowaza.sud"], SHA256.hash(data: published).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(store.loadCurrent()?.generation, generation.generation)
    }

    func testAuxiliaryArchiveOutputsCanReplaceBundledSupportInGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("shared/Sumire/Dictionaries", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", "single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"] {
            try Data(("bundled " + name).utf8).write(to: base.appendingPathComponent(name))
        }
        var importedFiles: [String: URL] = [:]
        for name in ["single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"] {
            let file = incoming.appendingPathComponent(name)
            try Data(("imported " + name).utf8).write(to: file)
            importedFiles[name] = file
        }

        let generation = try store.publish(importedFiles: importedFiles, from: base)

        for name in importedFiles.keys {
            XCTAssertEqual(try Data(contentsOf: generation.directory.appendingPathComponent(name)), Data(("imported " + name).utf8))
        }
        let manifestData = try Data(contentsOf: generation.directory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(Set(manifest["imported_files"] as? [String] ?? []), Set(importedFiles.keys))
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

    func testReleaseGenerationAcceptsSameNamedReleaseLeafAndRejectsLegacyOnlyAggregate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", "character.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let current = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let character = incoming.appendingPathComponent("character.sud")
        try Data("release character leaf".utf8).write(to: character)
        let releaseGeneration = try store.publish(importedFiles: ["character.sud": character], from: current.directory,
                                                  importMode: .releaseLeaf)
        XCTAssertNotEqual(releaseGeneration.generation, current.generation)
        XCTAssertEqual(try Data(contentsOf: releaseGeneration.directory.appendingPathComponent("character.sud")),
                       Data("release character leaf".utf8))
        XCTAssertEqual(releaseGeneration.legacyAggregateOverlayIDs, [])

        let person = incoming.appendingPathComponent("person.sud")
        try Data("legacy person aggregate".utf8).write(to: person)
        XCTAssertThrowsError(try store.publish(importedFiles: ["person.sud": person], from: releaseGeneration.directory,
                                               importMode: .releaseLeaf))
        XCTAssertEqual(store.loadCurrent()?.generation, releaseGeneration.generation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: releaseGeneration.directory.appendingPathComponent("legacy_aggregates/character.sud").path))
    }

    func testReleaseLeafRejectsUnmarkedBaseWithoutReplacingOverlappingLegacyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("legacy-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyFiles = ["character.sud": Data("legacy character aggregate".utf8),
                           "work_franchise.sud": Data("legacy franchise aggregate".utf8)]
        try Data("legacy system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("legacy connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        for (name, data) in legacyFiles { try data.write(to: base.appendingPathComponent(name)) }
        let current = try store.publish(importedFiles: [:], from: base)

        for name in legacyFiles.keys.sorted() {
            let releaseLeaf = incoming.appendingPathComponent(name)
            try Data(("release leaf " + name).utf8).write(to: releaseLeaf)
            XCTAssertThrowsError(try store.publish(importedFiles: [name: releaseLeaf], from: current.directory,
                                                   importMode: .releaseLeaf), name)
            XCTAssertEqual(store.loadCurrent()?.generation, current.generation)
            XCTAssertEqual(try Data(contentsOf: current.directory.appendingPathComponent(name)),
                           try XCTUnwrap(legacyFiles[name]))
        }
    }

    func testReleaseLeafBootstrapsUnmarkedBundledBaseAsMarkedGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("bundled system".utf8).write(to: bundled.appendingPathComponent("system.sud"))
        try Data("bundled connection".utf8).write(to: bundled.appendingPathComponent("connection.sud"))
        try Data("bundled character".utf8).write(to: bundled.appendingPathComponent("character.sud"))
        for name in ["standalone.sud", "reading_correction.sud", "system_ngram.dat", "system_ngram_unigram.dat",
                     "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat", "single_kanji.sud", "emoji.sud",
                     "emoticon.sud", "symbol.sud"] {
            let file = bundled.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("bundled " + name).utf8).write(to: file)
        }
        let releaseLeaf = incoming.appendingPathComponent("character.sud")
        try Data("release character leaf".utf8).write(to: releaseLeaf)

        let generation = try store.publish(importedFiles: ["character.sud": releaseLeaf], from: bundled,
                                           supportFallback: bundled, importMode: .releaseLeaf)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: generation.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path))
        XCTAssertEqual(try Data(contentsOf: generation.directory.appendingPathComponent("character.sud")),
                       Data("release character leaf".utf8))
        XCTAssertEqual(store.loadCurrent()?.generation, generation.generation)
    }

    func testReleaseTransitionQuarantinesAndRetainsUnclassifiedOldGenerationCategories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let releaseBase = root.appendingPathComponent("release-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releaseBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Recreate the v1 generation manifest written before release taxonomy
        // markers and typed overlay metadata existed.
        let oldValues = [
            "system.sud": Data("old system".utf8),
            "connection.sud": Data("old connection".utf8),
            "character.sud": Data("old unclassified character bytes".utf8),
            "work_franchise.sud": Data("old unclassified franchise bytes".utf8)
        ]
        let generationID = UUID().uuidString.lowercased()
        let generationName = "generation-" + generationID
        let oldGeneration = storeDirectory.appendingPathComponent(generationName, isDirectory: true)
        try FileManager.default.createDirectory(at: oldGeneration, withIntermediateDirectories: false)
        var oldHashes: [String: String] = [:]
        for (name, data) in oldValues {
            try data.write(to: oldGeneration.appendingPathComponent(name))
            oldHashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let oldManifest = try JSONSerialization.data(withJSONObject: [
            "format_version": 1,
            "generation": generationID,
            "source_revision": "unknown-or-mixed",
            "imported_files": ["character.sud", "work_franchise.sud"],
            "output_sha256": oldHashes
        ], options: [.sortedKeys])
        try oldManifest.write(to: oldGeneration.appendingPathComponent("manifest.json"))
        let manifestDigest = SHA256.hash(data: oldManifest).map { String(format: "%02x", $0) }.joined()
        let oldPointer = try JSONSerialization.data(withJSONObject: [
            "format_version": 1,
            "generation": generationName,
            "manifest_sha256": manifestDigest
        ], options: [.sortedKeys])
        try oldPointer.write(to: storeDirectory.appendingPathComponent("current.json"))

        let oldLoaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(oldLoaded.unclassifiedLegacyRootCategoryIDs, ["character", "work_franchise"])
        XCTAssertTrue(oldLoaded.preservedUnclassifiedCategoryIDs.isEmpty)

        // A current release base with the full support groups available.
        let releaseValues = [
            "system.sud", "connection.sud", "character.sud", "standalone.sud",
            "reading_correction.sud", "system_ngram.dat", "system_ngram_unigram.dat",
            "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat", "single_kanji.sud",
            "emoji.sud", "emoticon.sud", "symbol.sud"
        ]
        for name in releaseValues {
            let file = releaseBase.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("release base " + name).utf8).write(to: file)
        }
        try Data().write(to: releaseBase.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let incomingCharacter = incoming.appendingPathComponent("character.sud")
        try Data("new release character leaf".utf8).write(to: incomingCharacter)

        let first = try store.publish(importedFiles: ["character.sud": incomingCharacter], from: releaseBase,
                                      supportFallback: releaseBase, importMode: .releaseLeaf)
        XCTAssertEqual(first.preservedUnclassifiedCategoryIDs, ["character", "work_franchise"])
        XCTAssertTrue(first.unclassifiedLegacyRootCategoryIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("character.sud")),
                       Data("new release character leaf".utf8))
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("unclassified_categories/character.sud")),
                       oldValues["character.sud"])
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("unclassified_categories/work_franchise.sud")),
                       oldValues["work_franchise.sud"])

        let second = try store.publish(importedFiles: [:], from: first.directory,
                                       supportFallback: releaseBase, importMode: .releaseLeaf)
        XCTAssertEqual(second.preservedUnclassifiedCategoryIDs, ["character", "work_franchise"])
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("character.sud")),
                       Data("new release character leaf".utf8))
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("unclassified_categories/character.sud")),
                       oldValues["character.sud"])
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("unclassified_categories/work_franchise.sud")),
                       oldValues["work_franchise.sud"])

        try Data("corrupt".utf8).write(to: second.directory.appendingPathComponent("unclassified_categories/character.sud"),
                                       options: .atomic)
        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.preservedUnclassifiedCategoryIDs, ["character", "work_franchise"])
        XCTAssertEqual(try Data(contentsOf: recovered.directory.appendingPathComponent("character.sud")),
                       Data("new release character leaf".utf8))
        XCTAssertEqual(try Data(contentsOf: recovered.directory.appendingPathComponent("unclassified_categories/character.sud")),
                       oldValues["character.sud"])
        XCTAssertEqual(try Data(contentsOf: recovered.directory.appendingPathComponent("unclassified_categories/work_franchise.sud")),
                       oldValues["work_franchise.sud"])
    }

    func testReleaseModeNonCategoryImportPreservesUnmarkedLegacyBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, value) in ["system.sud": "legacy system", "connection.sud": "legacy connection",
                              "character.sud": "legacy family character"] {
            try Data(value.utf8).write(to: base.appendingPathComponent(name))
        }
        let initial = try store.publish(importedFiles: [:], from: base)
        let connection = incoming.appendingPathComponent("connection.sud")
        try Data("updated connection".utf8).write(to: connection)

        let published = try store.publish(importedFiles: ["connection.sud": connection], from: initial.directory,
                                          importMode: .releaseLeaf)

        XCTAssertEqual(try Data(contentsOf: published.directory.appendingPathComponent("connection.sud")),
                       Data("updated connection".utf8))
        XCTAssertEqual(try Data(contentsOf: published.directory.appendingPathComponent("character.sud")),
                       Data("legacy family character".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: published.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path))

        let releaseCharacter = incoming.appendingPathComponent("release-character.sud")
        try Data("release character leaf".utf8).write(to: releaseCharacter)
        XCTAssertThrowsError(try store.publish(importedFiles: ["character.sud": releaseCharacter],
                                               from: published.directory, importMode: .releaseLeaf))
        XCTAssertEqual(store.loadCurrent()?.generation, published.generation)
    }

    func testTypedLegacyOverlaysSurvivePublicationFromDifferentTaxonomyBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyBase = root.appendingPathComponent("legacy-base", isDirectory: true)
        let releaseBase = root.appendingPathComponent("release-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: legacyBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releaseBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud"] {
            try Data(("legacy " + name).utf8).write(to: legacyBase.appendingPathComponent(name))
            try Data(("release " + name).utf8).write(to: releaseBase.appendingPathComponent(name))
        }
        try Data("release taxonomy".utf8).write(
            to: releaseBase.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let aggregate = incoming.appendingPathComponent("person.sud")
        let aggregateData = Data("stored old person aggregate".utf8)
        try aggregateData.write(to: aggregate)
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let initial = try store.publish(importedFiles: [:], from: legacyBase)
        let withOverlay = try store.publish(importedFiles: [:], from: initial.directory,
                                            legacyAggregateOverlays: [person: aggregate],
                                            importMode: .typedLegacyAggregate)
        XCTAssertEqual(withOverlay.legacyAggregateOverlayIDs, [person])
        XCTAssertEqual(store.loadCurrent()?.generation, withOverlay.generation)

        let character = incoming.appendingPathComponent("character.sud")
        try Data("new release character".utf8).write(to: character)
        let releaseGeneration = try store.publish(importedFiles: ["character.sud": character], from: releaseBase,
                                                  supportFallback: releaseBase, importMode: .releaseLeaf)

        XCTAssertEqual(releaseGeneration.legacyAggregateOverlayIDs, [person])
        XCTAssertEqual(try Data(contentsOf: releaseGeneration.directory.appendingPathComponent("legacy_aggregates/person.sud")),
                       aggregateData)
        XCTAssertEqual(try Data(contentsOf: releaseGeneration.directory.appendingPathComponent("character.sud")),
                       Data("new release character".utf8))
        XCTAssertEqual(store.loadCurrent()?.generation, releaseGeneration.generation)
    }

    func testTypedLegacyAggregateUsesSeparateNamespaceBesideSameNamedReleaseLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", "character.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let character = incoming.appendingPathComponent("character.sud")
        try Data("legacy character aggregate".utf8).write(to: character)
        let legacyCharacter = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "character")
        let first = try store.publish(importedFiles: [:], from: base, supportFallback: base,
                                      legacyAggregateOverlays: [legacyCharacter: character],
                                      importMode: .typedLegacyAggregate)

        XCTAssertEqual(first.legacyAggregateOverlayIDs, [legacyCharacter])
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("character.sud")),
                       Data("character.sud".utf8))
        XCTAssertEqual(try Data(contentsOf: first.directory.appendingPathComponent("legacy_aggregates/character.sud")),
                       Data("legacy character aggregate".utf8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: first.directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["legacy_aggregate_overlay_ids"] as? [String], ["character"])
        let hashes = try XCTUnwrap(manifest["output_sha256"] as? [String: String])
        XCTAssertNotNil(hashes["legacy_aggregates/character.sud"])
        XCTAssertEqual(store.loadCurrent()?.legacyAggregateOverlayIDs, [legacyCharacter])
    }

    func testTypedLegacyAggregateSurvivesRepublishAndPointerRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = incoming.appendingPathComponent("person.sud")
        try Data("legacy person aggregate".utf8).write(to: person)
        let legacyPerson = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let first = try store.publish(importedFiles: [:], from: base, supportFallback: base,
                                      legacyAggregateOverlays: [legacyPerson: person],
                                      importMode: .typedLegacyAggregate)
        let system = incoming.appendingPathComponent("system.sud")
        try Data("updated system".utf8).write(to: system)
        let second = try store.publish(importedFiles: ["system.sud": system], from: first.directory,
                                       importMode: .typedLegacyAggregate)

        XCTAssertEqual(second.legacyAggregateOverlayIDs, [legacyPerson])
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent("legacy_aggregates/person.sud")),
                       Data("legacy person aggregate".utf8))
        XCTAssertEqual(store.loadCurrent()?.legacyAggregateOverlayIDs, [legacyPerson])
        try Data("interrupted pointer".utf8).write(to: store.directory.appendingPathComponent("current.json"), options: .atomic)
        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.legacyAggregateOverlayIDs, [legacyPerson])
    }

    func testCorruptLegacyAggregateOverlayFallsBackToPreviousGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = incoming.appendingPathComponent("person.sud")
        try Data("legacy person aggregate".utf8).write(to: person)
        let legacyPerson = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let first = try store.publish(importedFiles: [:], from: base, supportFallback: base,
                                      legacyAggregateOverlays: [legacyPerson: person],
                                      importMode: .typedLegacyAggregate)
        let system = incoming.appendingPathComponent("system.sud")
        try Data("updated system".utf8).write(to: system)
        let second = try store.publish(importedFiles: ["system.sud": system], from: first.directory,
                                       importMode: .typedLegacyAggregate)

        try Data("corrupt overlay".utf8).write(
            to: second.directory.appendingPathComponent("legacy_aggregates/person.sud"), options: .atomic)

        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.legacyAggregateOverlayIDs, [legacyPerson])
        XCTAssertEqual(try Data(contentsOf: recovered.directory.appendingPathComponent("legacy_aggregates/person.sud")),
                       Data("legacy person aggregate".utf8))
    }

    func testTypedAggregateRejectsUnknownIDsAndPreservesUnmarkedLegacyBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyBase = root.appendingPathComponent("legacy-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: legacyBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud"] {
            try Data(name.utf8).write(to: legacyBase.appendingPathComponent(name))
        }
        let activeLegacyLeaf = Data("active legacy person leaf".utf8)
        try activeLegacyLeaf.write(to: legacyBase.appendingPathComponent("person.sud"))
        let aggregate = incoming.appendingPathComponent("person.sud")
        let aggregateData = Data("legacy person aggregate".utf8)
        try aggregateData.write(to: aggregate)
        let unknown = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "../escape")
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        XCTAssertThrowsError(try store.publish(importedFiles: [:], from: legacyBase,
                                               legacyAggregateOverlays: [unknown: aggregate],
                                               importMode: .typedLegacyAggregate))
        XCTAssertNil(store.loadCurrent())

        XCTAssertThrowsError(try store.publish(importedFiles: ["person.sud": aggregate], from: legacyBase,
                                               importMode: .typedLegacyAggregate))
        XCTAssertNil(store.loadCurrent())

        let releaseOnly = incoming.appendingPathComponent("shrine.sud")
        try Data("release-only leaf".utf8).write(to: releaseOnly)
        XCTAssertThrowsError(try store.publish(
            importedFiles: ["facility/religious/shrine.sud": releaseOnly], from: legacyBase,
            importMode: .typedLegacyAggregate))
        XCTAssertNil(store.loadCurrent())

        let active = try store.publish(importedFiles: [:], from: legacyBase)
        let published = try store.publish(importedFiles: [:], from: active.directory,
                                          legacyAggregateOverlays: [person: aggregate],
                                          importMode: .typedLegacyAggregate)

        XCTAssertEqual(published.legacyAggregateOverlayIDs, [person])
        XCTAssertEqual(try Data(contentsOf: published.directory.appendingPathComponent("person.sud")), activeLegacyLeaf)
        XCTAssertEqual(try Data(contentsOf: published.directory.appendingPathComponent("legacy_aggregates/person.sud")),
                       aggregateData)
        XCTAssertEqual(store.loadCurrent()?.generation, published.generation)
        XCTAssertEqual(store.loadCurrent()?.legacyAggregateOverlayIDs, [person])
    }

    func testManifestWithoutLegacyOverlayFieldLoadsAsNoOverlays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let generation = try store.publish(importedFiles: [:], from: base, supportFallback: base)

        let manifestURL = generation.directory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest.removeValue(forKey: "legacy_aggregate_overlay_ids")
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)

        let pointerURL = store.directory.appendingPathComponent("current.json")
        var pointer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as? [String: Any])
        pointer["manifest_sha256"] = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: pointer, options: [.sortedKeys]).write(to: pointerURL, options: .atomic)

        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(loaded.generation, generation.generation)
        XCTAssertEqual(loaded.legacyAggregateOverlayIDs, [])
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


    func testLoadedSourceSelectionSeparatesCompleteAggregateFromReleaseLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let personLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("person") }
            .map(\.id)
        let facilityLeaf = try XCTUnwrap(DictionaryCategoryCatalog.categories
            .first { $0.legacyFamilies == ["facility"] }?.id)
        XCTAssertFalse(personLeaves.isEmpty)

        let aggregate = incoming.appendingPathComponent("person.sud")
        let aggregateData = Data("person family aggregate".utf8)
        try aggregateData.write(to: aggregate)
        let releaseLeaf = incoming.appendingPathComponent(facilityLeaf + ".sud")
        try FileManager.default.createDirectory(
            at: releaseLeaf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("single facility leaf".utf8).write(to: releaseLeaf)

        let baseline = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let releaseGeneration = try store.publish(
            importedFiles: [facilityLeaf + ".sud": releaseLeaf],
            from: baseline.directory,
            importMode: .releaseLeaf
        )
        let published = try store.publish(
            importedFiles: [:],
            from: releaseGeneration.directory,
            legacyAggregateOverlays: [person: aggregate],
            importMode: .typedLegacyAggregate
        )
        let loaded = try XCTUnwrap(store.loadCurrent())
        let selection = loaded.resolveSourceSelection(for: personLeaves + [facilityLeaf])

        XCTAssertEqual(selection.releaseLeafIDs, [facilityLeaf])
        XCTAssertEqual(selection.legacyAggregateSources.map(\.id), [person])
        XCTAssertEqual(selection.legacyAggregateSources.map(\.fileURL), [
            published.directory.appendingPathComponent("legacy_aggregates/person.sud")
        ])
        XCTAssertEqual(selection.unavailableCategoryIDs, [])
    }

    func testSourceSelectionReportsMissingAndUnknownCategoriesAndFailsClosedWithoutMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let releaseBase = root.appendingPathComponent("release-base", isDirectory: true)
        let legacyBase = root.appendingPathComponent("legacy-base", isDirectory: true)
        let releaseStore = DictionaryGenerationStore(directory: root.appendingPathComponent("release-store", isDirectory: true))
        let legacyStore = DictionaryGenerationStore(directory: root.appendingPathComponent("legacy-store", isDirectory: true))
        try FileManager.default.createDirectory(at: releaseBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: releaseBase.appendingPathComponent(name))
        }
        for name in ["system.sud", "connection.sud"] {
            try Data(name.utf8).write(to: legacyBase.appendingPathComponent(name))
        }
        let facilityLeaf = try XCTUnwrap(DictionaryCategoryCatalog.categories
            .first { $0.legacyFamilies == ["facility"] }?.id)
        let unknownID = "unknown/category"
        let selected = [facilityLeaf, unknownID]

        let releaseGeneration = try releaseStore.publish(importedFiles: [:], from: releaseBase,
                                                        supportFallback: releaseBase)
        let releaseSelection = try XCTUnwrap(releaseStore.loadCurrent())
            .resolveSourceSelection(for: selected)
        XCTAssertEqual(releaseSelection.releaseLeafIDs, [])
        XCTAssertEqual(releaseSelection.legacyAggregateSources, [])
        XCTAssertEqual(releaseSelection.unavailableCategoryIDs, selected)

        let legacyGeneration = try legacyStore.publish(importedFiles: [:], from: legacyBase)
        let legacySelection = try XCTUnwrap(legacyStore.loadCurrent())
            .resolveSourceSelection(for: selected)
        XCTAssertEqual(legacySelection.releaseLeafIDs, [])
        XCTAssertEqual(legacySelection.legacyAggregateSources, [])
        XCTAssertEqual(legacySelection.unavailableCategoryIDs, selected)
        XCTAssertEqual(legacyGeneration.legacyAggregateOverlayIDs, [])
        XCTAssertNotEqual(releaseGeneration.generation, legacyGeneration.generation)
    }

    func testUnmanifestedReleaseMarkerDoesNotClassifyAmbiguousLegacyRootFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("legacy-base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", "character.sud"] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let published = try store.publish(importedFiles: [:], from: base)
        let unmanifestedMarker = published.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker)
        try Data().write(to: unmanifestedMarker)

        let loaded = try XCTUnwrap(store.loadCurrent())
        let selection = loaded.resolveSourceSelection(for: ["character"])

        XCTAssertFalse(loaded.hasVerifiedReleaseMarker)
        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, ["character"])
    }

    func testUnmanifestedReleaseMarkerIsNotPromotedWhenRepublishingGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("legacy-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", "character.sud"] {
            try Data(("legacy " + name).utf8).write(to: base.appendingPathComponent(name))
        }
        let first = try store.publish(importedFiles: [:], from: base)
        try Data().write(to: first.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        XCTAssertFalse(try XCTUnwrap(store.loadCurrent()).hasVerifiedReleaseMarker)

        let updatedSystem = incoming.appendingPathComponent("system.sud")
        try Data("updated legacy system".utf8).write(to: updatedSystem)
        let republished = try store.publish(importedFiles: ["system.sud": updatedSystem], from: first.directory)
        let loaded = try XCTUnwrap(store.loadCurrent())
        let selection = loaded.resolveSourceSelection(for: ["character"])

        XCTAssertEqual(loaded.generation, republished.generation)
        XCTAssertFalse(loaded.hasVerifiedReleaseMarker)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: republished.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path))
        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, ["character"])
    }

    func testUnmanifestedReleaseMarkerRejectsReleaseLeafImportWithoutReplacingGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("legacy-base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyCharacter = Data("legacy character aggregate".utf8)
        try Data("legacy system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("legacy connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try legacyCharacter.write(to: base.appendingPathComponent("character.sud"))
        let current = try store.publish(importedFiles: [:], from: base)
        try Data().write(to: current.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        XCTAssertFalse(try XCTUnwrap(store.loadCurrent()).hasVerifiedReleaseMarker)

        let importedLeaf = incoming.appendingPathComponent("character.sud")
        try Data("untrusted release leaf".utf8).write(to: importedLeaf)
        XCTAssertThrowsError(try store.publish(importedFiles: ["character.sud": importedLeaf],
                                               from: current.directory, importMode: .releaseLeaf))

        XCTAssertEqual(store.loadCurrent()?.generation, current.generation)
        XCTAssertEqual(try Data(contentsOf: current.directory.appendingPathComponent("character.sud")),
                       legacyCharacter)
    }

    func testCharacterFamilyAggregateSubstitutesItsMappedReleaseLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("character") }
            .map(\.id)
        XCTAssertEqual(selectedLeaves, ["character"])
        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        for id in selectedLeaves {
            let leaf = base.appendingPathComponent(id + ".sud")
            try FileManager.default.createDirectory(
                at: leaf.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("release leaf " + id).utf8).write(to: leaf)
        }
        let aggregate = incoming.appendingPathComponent("character.sud")
        try Data("character family aggregate".utf8).write(to: aggregate)
        let character = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "character")

        let baseline = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let published = try store.publish(
            importedFiles: [:], from: baseline.directory,
            legacyAggregateOverlays: [character: aggregate],
            importMode: .typedLegacyAggregate
        )
        let selection = try XCTUnwrap(store.loadCurrent()).resolveSourceSelection(for: selectedLeaves)

        XCTAssertEqual(published.legacyAggregateOverlayIDs, [character])
        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources.map(\.id), [character])
        XCTAssertEqual(selection.unavailableCategoryIDs, [])
    }

    func testDirectDemographicReleaseLeafDoesNotRouteThroughCharacterAggregate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let selectedLeaf = "media_demographic/audience/shonen"
        let releaseLeaf = base.appendingPathComponent(selectedLeaf + ".sud")
        try FileManager.default.createDirectory(
            at: releaseLeaf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("direct release leaf".utf8).write(to: releaseLeaf)
        let character = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "character")
        let aggregate = incoming.appendingPathComponent("character.sud")
        try Data("partial character aggregate".utf8).write(to: aggregate)

        let baseline = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let published = try store.publish(
            importedFiles: [:], from: baseline.directory,
            legacyAggregateOverlays: [character: aggregate],
            importMode: .typedLegacyAggregate
        )
        let selection = try XCTUnwrap(store.loadCurrent()).resolveSourceSelection(for: [selectedLeaf])

        XCTAssertEqual(published.legacyAggregateOverlayIDs, [character])
        XCTAssertEqual(selection.releaseLeafIDs, [selectedLeaf])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, [])
    }

    func testSourceSelectionDoesNotExposeCorruptAggregateAfterGenerationRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let personLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("person") }
            .map(\.id)
        let aggregate = incoming.appendingPathComponent("person.sud")
        try Data("valid person aggregate".utf8).write(to: aggregate)

        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let withAggregate = try store.publish(
            importedFiles: [:], from: previous.directory,
            legacyAggregateOverlays: [person: aggregate],
            importMode: .typedLegacyAggregate
        )
        try Data("corrupt aggregate".utf8).write(
            to: withAggregate.directory.appendingPathComponent("legacy_aggregates/person.sud"),
            options: .atomic
        )

        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, previous.generation)
        let selection = recovered.resolveSourceSelection(for: personLeaves)

        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, personLeaves)
    }

    func testSourceSelectionDoesNotExposeMissingAggregateAfterGenerationRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let personLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("person") }
            .map(\.id)
        let aggregate = incoming.appendingPathComponent("person.sud")
        try Data("person aggregate".utf8).write(to: aggregate)

        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let withAggregate = try store.publish(
            importedFiles: [:], from: previous.directory,
            legacyAggregateOverlays: [person: aggregate],
            importMode: .typedLegacyAggregate
        )
        try FileManager.default.removeItem(
            at: withAggregate.directory.appendingPathComponent("legacy_aggregates/person.sud")
        )

        let recovered = try XCTUnwrap(store.loadCurrent())
        let selection = recovered.resolveSourceSelection(for: personLeaves)

        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertEqual(recovered.generation, previous.generation)
        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, personLeaves)
    }

    func testSourceSelectionRejectsAggregateChangedAfterLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let person = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "person")
        let personLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("person") }
            .map(\.id)
        let aggregate = incoming.appendingPathComponent("person.sud")
        try Data("valid person aggregate".utf8).write(to: aggregate)

        let baseline = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let published = try store.publish(
            importedFiles: [:], from: baseline.directory,
            legacyAggregateOverlays: [person: aggregate],
            importMode: .typedLegacyAggregate
        )
        let loaded = try XCTUnwrap(store.loadCurrent())
        let aggregateURL = published.directory.appendingPathComponent("legacy_aggregates/person.sud")
        try Data("changed after load".utf8).write(to: aggregateURL, options: .atomic)

        let selection = loaded.resolveSourceSelection(for: personLeaves)

        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, personLeaves)
    }

    func testSourceSelectionRejectsReleaseLeafChangedAfterLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedLeaf = "media_demographic/audience/shonen"
        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let leafURL = base.appendingPathComponent(selectedLeaf + ".sud")
        try FileManager.default.createDirectory(
            at: leafURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("valid release leaf".utf8).write(to: leafURL)

        let published = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(loaded.resolveSourceSelection(for: [selectedLeaf]).releaseLeafIDs, [selectedLeaf])

        try Data("changed after load".utf8).write(
            to: published.directory.appendingPathComponent(selectedLeaf + ".sud"), options: .atomic)
        let selection = loaded.resolveSourceSelection(for: [selectedLeaf])

        XCTAssertEqual(selection.releaseLeafIDs, [])
        XCTAssertEqual(selection.legacyAggregateSources, [])
        XCTAssertEqual(selection.unavailableCategoryIDs, [selectedLeaf])
    }
    func testManifestedReleaseMarkerCorruptionFallsBackToPreviousGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(file.utf8).write(to: base.appendingPathComponent(file))
        }
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let current = try store.publish(importedFiles: [:], from: previous.directory)
        XCTAssertTrue(try XCTUnwrap(store.loadCurrent()).hasVerifiedReleaseMarker)
        try Data("corrupted marker".utf8).write(to: current.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let recovered = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(recovered.generation, previous.generation)
        XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertTrue(recovered.hasVerifiedReleaseMarker)
        XCTAssertEqual(store.loadCandidates().map(\.generation), [previous.generation])
    }
    func testLoadedSourceSelectionRevalidatesMarkerAndManifestProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(name.utf8).write(to: base.appendingPathComponent(name))
        }
        let aggregate = root.appendingPathComponent("person.sud")
        try Data("person aggregate".utf8).write(to: aggregate)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let published = try store.publish(importedFiles: [:], from: base, supportFallback: base,
            legacyAggregateOverlays: [.init(rawValue: "person"): aggregate], importMode: .typedLegacyAggregate)
        let reloaded = try XCTUnwrap(store.loadCurrent())
        let ids = DictionaryCategoryCatalog.categories.filter { $0.legacyFamilies.contains("person") }.map(\.id)
        for snapshot in [published, reloaded] {
            for name in [DictionaryCategoryCatalog.releaseMarker, "manifest.json"] {
                let url = published.directory.appendingPathComponent(name)
                let bytes = try Data(contentsOf: url)
                let symlinkTarget = root.appendingPathComponent("saved-" + name)
                try bytes.write(to: symlinkTarget)
                for mutation in 0..<4 {
                    try FileManager.default.removeItem(at: url)
                    switch mutation {
                    case 0: try Data("changed bytes".utf8).write(to: url)
                    case 1: break // Missing file.
                    case 2: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    default: try FileManager.default.createSymbolicLink(at: url, withDestinationURL: symlinkTarget)
                    }
                    XCTAssertFalse(snapshot.hasCurrentVerifiedReleaseProvenance, "\(name), mutation \(mutation)")
                    let selection = snapshot.resolveSourceSelection(for: ids)
                    XCTAssertTrue(selection.legacyAggregateSources.isEmpty)
                    XCTAssertTrue(selection.releaseLeafIDs.isEmpty)
                    XCTAssertEqual(selection.unavailableCategoryIDs, ids)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    try bytes.write(to: url)
                    XCTAssertTrue(snapshot.hasCurrentVerifiedReleaseProvenance)
                    XCTAssertEqual(snapshot.resolveSourceSelection(for: ids).legacyAggregateSources.map { $0.id.rawValue }, ["person"])
                }
            }
        }
    }

}
