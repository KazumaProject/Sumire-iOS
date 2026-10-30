import XCTest
import SumireCore
@testable import Sumire

final class TypedAggregateRuntimeIntegrationTests: XCTestCase {
    private func packed<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data()
        for value in values { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        return data
    }
    private func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }
    private func file(kind: UInt32, dimension: UInt32, sections: [Data]) -> Data {
        var directory = Data(), body = Data(), offset = 24 + 24 * sections.count
        for section in sections {
            let padding = (8 - offset % 8) % 8
            body.append(Data(repeating: 0, count: padding)); offset += padding
            directory.append(packed([UInt64(offset), UInt64(section.count)]))
            directory.append(packed([crc(section), UInt32(0)]))
            body.append(section); offset += section.count
        }
        return Data("SUMIRE01".utf8) + packed([UInt32(1), kind, UInt32(sections.count), dimension]) + directory + body
    }
    private func dictionary(_ text: String, cost: Int16 = 0) -> Data {
        let textBytes = Data(text.utf8)
        return file(kind: 1, dimension: 0, sections: [
            packed([UInt64(5)]), packed([UInt16(32), 32, 0x3042]), packed([UInt64(4)]),
            packed([UInt32(1)]), packed([UInt32(0), 0, 1]), packed([UInt16(0)]),
            packed([cost]), packed([UInt32(0)]), packed([UInt32(0), UInt32(textBytes.count)]), textBytes
        ])
    }
    private func makeBase(_ root: URL) throws -> URL {
        let base = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let connection = file(kind: 2, dimension: 1, sections: [
            packed([UInt16(0)]), packed([UInt16(0)]), packed([Int16(0)]), packed([UInt64(0)]),
            Data(), packed([UInt32(0), 0]), packed([UInt16(0)])
        ])
        try connection.write(to: base.appendingPathComponent("connection.sud"))
        try dictionary("基準", cost: 30_000).write(to: base.appendingPathComponent("system.sud"))
        try Data("v1.7.277\n".utf8).write(to: base.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        for id in personLeaves {
            try dictionary("葉候補").write(to: base.appendingPathComponent(id + ".sud"))
        }
        return base
    }
    private var personLeaves: [String] {
        DictionaryCategoryCatalog.categories.filter { $0.legacyFamilies.contains("person") }.map(\.id)
    }
    private func convert(_ source: DictionaryGenerationStore.Loaded, ids: [String]) throws -> ConversionResponse {
        try convert(sources: [NativeDictionaryEngineSource(generation: source)], ids: ids)
    }
    private func convert(sources: [NativeDictionaryEngineSource], ids: [String]) throws -> ConversionResponse {
        let service = ConversionService(sources: sources)
        service.setCategoryIDs(ids)
        service.setEnglishReading(false)
        let done = expectation(description: "typed generation through production Service")
        var value: Result<ConversionResponse, Error>?
        service.convert("あ", generation: 1, editStart: 0) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(value).get()
    }
    func testWholeFamilyUsesTypedAggregateWhilePartialSelectionKeepsLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        let aggregate = root.appendingPathComponent("incoming.sud")
        try dictionary("集約固有", cost: -20_000).write(to: aggregate)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let loaded = try store.publish(importedFiles: [:], from: base, supportFallback: base,
            legacyAggregateOverlays: [.init(rawValue: "person"): aggregate], importMode: .typedLegacyAggregate)
        XCTAssertTrue(loaded.hasVerifiedReleaseMarker)
        XCTAssertEqual(personLeaves.count, 29)
        XCTAssertEqual(loaded.resolveSourceSelection(for: personLeaves).legacyAggregateSources.map { $0.id.rawValue }, ["person"])
        let partial = try convert(loaded, ids: ["actor"])
        XCTAssertTrue(partial.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(partial.candidates.contains { $0.text == "集約固有" })
        let full = try convert(loaded, ids: personLeaves)
        XCTAssertTrue(full.candidates.contains { $0.text == "集約固有" && $0.dictionaries.contains("legacy_aggregates/person") },
                      "A verified full-family aggregate must reach actual Service conversion")
        XCTAssertFalse(full.candidates.contains { $0.text == "葉候補" }, "Substituted leaves must not also load")
        let aggregateCandidate = try XCTUnwrap(full.candidates.first { $0.text == "集約固有" })
        XCTAssertEqual(aggregateCandidate.classifiedCategories, ["legacy_aggregates/person"])
        XCTAssertEqual(aggregateCandidate.displayAnnotation, "[人名]", "Keep typed origins without exposing storage paths as badges")
    }
    func testOnlyManifestedChecksumMatchedAggregatesBecomeActive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let first = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let unmanifested = first.directory.appendingPathComponent("legacy_aggregates/person.sud")
        try FileManager.default.createDirectory(at: unmanifested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dictionary("未登録集約", cost: -20_000).write(to: unmanifested)
        let unregistered = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(unregistered.legacyAggregateOverlayIDs.isEmpty)
        let inactive = try convert(unregistered, ids: personLeaves)
        XCTAssertTrue(inactive.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(inactive.candidates.contains { $0.text == "未登録集約" })

        let incoming = root.appendingPathComponent("incoming.sud")
        try dictionary("認証済集約", cost: -20_000).write(to: incoming)
        let current = try store.publish(importedFiles: [:], from: first.directory,
            legacyAggregateOverlays: [.init(rawValue: "person"): incoming], importMode: .typedLegacyAggregate)
        let live = try convert(current, ids: personLeaves)
        XCTAssertTrue(live.candidates.contains { $0.text == "認証済集約" })
        // A file replaced after Loaded was created cannot participate in its resolver plan.
        try Data("changed aggregate".utf8).write(to: current.directory.appendingPathComponent("legacy_aggregates/person.sud"))
        let changed = try convert(current, ids: personLeaves)
        XCTAssertTrue(changed.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(changed.candidates.contains { $0.text == "認証済集約" })
        XCTAssertEqual(store.loadCandidates().map(\.generation), [first.generation])
        // A manifested marker/hash failure and a manifest/hash failure also exclude current.
        try Data(contentsOf: incoming).write(to: current.directory.appendingPathComponent("legacy_aggregates/person.sud"))
        let marker = current.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker)
        let markerBytes = try Data(contentsOf: marker)
        try Data("changed marker".utf8).write(to: marker)
        // Reusing Loaded must not retain aggregate authority after marker replacement.
        let staleMarkerResponse = try? convert(current, ids: personLeaves)
        XCTAssertFalse(staleMarkerResponse?.candidates.contains { $0.text == "認証済集約" } == true,
                       "A stale Loaded must not activate an aggregate after its manifested marker changes")
        XCTAssertEqual(store.loadCandidates().map(\.generation), [first.generation])
        let markerFallback = try convert(sources: [.init(generation: current), .init(generation: first), .init(directory: base)], ids: personLeaves)
        XCTAssertTrue(markerFallback.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(markerFallback.candidates.contains { $0.text == "認証済集約" })
        try markerBytes.write(to: marker)
        try Data("changed manifest".utf8).write(to: current.directory.appendingPathComponent("manifest.json"))
        let manifestFallback = try convert(sources: [.init(generation: current), .init(generation: first), .init(directory: base)], ids: personLeaves)
        XCTAssertTrue(manifestFallback.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(manifestFallback.candidates.contains { $0.text == "認証済集約" })
        let manifestBundleFallback = try convert(sources: [.init(generation: current), .init(directory: base)], ids: personLeaves)
        XCTAssertTrue(manifestBundleFallback.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(manifestBundleFallback.candidates.contains { $0.text == "認証済集約" })
        let recovered = try XCTUnwrap(store.loadCandidates().first)
        XCTAssertEqual(recovered.generation, first.generation)
        let response = try convert(recovered, ids: personLeaves)
        XCTAssertTrue(response.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(response.candidates.contains { $0.text == "認証済集約" })
    }

    func testNativeAggregateFailureFallsBackToPreviousThenBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let incoming = root.appendingPathComponent("incoming.sud")
        try dictionary("前世代集約", cost: -20_000).write(to: incoming)
        let good = try store.publish(importedFiles: [:], from: base, supportFallback: base,
            legacyAggregateOverlays: [.init(rawValue: "person"): incoming], importMode: .typedLegacyAggregate)
        try Data("manifested but invalid native file".utf8).write(to: incoming)
        let bad = try store.publish(importedFiles: [:], from: good.directory,
            legacyAggregateOverlays: [.init(rawValue: "person"): incoming], importMode: .typedLegacyAggregate)
        XCTAssertEqual(store.loadCandidates().map(\.generation), [bad.generation, good.generation])
        var sources = store.loadCandidates().map { NativeDictionaryEngineSource(generation: $0) }
        sources.append(NativeDictionaryEngineSource(directory: base))
        let previous = try convert(sources: sources, ids: personLeaves)
        XCTAssertTrue(previous.candidates.contains { $0.text == "前世代集約" })
        XCTAssertFalse(previous.candidates.contains { $0.text == "葉候補" })
        _ = try store.publish(importedFiles: [:], from: bad.directory,
            legacyAggregateOverlays: [.init(rawValue: "person"): incoming], importMode: .typedLegacyAggregate)
        sources = store.loadCandidates().map { NativeDictionaryEngineSource(generation: $0) }
        sources.append(NativeDictionaryEngineSource(directory: base))
        let bundle = try convert(sources: sources, ids: personLeaves)
        XCTAssertTrue(bundle.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(bundle.candidates.contains { $0.text == "前世代集約" })
    }

    func testUnmanifestedMarkerCannotPromoteLegacyRootNamesToReleaseLeaves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBase(root)
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in ["system.sud", "connection.sud"] {
            try FileManager.default.copyItem(at: bundle.appendingPathComponent(name), to: legacy.appendingPathComponent(name))
        }
        try dictionary("旧分類集約", cost: -20_000).write(to: legacy.appendingPathComponent("character.sud"))
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let old = try store.publish(importedFiles: [:], from: legacy)
        XCTAssertFalse(old.hasVerifiedReleaseMarker)
        let before = try convert(old, ids: ["character"])
        XCTAssertTrue(before.candidates.contains { $0.text == "旧分類集約" }, "Keep the existing unmarked legacy catalog path")
        try Data("unmanifested marker".utf8).write(to: old.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let unverified = try XCTUnwrap(store.loadCurrent())
        XCTAssertFalse(unverified.hasVerifiedReleaseMarker)
        let after = try convert(sources: [NativeDictionaryEngineSource(generation: unverified),
                                         NativeDictionaryEngineSource(directory: bundle)], ids: ["character"])
        XCTAssertFalse(after.candidates.contains { $0.text == "旧分類集約" })
        XCTAssertTrue(after.candidates.contains { $0.text == "基準" })
    }

    private enum Kind {
        case shorts, ints, longs, characters
        var name: String { switch self { case .shorts: "[S"; case .ints: "[I"; case .longs: "[J"; case .characters: "[C" } }
        var uid: UInt64 {
            switch self {
            case .shorts: 0xef832e06e55db0fa
            case .ints: 0x4dba602676eab2a5
            case .longs: 0x782004b512b17593
            case .characters: 0xb02666b0e25d84ac
            }
        }
        var width: Int { switch self { case .shorts, .characters: 2; case .ints: 4; case .longs: 8 } }
    }
    private struct ArrayValue { let kind: Kind; let values: [UInt64] }

    private func appendBE(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    private func appendLE(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    private func javaStream(_ arrays: [ArrayValue]) -> Data {
        var data = Data([0xac, 0xed, 0, 5])
        for array in arrays {
            data.append(contentsOf: [0x75, 0x72])
            appendBE(UInt64(array.kind.name.utf8.count), width: 2, to: &data)
            data.append(contentsOf: array.kind.name.utf8)
            appendBE(array.kind.uid, width: 8, to: &data)
            data.append(contentsOf: [2, 0, 0, 0x78, 0x70])
            appendBE(UInt64(array.values.count), width: 4, to: &data)
            for value in array.values { appendBE(value, width: array.kind.width, to: &data) }
        }
        return data
    }
    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~value
    }
    private func storedZIP(_ files: [(String, Data)]) -> Data {
        struct Central { let name: Data; let crc, size, offset: UInt32 }
        var data = Data(), central: [Central] = []
        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32, to data: inout Data) {
            append16(UInt16(truncatingIfNeeded: value), to: &data)
            append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        }
        for (name, payload) in files {
            let nameData = Data(name.utf8), size = UInt32(payload.count), checksum = crc32(payload)
            let offset = UInt32(data.count)
            append32(0x0403_4b50, to: &data); append16(20, to: &data); append16(0, to: &data)
            append16(0, to: &data); append16(0, to: &data); append16(0, to: &data)
            append32(checksum, to: &data); append32(size, to: &data); append32(size, to: &data)
            append16(UInt16(nameData.count), to: &data); append16(0, to: &data)
            data.append(nameData); data.append(payload)
            central.append(Central(name: nameData, crc: checksum, size: size, offset: offset))
        }
        let centralOffset = UInt32(data.count)
        for entry in central {
            append32(0x0201_4b50, to: &data); append16(20, to: &data); append16(20, to: &data)
            append16(0, to: &data); append16(0, to: &data); append16(0, to: &data); append16(0, to: &data)
            append32(entry.crc, to: &data); append32(entry.size, to: &data); append32(entry.size, to: &data)
            append16(UInt16(entry.name.count), to: &data); append16(0, to: &data); append16(0, to: &data)
            append16(0, to: &data); append16(0, to: &data); append32(0, to: &data); append32(entry.offset, to: &data)
            data.append(entry.name)
        }
        let centralSize = UInt32(data.count) - centralOffset
        append32(0x0605_4b50, to: &data); append16(0, to: &data); append16(0, to: &data)
        append16(UInt16(central.count), to: &data); append16(UInt16(central.count), to: &data)
        append32(centralSize, to: &data); append32(centralOffset, to: &data); append16(0, to: &data)
        return data
    }

    func testRealArchiveImportReachesFullFamilyConversionButNotPartialSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try makeBase(root)
        let reading = javaStream([
            .init(kind: .longs, values: [0b101]), .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x3042]), .init(kind: .ints, values: [1])
        ])
        let surface = javaStream([
            .init(kind: .longs, values: [0b101]), .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x96c6])
        ])
        let tokens = javaStream([
            .init(kind: .shorts, values: [0]), .init(kind: .shorts, values: [0]),
            .init(kind: .ints, values: [2]), .init(kind: .longs, values: [0b10])
        ])
        let pos = javaStream([.init(kind: .shorts, values: [0]), .init(kind: .shorts, values: [0])])
        let archive = root.appendingPathComponent("legacy-person.zip")
        try storedZIP([
            ("pos_table.dat", pos), ("connectionId.dat", Data([0, 0])),
            ("categories/person/yomi.dat", reading), ("categories/person/tango.dat", surface),
            ("categories/person/token.dat", tokens)
        ]).write(to: archive)
        let container = root.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        // No converter or validator seam: exercise production ZIP conversion,
        // native validation, publication, authentication and Service conversion.
        let outcome = DictionaryArchiveImporter.perform(archive: archive, sharedContainer: container,
            categoryInterpretation: .legacyAggregate, storeImportMode: .typedLegacyAggregate,
            bundledSupport: support)
        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertEqual(outcome.storedLegacyAggregateIDs, ["person"])
        XCTAssertTrue(outcome.message.contains("すべて選択"), outcome.message)
        let store = DictionaryGenerationStore(directory: container.appendingPathComponent("Sumire/Dictionaries"))
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(loaded.hasCurrentVerifiedReleaseProvenance)
        let full = try convert(loaded, ids: personLeaves)
        XCTAssertTrue(full.candidates.contains { $0.text == "集" && $0.dictionaries.contains("legacy_aggregates/person") })
        XCTAssertFalse(full.candidates.contains { $0.text == "葉候補" })
        let partial = try convert(loaded, ids: ["actor"])
        XCTAssertTrue(partial.candidates.contains { $0.text == "葉候補" })
        XCTAssertFalse(partial.candidates.contains { $0.text == "集" })

        let unmarkedSupport = root.appendingPathComponent("unmarked")
        try FileManager.default.copyItem(at: support, to: unmarkedSupport)
        try FileManager.default.removeItem(at: unmarkedSupport.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        for id in DictionaryCategoryCatalog.legacyIDs {
            try dictionary("旧分類", cost: 20_000).write(to: unmarkedSupport.appendingPathComponent(id + ".sud"))
        }
        let unmarkedContainer = root.appendingPathComponent("unmarked-container")
        try FileManager.default.createDirectory(at: unmarkedContainer, withIntermediateDirectories: true)
        let inactiveOutcome = DictionaryArchiveImporter.perform(archive: archive, sharedContainer: unmarkedContainer,
            categoryInterpretation: .legacyAggregate, storeImportMode: .typedLegacyAggregate,
            bundledSupport: unmarkedSupport)
        XCTAssertTrue(inactiveOutcome.succeeded, inactiveOutcome.message)
        XCTAssertTrue(inactiveOutcome.message.contains("認証がないため"), inactiveOutcome.message)
        let inactive = try XCTUnwrap(DictionaryGenerationStore(directory:
            unmarkedContainer.appendingPathComponent("Sumire/Dictionaries")).loadCurrent())
        XCTAssertFalse(inactive.hasVerifiedReleaseMarker)
        XCTAssertTrue(inactive.resolveSourceSelection(for: personLeaves).legacyAggregateSources.isEmpty)
        XCTAssertFalse(try convert(inactive, ids: personLeaves).candidates.contains { $0.text == "集" })
    }

}
