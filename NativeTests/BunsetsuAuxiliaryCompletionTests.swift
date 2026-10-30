import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class BunsetsuAuxiliaryCompletionTests: XCTestCase {
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
    private func base(yomi: String = "あいうえ") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try file(kind: 2, dimension: 3, sections: [packed([UInt16(1)]), packed([UInt16(2)]),
            packed([Int16(0), 0, 0]), packed([UInt64(0), 0, 0]), Data(),
            packed([UInt32(0), 0, 0, 0]), packed([UInt16(0), 0, 0])])
            .write(to: root.appendingPathComponent("connection.sud"))
        try dictionary(reading: "あいう", text: "主", cost: 20_000).write(to: root.appendingPathComponent("system.sud"))
        try dictionary(reading: "ほげ", text: "unused", cost: 100).write(to: root.appendingPathComponent("single_kanji.sud"))
        for (name, text, cost) in [("emoji", "🧪", Int16(100)), ("emoticon", "(^_^)", Int16(200)), ("symbol", "☆", Int16(300))] {
            try dictionary(reading: yomi, text: text, cost: cost).write(to: root.appendingPathComponent(name + ".sud"))
        }
        let bundled = try XCTUnwrap(ConversionService.bundledDictionary)
        for path in ["system_ngram.dat", "system_ngram_unigram.dat", "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat"] {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled.appendingPathComponent(path), to: target)
        }
        return root
    }
    private func convert(_ value: ConversionService, _ input: String = "あいう", bunsetsu: Bool = true) throws -> ConversionResponse {
        generation += 1
        let done = expectation(description: "real auxiliary bunsetsu completion")
        var result: Result<ConversionResponse, Error>?
        value.convert(input, generation: generation, editStart: 0, includeBunsetsu: true, bunsetsuSearch: bunsetsu) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }
    func testActualServiceBunsetsuIncludesAllThreeAuxiliaryCompletions() throws {
        let value = ConversionService(directory: try base()); value.setEnglishReading(false)
        let response = try convert(value)
        // df1f383: token cost + 1000 per extra UTF-16 unit, standard.
        XCTAssertEqual(response.candidates.first { $0.text == "🧪" }?.score, 1_100)
        XCTAssertEqual(response.candidates.first { $0.text == "(^_^)" }?.score, 1_200)
        XCTAssertEqual(response.candidates.first { $0.text == "☆" }?.score, 1_300)
    }
    func testAndroidLookaheadAggressivenessMinimumExactAndMaximumBounds() throws {
        let value = ConversionService(directory: try base(yomi: "あいうえおか")); value.setEnglishReading(false)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        XCTAssertFalse(try convert(value).candidates.contains { ["🧪", "(^_^)", "☆"].contains($0.text) })
        for (setting, penalty) in [(JapanesePredictionAggressiveness.conservative, Int64(4_500)), (.standard, 3_000), (.aggressive, 1_500)] {
            value.setPredictionSettings(.init(lookaheadCharacterCount: 3, aggressiveness: setting))
            let response = try convert(value)
            for (text, cost) in [("🧪", Int64(100)), ("(^_^)", 200), ("☆", 300)] {
                XCTAssertEqual(response.candidates.first { $0.text == text }?.score, cost + penalty)
            }
        }
        value.setPredictionSettings(.init(lookaheadCharacterCount: 6))
        XCTAssertFalse(try convert(value, "あい").candidates.contains { $0.text == "🧪" })
        let exact = ConversionService(directory: try base(yomi: "あ")); exact.setEnglishReading(false)
        let row = try XCTUnwrap(try convert(exact, "あ").candidates.first { $0.text == "🧪" })
        XCTAssertEqual(row.score, 100); XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
        let maximum = ConversionService(directory: try base(yomi: String(repeating: "あ", count: 17)))
        maximum.setEnglishReading(false)
        XCTAssertEqual(try convert(maximum, String(repeating: "あ", count: 16)).candidates.first { $0.text == "🧪" }?.score, 1_100)
        XCTAssertFalse(try convert(maximum, String(repeating: "あ", count: 17)).candidates.contains { $0.text == "🧪" })
    }
    func testKnownOwnedEndpointsTypedUTF16AndPartialPlanRetainRemainder() throws {
        var value: ConversionService? = ConversionService(directory: try base())
        value!.setEnglishReading(false)
        let first = try convert(value!), firstGeneration = generation
        let snapshot = try XCTUnwrap(first.bunsetsuSnapshot)
        for (dictionary, text) in [("emoji", "🧪"), ("emoticon", "(^_^)"), ("symbol", "☆")] {
            let row = try XCTUnwrap(first.candidates.first { $0.text == text })
            XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
            XCTAssertEqual(row.dictionaries, [dictionary]); XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
            let owned = try XCTUnwrap(snapshot.candidates.first { $0.candidateID == row.id })
            XCTAssertEqual(owned.tokenPath?.first?.readingRange, NSRange(location: 0, length: 3))
            XCTAssertEqual(owned.leftID, 1); XCTAssertEqual(owned.rightID, 2)
        }
        let fallback = try XCTUnwrap(snapshot.candidates.first { $0.identity.surface == "あいう" && $0.tokenPath == nil })
        XCTAssertNil(fallback.leftID); XCTAssertNil(fallback.rightID)
        var session = try BunsetsuConversionSession(rawInput: "あいう末", conversionInput: "あいう", tailText: "末",
            wholeDisplayText: first.candidates[0].text, generation: firstGeneration, snapshot: snapshot,
            orderedDisplayCandidates: first.orderedDisplayIdentities)
        let token = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: generation + 1))
        let alternatives = try convert(value!)
        let records = alternatives.candidates.enumerated().map { index, row in
            BunsetsuSessionCandidate(text: row.text, reference: .conversionResult(generation: generation, candidateID: row.id),
                score: row.score, candidateIndex: index, leftID: row.leftID, rightID: row.rightID,
                matchedReadingUTF16Length: row.range.length)
        }
        XCTAssertTrue(session.installCandidates(records, responseReading: "あいう", responseGeneration: generation, for: token))
        _ = session.selectFocusedCandidate(at: try XCTUnwrap(session.segments.first?.candidateRecords.firstIndex { $0.text == "🧪" }))
        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.committedText, "🧪"); XCTAssertEqual(plan.committedReading, "あいう")
        XCTAssertEqual(plan.readingUTF16Length, 3); XCTAssertEqual(plan.nextComposingInput, "末")
        XCTAssertEqual(plan.learningFragments.first?.leftID, 1); XCTAssertEqual(plan.learningFragments.first?.rightID, 2)
        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(reading: "あいう", requestGeneration: firstGeneration + 1,
            orderedDisplayCandidates: first.orderedDisplayIdentities))
        _ = try convert(value!, "あい"); value = nil
        XCTAssertEqual(snapshot.candidates.first { $0.identity.surface == "🧪" }?.tokenPath?.first?.readingRange, NSRange(location: 0, length: 3))
        let unicode = ConversionService(directory: try base(yomi: "あ😀い")); unicode.setEnglishReading(false)
        let response = try convert(unicode, "あ😀")
        for text in ["🧪", "(^_^)", "☆"] {
            let row = try XCTUnwrap(response.candidates.first { $0.text == text })
            XCTAssertEqual(row.range, NSRange(location: 0, length: 3)); XCTAssertNotNil(Range(row.range, in: "あ😀"))
            XCTAssertEqual(row.leftID, 1); XCTAssertEqual(row.rightID, 2)
            XCTAssertEqual(response.bunsetsuSnapshot?.candidates.first { $0.candidateID == row.id }?.tokenPath?.first?.readingRange,
                NSRange(location: 0, length: 3))
        }
    }

}
