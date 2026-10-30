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

}
