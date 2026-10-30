import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class BunsetsuJapaneseCompletionTests: XCTestCase {
    private var directories: [URL] = []
    private var generation: UInt64 = 0
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }
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
    private func dictionary(reading: String, text: String, cost: Int16) -> Data {
        let units = Array(reading.utf16)
        precondition(!units.isEmpty && units.count < 30)
        var tree: UInt64 = 1
        for index in units.indices { tree |= UInt64(1) << (2 + index * 2) }
        let leaves = UInt64(1) << (units.count * 2)
        let bytes = Data(text.utf8)
        return file(kind: 1, dimension: 0, sections: [
            packed([tree]), packed([UInt16(32), 32] + units), packed([leaves]),
            packed([UInt32(1)]), packed([UInt32(0), 0, 1]), packed([UInt16(0)]),
            packed([cost]), packed([UInt32(0)]), packed([UInt32(0), UInt32(bytes.count)]), bytes
        ])
    }
    private func base() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try file(kind: 2, dimension: 3, sections: [packed([UInt16(1)]), packed([UInt16(2)]),
            packed([Int16(0), 0, 0]), packed([UInt64(0), 0, 0]), Data(),
            packed([UInt32(0), 0, 0, 0]), packed([UInt16(0), 0, 0])])
            .write(to: root.appendingPathComponent("connection.sud"))
        try dictionary(reading: "あいうえお", text: "文節補完", cost: 100).write(to: root.appendingPathComponent("system.sud"))
        try dictionary(reading: "あいうえお", text: "分類補完", cost: 100).write(to: root.appendingPathComponent("actor.sud"))
        try dictionary(reading: "あいうえお", text: "訂正\tていせい", cost: 200).write(to: root.appendingPathComponent("reading_correction.sud"))
        try dictionary(reading: "あいうえお", text: "諺補完", cost: 300).write(to: root.appendingPathComponent("kotowaza.sud"))
        try Data("v1.7.277\n".utf8).write(to: root.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let bundled = try XCTUnwrap(ConversionService.bundledDictionary)
        for path in ["system_ngram.dat", "system_ngram_unigram.dat", "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat"] {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled.appendingPathComponent(path), to: target)
        }
        return root
    }
    private func convert(_ service: ConversionService, _ reading: String = "あいう", bunsetsu: Bool = true) throws -> ConversionResponse {
        generation += 1
        let done = expectation(description: "configured Japanese bunsetsu completion")
        var result: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, includeBunsetsu: true, bunsetsuSearch: bunsetsu) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }
    func testServiceBunsetsuUsesConfiguredJapaneseCompletion() throws {
        let value = ConversionService(directory: try base())
        value.setEnglishReading(false); value.setCategoryIDs(["actor"])
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2))
        let result = try convert(value)
        // df1f383: system 8000/extra unit, category 1500, correction 8000.
        XCTAssertEqual(result.candidates.first { $0.text == "文節補完" }?.score, 16_100)
        XCTAssertEqual(result.candidates.first { $0.text == "分類補完" }?.score, 3_100)
        XCTAssertEqual(result.candidates.first { $0.text == "訂正" }?.score, 16_200)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        XCTAssertFalse(try convert(value).candidates.contains { ["文節補完", "分類補完", "訂正"].contains($0.text) })
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2, aggressiveness: .aggressive))
        let aggressive = try convert(value)
        XCTAssertEqual(aggressive.candidates.first { $0.text == "文節補完" }?.score, 8_100)
        XCTAssertEqual(aggressive.candidates.first { $0.text == "分類補完" }?.score, 1_600)
        XCTAssertEqual(aggressive.candidates.first { $0.text == "訂正" }?.score, 8_200)
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "learning queue fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testKnownEndpointsCandidateZeroOwnedSnapshotAndPartialCommitPlan() throws {
        let root = try base(), database = root.appendingPathComponent("learning.sqlite")
        var value: ConversionService? = ConversionService(directory: root)
        value!.setEnglishReading(false); value!.setCategoryIDs(["actor"])
        value!.setPredictionSettings(.init(lookaheadCharacterCount: 2)); value!.setLearning(url: database)
        let first = try convert(value!), snapshot = try XCTUnwrap(first.bunsetsuSnapshot)
        let initialGeneration = generation
        XCTAssertEqual(first.candidates.first?.text, "分類補完")
        XCTAssertEqual(first.candidates.first?.id, 0, "A newly ranked completion can be native candidate zero")
        for text in ["文節補完", "分類補完", "訂正"] {
            let row = try XCTUnwrap(first.candidates.first { $0.text == text })
            XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
            XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
            let owned = try XCTUnwrap(snapshot.candidates.first { $0.candidateID == row.id })
            XCTAssertEqual(owned.leftID, 1); XCTAssertEqual(owned.rightID, 2)
            XCTAssertEqual(owned.tokenPath?.first?.readingRange, NSRange(location: 0, length: 3))
        }
        let noDictionaryPath = try XCTUnwrap(snapshot.candidates.first { $0.identity.surface == "あいう" && $0.tokenPath == nil })
        XCTAssertNil(noDictionaryPath.leftID); XCTAssertNil(noDictionaryPath.rightID)
        let patterns = try snapshot.projectedSplitPatterns(reading: "あいう", requestGeneration: initialGeneration,
                                                          orderedDisplayCandidates: first.orderedDisplayIdentities)
        var session = try BunsetsuConversionSession(rawInput: "あいう末", conversionInput: "あいう", tailText: "末",
            wholeDisplayText: "分類補完", generation: initialGeneration, snapshot: snapshot,
            orderedDisplayCandidates: first.orderedDisplayIdentities)
        let token = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: generation + 1))
        let alternatives = try convert(value!)
        let records = alternatives.candidates.enumerated().map { index, candidate in
            BunsetsuSessionCandidate(text: candidate.text, reference: .conversionResult(generation: generation, candidateID: candidate.id),
                score: candidate.score, candidateIndex: index, leftID: candidate.leftID, rightID: candidate.rightID,
                matchedReadingUTF16Length: candidate.range.length)
        }
        XCTAssertTrue(session.installCandidates(records, responseReading: "あいう", responseGeneration: generation, for: token))
        let selectedIndex = try XCTUnwrap(session.segments.first?.candidateRecords.firstIndex { $0.text == "分類補完" })
        _ = session.selectFocusedCandidate(at: selectedIndex)
        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.committedReading, "あいう"); XCTAssertEqual(plan.readingUTF16Length, 3)
        XCTAssertEqual(plan.committedText, "分類補完"); XCTAssertEqual(plan.nextComposingInput, "末")
        XCTAssertEqual(plan.learningFragments.first?.leftID, 1); XCTAssertEqual(plan.learningFragments.first?.rightID, 2)
        XCTAssertEqual(plan.learningFragments.first?.reading, "あいう")
        value!.commitLearningPlan(plan, learnFirst: true) { _ in }; fence(value!)
        XCTAssertTrue(try LearningStore(url: database).snapshot().isEmpty, "The uncommitted tail must not be saved")
        value!.cancelLearning(); fence(value!)
        let selected = try XCTUnwrap(alternatives.candidates.first { $0.text == "分類補完" })
        let rank = try XCTUnwrap(alternatives.candidates.firstIndex { $0.id == selected.id })
        value!.commitSelection(generation: generation, candidate: selected, rank: rank, input: "あいう", remaining: "", learnFirst: true) { _ in }
        fence(value!)
        let saved = try LearningStore(url: database).snapshot()
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.reading, "あいう")
        XCTAssertEqual(saved.first?.leftID, 1); XCTAssertEqual(saved.first?.rightID, 2)
        let oldGeneration = generation
        value!.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        value!.commitSelection(generation: oldGeneration, candidate: selected, rank: rank, input: "あいう", remaining: "", learnFirst: true) { _ in }
        fence(value!)
        XCTAssertEqual(try LearningStore(url: database).snapshot(), saved, "Old completion selection must not save after a config change")
        _ = try convert(value!, "あい")
        value!.setLearning(url: nil); fence(value!); value = nil
        XCTAssertEqual(try snapshot.projectedSplitPatterns(reading: "あいう", requestGeneration: initialGeneration,
            orderedDisplayCandidates: first.orderedDisplayIdentities), patterns)
        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(reading: "あいう", requestGeneration: initialGeneration + 1,
            orderedDisplayCandidates: first.orderedDisplayIdentities))
    }
    func testUTF16ConsumedPrefixAndUnknownFallbackRemainDistinct() throws {
        let root = try base()
        try dictionary(reading: "あ😀うえ", text: "Unicode補完", cost: 100).write(to: root.appendingPathComponent("system.sud"))
        let value = ConversionService(directory: root); value.setEnglishReading(false)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2))
        let response = try convert(value, "あ😀")
        let row = try XCTUnwrap(response.candidates.first { $0.text == "Unicode補完" })
        XCTAssertEqual(row.score, 16_100); XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
        XCTAssertNotNil(Range(row.range, in: "あ😀")); XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
        let snapshot = try XCTUnwrap(response.bunsetsuSnapshot)
        let plain = try XCTUnwrap(snapshot.candidates.first { $0.identity.surface == "あ😀" && $0.tokenPath == nil })
        XCTAssertNil(plain.leftID); XCTAssertNil(plain.rightID)
        _ = try convert(value, "あいう")
        XCTAssertEqual(snapshot.candidates.first { $0.candidateID == row.id }?.identity.surface, "Unicode補完")
    }
    func testLowerCostSharedSurfaceCompletionWinsDisplayAndKeepsTypedRange() throws {
        let root = try base(), text = "文節補完同文面試験", bytes = Data(text.utf8)
        let units = Array("あいうえ".utf16)
        var tree: UInt64 = 1
        for index in units.indices { tree |= UInt64(1) << (2 + index * 2) }
        try file(kind: 1, dimension: 0, sections: [packed([tree]), packed([UInt16(32), 32] + units),
            packed([UInt64(1) << 6 | UInt64(1) << 8]), packed([UInt32(1), 2]),
            packed([UInt32(0), 0, 1, 2]), packed([UInt16(0), 0]), packed([Int16(30_000), 100]),
            packed([UInt32(0), 0]), packed([UInt32(0), UInt32(bytes.count)]), bytes])
            .write(to: root.appendingPathComponent("system.sud"))
        let value = ConversionService(directory: root); value.setEnglishReading(false)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        let response = try convert(value)
        let row = try XCTUnwrap(response.candidates.first { $0.text == text })
        XCTAssertEqual(row.score, 8_100)
        XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
        let snapshot = try XCTUnwrap(response.bunsetsuSnapshot)
        let nativeRows = snapshot.candidates.filter { $0.identity.surface == text }
        XCTAssertEqual(nativeRows.first?.score, 8_100)
        XCTAssertTrue(nativeRows.contains { $0.score >= 30_000 })
        let session = try BunsetsuConversionSession(rawInput: "あいう", conversionInput: "あいう",
            wholeDisplayText: text, generation: generation, snapshot: snapshot,
            orderedDisplayCandidates: response.orderedDisplayIdentities)
        XCTAssertEqual(session.leadingSegmentCommitPlan()?.readingUTF16Length, 3)
        XCTAssertEqual(session.leadingSegmentCommitPlan()?.committedReading, "あいう")
    }
    func testMatchedSharedSurfaceCompletionCompetesAtTheSamePriority() throws {
        let root = try base(), bytes = Data("あいう".utf8), units = Array("あいうえ".utf16)
        var tree: UInt64 = 1
        for index in units.indices { tree |= UInt64(1) << (2 + index * 2) }
        try file(kind: 1, dimension: 0, sections: [packed([tree]), packed([UInt16(32), 32] + units),
            packed([UInt64(1) << 6 | UInt64(1) << 8]), packed([UInt32(1), 2]),
            packed([UInt32(0), 0, 1, 2]), packed([UInt16(0), 0]), packed([Int16(30_000), 100]),
            packed([UInt32(0), 0]), packed([UInt32(0), UInt32(bytes.count)]), bytes])
            .write(to: root.appendingPathComponent("system.sud"))
        try file(kind: 3, dimension: 1, sections: [packed([UInt32(0), UInt32(bytes.count)]), bytes])
            .write(to: root.appendingPathComponent("standalone.sud"))
        let value = ConversionService(directory: root); value.setEnglishReading(false)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        let response = try convert(value)
        let row = try XCTUnwrap(response.candidates.first { $0.text == "あいう" })
        XCTAssertEqual(row.score, 8_100)
        XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
        let raw = try XCTUnwrap(response.bunsetsuSnapshot).candidates.filter { $0.identity.surface == "あいう" }
        XCTAssertEqual(raw.first?.score, 8_100)
        XCTAssertTrue(raw.contains { $0.score >= 30_000 })
    }
    func testNumericBunsetsuKeepsNumericRouteWithoutDictionaryCompletion() throws {
        for reading in ["123", "１２３"] {
            let root = try base(), suffix = reading == "123" ? "4" : "４"
            try dictionary(reading: reading + suffix, text: "数値system補完", cost: 100).write(to: root.appendingPathComponent("system.sud"))
            try dictionary(reading: reading + suffix, text: "数値分類補完", cost: 100).write(to: root.appendingPathComponent("actor.sud"))
            try dictionary(reading: reading + suffix, text: "数値訂正補完\tていせい", cost: 200).write(to: root.appendingPathComponent("reading_correction.sud"))
            let value = ConversionService(directory: root); value.setEnglishReading(false); value.setCategoryIDs(["actor"])
            value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
            let response = try convert(value, reading)
            XCTAssertFalse(response.candidates.contains { ["数値system補完", "数値分類補完", "数値訂正補完"].contains($0.text) })
            let numeric = try XCTUnwrap(response.candidates.first { $0.text == "百二十三" })
            XCTAssertEqual(numeric.leftID, 2040); XCTAssertEqual(numeric.rightID, 2040)
            XCTAssertEqual(numeric.range, NSRange(location: 0, length: 3))
            if reading == "123" {
                let date = try XCTUnwrap(response.candidates.first { $0.text == "1月23日" })
                XCTAssertEqual(date.leftID, 1851); XCTAssertEqual(date.rightID, 1851)
            }
        }
    }
}
