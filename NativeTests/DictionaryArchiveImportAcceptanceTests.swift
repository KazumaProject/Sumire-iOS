import XCTest
import CryptoKit
import SumireCore
@testable import Sumire

final class DictionaryArchiveImportAcceptanceTests: XCTestCase {
    private struct NativeManifest: Decodable {
        let sourceRevision: String
        let outputSHA256: [String: String]

        enum CodingKeys: String, CodingKey {
            case sourceRevision = "source_revision"
            case outputSHA256 = "output_sha256"
        }
    }

    private enum FixtureError: Error {
        case invalidNativeGeneration
        case unexpectedValidation
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sumire-import-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeSupportDictionary(at root: URL) throws -> URL {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let files = [
            "system.sud", "connection.sud", "standalone.sud", "reading_correction.sud",
            "system_ngram.dat", "system_ngram_unigram.dat",
            "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat",
            "single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"
        ]
        for relativePath in files {
            let file = support.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("support fixture: \(relativePath)".utf8).write(to: file)
        }
        return support
    }

    private func makeStore(container: URL) -> DictionaryGenerationStore {
        DictionaryGenerationStore(directory: container.appendingPathComponent("Sumire/Dictionaries", isDirectory: true))
    }

    private func makeOutputDirectory(at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    private func emptyStoredZIP(entryName: String) -> Data {
        let name = Data(entryName.utf8)
        var archive = Data()
        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32, to data: inout Data) {
            append16(UInt16(truncatingIfNeeded: value), to: &data)
            append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        }

        append32(0x0403_4b50, to: &archive)
        append16(20, to: &archive) // version needed
        append16(0, to: &archive) // flags
        append16(0, to: &archive) // stored, no compression
        append16(0, to: &archive) // modification time
        append16(0, to: &archive) // modification date
        append32(0, to: &archive) // CRC-32 of empty payload
        append32(0, to: &archive) // compressed size
        append32(0, to: &archive) // uncompressed size
        append16(UInt16(name.count), to: &archive)
        append16(0, to: &archive) // extra length
        archive.append(name)

        let centralOffset = UInt32(archive.count)
        append32(0x0201_4b50, to: &archive)
        append16(20, to: &archive) // version made by
        append16(20, to: &archive) // version needed
        append16(0, to: &archive) // flags
        append16(0, to: &archive) // stored, no compression
        append16(0, to: &archive) // modification time
        append16(0, to: &archive) // modification date
        append32(0, to: &archive) // CRC-32 of empty payload
        append32(0, to: &archive) // compressed size
        append32(0, to: &archive) // uncompressed size
        append16(UInt16(name.count), to: &archive)
        append16(0, to: &archive) // extra length
        append16(0, to: &archive) // comment length
        append16(0, to: &archive) // disk number
        append16(0, to: &archive) // internal attributes
        append32(0, to: &archive) // external attributes
        append32(0, to: &archive) // local header offset
        archive.append(name)

        let centralSize = UInt32(archive.count) - centralOffset
        append32(0x0605_4b50, to: &archive)
        append16(0, to: &archive) // disk number
        append16(0, to: &archive) // central directory disk
        append16(1, to: &archive) // entries on this disk
        append16(1, to: &archive) // total entries
        append32(centralSize, to: &archive)
        append32(centralOffset, to: &archive)
        append16(0, to: &archive) // comment length
        return archive
    }

    func testPinnedAndroidArchiveStoresTypedAggregatesWithoutActivatingThemWhenConfigured() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_SOURCE_ZIP"],
              !archivePath.isEmpty,
              let nativePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_NATIVE_DICTIONARIES"],
              !nativePath.isEmpty else {
            throw XCTSkip("Set SUMIRE_REFERENCE_SOURCE_ZIP and SUMIRE_REFERENCE_NATIVE_DICTIONARIES for pinned importer acceptance")
        }

        let archive = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
        XCTAssertEqual(Self.sha256(archiveData), "45f3078272be30c936af389d44c8df6fb2cda565ea490b21c12afa1016d8bd54")
        let nativeDirectory = URL(fileURLWithPath: nativePath, isDirectory: true)
        let manifestData = try Data(contentsOf: nativeDirectory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(Self.sha256(manifestData), "60f44627887e96ef2618d90571234853e89ec193a0b23c2d0f8ab54ce2265f46")
        let manifest = try JSONDecoder().decode(NativeManifest.self, from: manifestData)
        XCTAssertEqual(manifest.sourceRevision, "df1f38315bf56d860d32919a3eaed6a75499e91e")
        XCTAssertEqual(manifest.outputSHA256.count, 44)

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseContainer = root.appendingPathComponent("release-app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseContainer, withIntermediateDirectories: false)
        let releaseOutcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: releaseContainer,
            categoryInterpretation: .releaseLeaf,
            storeImportMode: .releaseLeaf,
            bundledSupport: nativeDirectory)
        XCTAssertFalse(releaseOutcome.succeeded)
        XCTAssertTrue(releaseOutcome.message.contains("release分類"), releaseOutcome.message)
        XCTAssertNil(makeStore(container: releaseContainer).loadCurrent())

        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .legacyAggregate,
            storeImportMode: .typedLegacyAggregate,
            bundledSupport: nativeDirectory)

        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertEqual(outcome.convertedFiles.count, 9)
        XCTAssertEqual(Set(outcome.storedLegacyAggregateIDs), Set(DictionaryCategoryCatalog.legacyIDs))
        let loaded = try XCTUnwrap(makeStore(container: container).loadCurrent())
        XCTAssertFalse(loaded.hasVerifiedReleaseMarker,
                       "The unmarked Android base does not prove release taxonomy, so aggregates must stay inactive")
        let selection = loaded.resolveSourceSelection(for: DictionaryCategoryCatalog.ids)
        XCTAssertTrue(selection.releaseLeafIDs.isEmpty)
        XCTAssertTrue(selection.legacyAggregateSources.isEmpty)
        XCTAssertEqual(Set(selection.unavailableCategoryIDs), Set(DictionaryCategoryCatalog.ids))
        for (name, expectedHash) in manifest.outputSHA256.sorted(by: { $0.key < $1.key }) {
            let id = String(name.dropLast(".sud".count))
            let relativePath = DictionaryCategoryCatalog.legacyIDs.contains(id)
                ? "legacy_aggregates/\(name)"
                : name
            let file = loaded.directory.appendingPathComponent(relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Published native output is missing: \(name)")
            XCTAssertEqual(Self.sha256(try Data(contentsOf: file, options: .mappedIfSafe)), expectedHash, name)
        }
    }

    func testReleaseLeafReimportWithStoredAggregateRemainsSuccessful() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        try Data("v1.7.277\n".utf8).write(to: support.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let aggregate = root.appendingPathComponent("address-aggregate.sud")
        try Data("legacy addresses".utf8).write(to: aggregate)
        _ = try store.publish(importedFiles: [:], from: support, supportFallback: support,
            legacyAggregateOverlays: [.init(rawValue: "address"): aggregate], importMode: .typedLegacyAggregate)
        let archive = root.appendingPathComponent("release.zip")
        try Data("synthetic input".utf8).write(to: archive)
        let replacement = Data("new release addresses".utf8)
        let outcome = DictionaryArchiveImporter.perform(archive: archive, sharedContainer: container,
            categoryInterpretation: .releaseLeaf, storeImportMode: .releaseLeaf, bundledSupport: support,
            converter: { _, destination, _ in
                try self.makeOutputDirectory(at: destination)
                let file = destination.appendingPathComponent("address.sud")
                try replacement.write(to: file)
                return DictionaryArchiveImportConversion(outputDirectory: destination,
                    importedFiles: ["address.sud": file], legacyAggregateOverlays: [:], convertedFiles: ["address.sud"])
            }, validator: { _ in })
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("address.sud")), replacement)
        XCTAssertEqual(loaded.legacyAggregateOverlayIDs.map(\.rawValue), ["address"])
        XCTAssertEqual(loaded.resolveSourceSelection(for: ["address"]).legacyAggregateSources.map { $0.id.rawValue }, ["address"])
        XCTAssertEqual(loaded.resolveSourceSelection(for: ["address"], allowingLegacyAggregates: false).releaseLeafIDs, ["address"])
        XCTAssertTrue(outcome.succeeded, outcome.message)
    }

    func testReleaseLeafImportPublishesReleaseTaxonomyGeneration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("release.zip")
        try Data("synthetic converter input".utf8).write(to: archive)
        let categoryID = "facility/religious/shrine"
        let relativeFile = categoryID + ".sud"
        let releaseBytes = Data("converted release leaf".utf8)

        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .releaseLeaf,
            storeImportMode: .releaseLeaf,
            bundledSupport: support,
            converter: { _, destination, interpretation in
                XCTAssertEqual(interpretation, .releaseLeaf)
                try self.makeOutputDirectory(at: destination)
                let output = destination.appendingPathComponent(relativeFile)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try releaseBytes.write(to: output)
                return DictionaryArchiveImportConversion(
                    outputDirectory: destination,
                    importedFiles: [relativeFile: output],
                    legacyAggregateOverlays: [:],
                    convertedFiles: [relativeFile])
            },
            validator: { directory in
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.sud").path),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent("connection.sud").path) else {
                    throw FixtureError.invalidNativeGeneration
                }
            })

        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertEqual(outcome.convertedFiles, [relativeFile])
        XCTAssertTrue(outcome.storedLegacyAggregateIDs.isEmpty)
        let loaded = try XCTUnwrap(makeStore(container: container).loadCurrent())
        XCTAssertTrue(loaded.hasVerifiedReleaseMarker)
        XCTAssertEqual(loaded.resolveSourceSelection(for: [categoryID]).releaseLeafIDs, [categoryID])
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent(relativeFile)), releaseBytes)
    }

    func testReleaseLeafImportRejectsInvalidDemographicNativeDictionaryWithoutReplacingCurrentGeneration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try XCTUnwrap(ConversionService.bundledDictionary)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let baseline = try store.publish(
            importedFiles: [:], from: support, supportFallback: support, importMode: .releaseLeaf)
        XCTAssertTrue(baseline.hasVerifiedReleaseMarker)
        let baselineSystem = try Data(contentsOf: baseline.directory.appendingPathComponent("system.sud"))

        let archive = root.appendingPathComponent("demographic.zip")
        try Data("synthetic converter input".utf8).write(to: archive)
        let categoryID = "media_demographic/audience/shonen"
        let relativeFile = categoryID + ".sud"
        let invalidDictionary = Data("not a native dictionary".utf8)
        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .releaseLeaf,
            storeImportMode: .releaseLeaf,
            bundledSupport: support,
            converter: { _, destination, interpretation in
                XCTAssertEqual(interpretation, .releaseLeaf)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let output = destination.appendingPathComponent(relativeFile)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try invalidDictionary.write(to: output)
                return DictionaryArchiveImportConversion(
                    outputDirectory: destination,
                    importedFiles: [relativeFile: output],
                    legacyAggregateOverlays: [:],
                    convertedFiles: [relativeFile])
            })

        XCTAssertFalse(outcome.succeeded, outcome.message)
        let current = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(current.generation, baseline.generation)
        XCTAssertEqual(try Data(contentsOf: current.directory.appendingPathComponent("system.sud")), baselineSystem)
        let generationDirectories = try FileManager.default.contentsOfDirectory(
            at: store.directory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("generation-") }
        XCTAssertEqual(Set(generationDirectories.map(\.lastPathComponent)), [baseline.generation])
    }

    func testLegacyAggregateImportStoresTypedOverlayWithoutReplacingSameNamedReleaseFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let id = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: "character")
        let releaseBytes = Data("release character leaf".utf8)
        let aggregateBytes = Data("legacy character aggregate".utf8)
        let initial = root.appendingPathComponent("character.sud")
        try releaseBytes.write(to: initial)
        let baseline = try store.publish(
            importedFiles: ["character.sud": initial],
            from: support,
            supportFallback: support,
            importMode: .releaseLeaf)

        let archive = root.appendingPathComponent("legacy.zip")
        try Data("synthetic converter input".utf8).write(to: archive)
        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .legacyAggregate,
            storeImportMode: .typedLegacyAggregate,
            bundledSupport: support,
            converter: { _, destination, interpretation in
                XCTAssertEqual(interpretation, .legacyAggregate)
                try self.makeOutputDirectory(at: destination)
                let overlay = destination.appendingPathComponent("legacy_aggregates/character.sud")
                try FileManager.default.createDirectory(
                    at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
                try aggregateBytes.write(to: overlay)
                return DictionaryArchiveImportConversion(
                    outputDirectory: destination,
                    importedFiles: [:],
                    legacyAggregateOverlays: [id: overlay],
                    convertedFiles: ["legacy_aggregates/character.sud"])
            },
            validator: { directory in
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.sud").path),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent("connection.sud").path) else {
                    throw FixtureError.invalidNativeGeneration
                }
            })

        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertTrue(outcome.convertedFiles.isEmpty, "A typed aggregate must not be reported as an active release file")
        XCTAssertEqual(outcome.storedLegacyAggregateIDs, ["character"])
        XCTAssertTrue(outcome.message.contains("現在のキーボード変換には使われません"))
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertNotEqual(loaded.generation, baseline.generation)
        XCTAssertEqual(loaded.legacyAggregateOverlayIDs, [id])
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("character.sud")), releaseBytes)
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("legacy_aggregates/character.sud")), aggregateBytes)
    }

    func testLegacyAggregateImportRejectsReleaseOnlyDemographicIDsWithoutReplacingCurrentGeneration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let baseline = try store.publish(importedFiles: [:], from: support)
        let baselineSystem = try Data(contentsOf: baseline.directory.appendingPathComponent("system.sud"))
        let demographicIDs = DictionaryCategoryCatalog.categories
            .map(\.id)
            .filter { $0.hasPrefix("media_demographic/") }
        XCTAssertEqual(demographicIDs.count, 8)

        for (index, id) in demographicIDs.enumerated() {
            let archive = root.appendingPathComponent("demographic-\(index).zip")
            try emptyStoredZIP(entryName: "categories/\(id)/yomi.dat.zip").write(to: archive)

            let outcome = DictionaryArchiveImporter.perform(
                archive: archive,
                sharedContainer: container,
                categoryInterpretation: .legacyAggregate,
                storeImportMode: .typedLegacyAggregate,
                bundledSupport: support)

            XCTAssertFalse(outcome.succeeded, id)
            XCTAssertTrue(outcome.message.contains("旧分類辞書の集約IDとして扱えない分類パス"), outcome.message)
            XCTAssertTrue(outcome.message.contains(id), outcome.message)
            let current = try XCTUnwrap(store.loadCurrent())
            XCTAssertEqual(current.generation, baseline.generation, id)
            XCTAssertEqual(
                try Data(contentsOf: current.directory.appendingPathComponent("system.sud")),
                baselineSystem,
                id)
            let generationDirectories = try FileManager.default.contentsOfDirectory(
                at: store.directory,
                includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("generation-") }
                .map(\.lastPathComponent)
            XCTAssertEqual(Set(generationDirectories), Set([baseline.generation]), id)
        }
    }

    func testInvalidZipLeavesCurrentGenerationUnchanged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let baseline = try store.publish(importedFiles: [:], from: support)
        let archive = root.appendingPathComponent("invalid.zip")
        try Data("not a ZIP archive".utf8).write(to: archive)

        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .releaseLeaf,
            storeImportMode: .releaseLeaf,
            bundledSupport: support,
            validator: { _ in throw FixtureError.unexpectedValidation })

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(store.loadCurrent()?.generation, baseline.generation)
    }

    func testPublicationValidationFailureLeavesCurrentGenerationUnchanged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeSupportDictionary(at: root)
        let container = root.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let store = makeStore(container: container)
        let baseline = try store.publish(importedFiles: [:], from: support)
        let archive = root.appendingPathComponent("replacement.zip")
        try Data("synthetic converter input".utf8).write(to: archive)
        let replacement = Data("replacement system dictionary".utf8)
        var validationCount = 0

        let outcome = DictionaryArchiveImporter.perform(
            archive: archive,
            sharedContainer: container,
            categoryInterpretation: .releaseLeaf,
            storeImportMode: .releaseLeaf,
            bundledSupport: support,
            converter: { _, destination, _ in
                try self.makeOutputDirectory(at: destination)
                let output = destination.appendingPathComponent("system.sud")
                try replacement.write(to: output)
                return DictionaryArchiveImportConversion(
                    outputDirectory: destination,
                    importedFiles: ["system.sud": output],
                    legacyAggregateOverlays: [:],
                    convertedFiles: ["system.sud"])
            },
            validator: { _ in
                validationCount += 1
                if validationCount == 2 { throw FixtureError.invalidNativeGeneration }
            })

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(store.loadCurrent()?.generation, baseline.generation)
        XCTAssertEqual(try Data(contentsOf: baseline.directory.appendingPathComponent("system.sud")),
                       Data("support fixture: system.sud".utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
