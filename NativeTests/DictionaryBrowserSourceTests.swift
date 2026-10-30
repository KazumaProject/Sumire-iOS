import XCTest
import SumireCore
import CryptoKit
@testable import Sumire

final class DictionaryBrowserSourceTests: XCTestCase {
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
    private func dictionary(_ text: String, cost: Int16 = 0) -> Data { dictionary([text], cost: cost) }
    private func dictionary(_ texts: [String], cost: Int16 = 0) -> Data {
        var strings = Data(), offsets: [UInt32] = [0]
        for text in texts { strings.append(Data(text.utf8)); offsets.append(UInt32(strings.count)) }
        return file(kind: 1, dimension: 0, sections: [
            packed([UInt64(5)]), packed([UInt16(32), 32, 0x3042]), packed([UInt64(4)]),
            packed([UInt32(1)]), packed([UInt32(0), 0, UInt32(texts.count)]),
            packed(Array(repeating: UInt16(0), count: texts.count)), packed(Array(repeating: cost, count: texts.count)),
            packed(texts.indices.map(UInt32.init)), packed(offsets), strings
        ])
    }
    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func writeBundleManifest(_ directory: URL, names: [String] = ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker]) throws {
        var hashes: [String: String] = [:]
        for name in names { hashes[name] = try sha256(of: directory.appendingPathComponent(name)) }
        try JSONSerialization.data(withJSONObject: ["source_revision": "synthetic-browser-fixture", "output_sha256": hashes], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
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
        try writeBundleManifest(base)
        return base
    }

    private func page(_ worker: DictionaryBrowserWorker, name: String = "system", restart: Bool = true, generation: UInt64) throws -> DictionaryBrowserWorker.Page {
        let done = expectation(description: "production browser worker/native rows")
        var value: Result<DictionaryBrowserWorker.Page, Error>?
        worker.page(name: name, query: "", mode: 2, restart: restart, generation: generation) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(value).get()
    }
    func testRetainedSourcesRevalidateMarkerBeforeWorkerOpensAndFallsBackToPrevious() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let incoming = root.appendingPathComponent("incoming.sud")
        try dictionary("現行固有").write(to: incoming)
        let current = try store.publish(importedFiles: ["system.sud": incoming], from: previous.directory)
        XCTAssertTrue(previous.hasVerifiedReleaseMarker)
        XCTAssertTrue(current.hasVerifiedReleaseMarker)
        let sources = DictionaryBrowserSource.candidates(name: "system", generations: store.loadCandidates(), bundled: base)
        XCTAssertEqual(sources.first?.generation, current.generation)
        try Data("changed marker".utf8).write(to: current.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let worker = DictionaryBrowserWorker(sourceCandidates: { _ in sources })
        let result = try page(worker, generation: worker.invalidate())
        XCTAssertEqual(result.source.generation, previous.generation)
        XCTAssertEqual(result.rows.map(\.surface), ["基準"])
    }
    func testActualWorkerUsesCurrentThenPreviousThenBundleWithExactProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root), incoming = root.appendingPathComponent("incoming.sud")
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        try dictionary("現行固有").write(to: incoming)
        let current = try store.publish(importedFiles: ["system.sud": incoming], from: previous.directory)
        let sources = DictionaryBrowserSource.candidates(name: "system", generations: store.loadCandidates(), bundled: base)
        XCTAssertEqual(sources.map(\.title), ["共有辞書（現行世代）", "共有辞書（前世代）", "同梱辞書"])
        func read() throws -> DictionaryBrowserWorker.Page {
            let worker = DictionaryBrowserWorker(sourceCandidates: { _ in sources })
            return try page(worker, generation: worker.invalidate())
        }
        let first = try read()
        XCTAssertEqual(first.rows.map(\.surface), ["現行固有"])
        XCTAssertEqual(first.source.manifestSHA256, current.verifiedManifestSHA256)
        XCTAssertEqual(first.source.dictionarySHA256, try sha256(of: current.directory.appendingPathComponent("system.sud")))
        XCTAssertEqual(first.source.sourceRevision, "unknown-or-mixed")
        try Data("changed".utf8).write(to: current.directory.appendingPathComponent("system.sud"))
        XCTAssertEqual(try read().source.generation, previous.generation)
        try Data("changed".utf8).write(to: previous.directory.appendingPathComponent("system.sud"))
        let last = try read()
        XCTAssertEqual(last.source.origin, .bundled)
        XCTAssertEqual(last.source.sourceRevision, "synthetic-browser-fixture")
        XCTAssertEqual(last.rows.map(\.surface), ["基準"])
    }

    func testRetainedManifestMarkerMissingAndSymlinkMutationsFallBackWithoutReacquiringLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let current = try store.publish(importedFiles: [:], from: previous.directory)
        let sources = DictionaryBrowserSource.candidates(name: "system", generations: store.loadCandidates(), bundled: base)
        for name in ["manifest.json", DictionaryCategoryCatalog.releaseMarker, "system.sud"] {
            let url = current.directory.appendingPathComponent(name), original = try Data(contentsOf: current.directory.appendingPathComponent(name))
            defer { try? original.write(to: url) }
            for mutation in 0..<3 {
                try? FileManager.default.removeItem(at: url)
                if mutation == 0 { try Data("changed".utf8).write(to: url) }
                if mutation == 2 { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: previous.directory.appendingPathComponent(name)) }
                let worker = DictionaryBrowserWorker(sourceCandidates: { _ in sources })
                XCTAssertEqual(try page(worker, generation: worker.invalidate()).source.generation, previous.generation, "\(name) mutation \(mutation)")
            }
            try FileManager.default.removeItem(at: url)
            try original.write(to: url)
        }
    }

    func testNativeOpenFailureFallsBackBeforeFirstPageButPaginationKeepsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        try dictionary((0..<101).map { "固定\($0)" }).write(to: base.appendingPathComponent("system.sud"))
        try writeBundleManifest(base)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let corrupt = root.appendingPathComponent("corrupt.sud")
        try Data("manifested but invalid native file".utf8).write(to: corrupt)
        let current = try store.publish(importedFiles: ["system.sud": corrupt], from: previous.directory)
        let sources = DictionaryBrowserSource.candidates(name: "system", generations: store.loadCandidates(), bundled: base)
        XCTAssertEqual(sources.first?.generation, current.generation)
        var selections = 0
        let worker = DictionaryBrowserWorker(sourceCandidates: { _ in selections += 1; return sources })
        let generation = worker.invalidate()
        let first = try page(worker, generation: generation)
        XCTAssertEqual(first.source.generation, previous.generation)
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertFalse(first.done)
        try Data("lost provenance".utf8).write(to: previous.directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try page(worker, restart: false, generation: generation))
        XCTAssertEqual(selections, 1, "A failed next page must not select a different source")
    }

    func testReleaseLeafNamespaceAndUnsafeNamesUseActualNativeRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root), name = "facility/religious/shrine"
        XCTAssertTrue(DictionaryCategoryCatalog.idSet.contains(name))
        let leaf = base.appendingPathComponent(name + ".sud")
        try FileManager.default.createDirectory(at: leaf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dictionary("葉閲覧固有").write(to: leaf)
        try writeBundleManifest(base, names: ["system.sud", "connection.sud", DictionaryCategoryCatalog.releaseMarker, name + ".sud"])
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let previous = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        let loaded = try store.publish(importedFiles: [:], from: previous.directory)
        for unsafe in ["../system", "/system", "legacy_aggregates/person", "unclassified_categories/person", "facility/../system", "person.sud", "unknown"] {
            XCTAssertTrue(DictionaryBrowserSource.candidates(name: unsafe, generations: [loaded], bundled: base).isEmpty)
        }
        let sources = DictionaryBrowserSource.candidates(name: name, generations: [loaded], bundled: base)
        let worker = DictionaryBrowserWorker(sourceCandidates: { _ in sources })
        let leafPage = try page(worker, name: name, generation: worker.invalidate())
        XCTAssertEqual(leafPage.source.generation, loaded.generation)
        XCTAssertEqual(leafPage.rows.map(\.surface), ["葉閲覧固有"])
        let retained = [loaded, try XCTUnwrap(store.loadCandidates().last)]
        try FileManager.default.removeItem(at: loaded.directory.appendingPathComponent(name + ".sud"))
        XCTAssertEqual(DictionaryBrowserSource.candidates(name: name, generations: retained, bundled: base).first?.generation, previous.generation)
        XCTAssertEqual(DictionaryBrowserSource.candidates(name: "system", generations: retained, bundled: base).first?.generation, loaded.generation,
                       "A missing selected leaf does not replace other browsable files with a different generation")
        // Identical basenames in a different namespace do not authorize that path.
        let folder = loaded.directory.appendingPathComponent("facility")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: base.appendingPathComponent("facility"))
        XCTAssertEqual(DictionaryBrowserSource.candidates(name: name, generations: [loaded], bundled: base).map(\.origin), [.bundled])
    }

    func testUnmanifestedMarkerCannotAuthenticateStoredBrowserSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try makeBase(root)
        try FileManager.default.removeItem(at: base.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        try writeBundleManifest(base, names: ["system.sud", "connection.sud"])
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
        let loaded = try store.publish(importedFiles: [:], from: base, supportFallback: base)
        XCTAssertFalse(loaded.hasVerifiedReleaseMarker)
        try Data("v1.7.277\n".utf8).write(to: loaded.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        XCTAssertEqual(DictionaryBrowserSource.candidates(name: "system", generations: [loaded], bundled: base).map(\.origin), [.bundled])
    }

}
