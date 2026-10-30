import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor final class JapanesePredictionRuntimeTests: XCTestCase {
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
    private func base(word: String = "あいうえお") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try file(kind: 2, dimension: 1, sections: [packed([UInt16(0)]), packed([UInt16(0)]),
            packed([Int16(0)]), packed([UInt64(0)]), Data(), packed([UInt32(0), 0]), packed([UInt16(0)])])
            .write(to: root.appendingPathComponent("connection.sud"))
        try dictionary(reading: word, text: "補完", cost: 100).write(to: root.appendingPathComponent("system.sud"))
        try dictionary(reading: word, text: "分類補完", cost: 100).write(to: root.appendingPathComponent("actor.sud"))
        try dictionary(reading: word, text: "訂正\tていせい", cost: 200).write(to: root.appendingPathComponent("reading_correction.sud"))
        try dictionary(reading: "cat", text: "cat", cost: 50).write(to: root.appendingPathComponent("english.sud"))
        try Data("v1.7.277\n".utf8).write(to: root.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        return root
    }
    private func service(_ directory: URL) -> ConversionService {
        let value = ConversionService(directory: directory)
        value.setEnglishReading(false)
        return value
    }
    private func convert(_ service: ConversionService, _ reading: String, english: Bool = false) throws -> ConversionResponse {
        generation += 1
        let done = expectation(description: "real configured native completion")
        var result: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: english) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }
    func testLookaheadChangesActualServiceCompletionRange() throws {
        let value = service(try base())
        value.setPredictionSettings(.init(lookaheadCharacterCount: 1))
        let short = try convert(value, "あいう")
        XCTAssertFalse(short.candidates.contains { $0.text == "補完" }, "Android accepts only readingLength <= inputLength + lookahead")
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2))
        let expanded = try convert(value, "あいう")
        XCTAssertEqual(expanded.candidates.first { $0.text == "補完" }?.score, 16_100)
        XCTAssertEqual(expanded.candidates.first { $0.text == "補完" }?.range, NSRange(location: 0, length: 3))
        let far = service(try base(word: "あいうえおかきくけ"))
        far.setPredictionSettings(.init(lookaheadCharacterCount: 5))
        XCTAssertFalse(try convert(far, "あいう").candidates.contains { $0.text == "補完" })
        far.setPredictionSettings(.init(lookaheadCharacterCount: 6))
        XCTAssertEqual(try convert(far, "あいう").candidates.first { $0.text == "補完" }?.score, 48_100)
    }
    func testIndependentAndroidPenaltiesForSystemCategoryAndCorrection() throws {
        let value = service(try base()); value.setCategoryIDs(["actor"])
        let cases: [(JapanesePredictionAggressiveness, Int64, Int64, Int64)] = [
            (.standard, 16_100, 3_100, 16_200), (.conservative, 24_100, 4_600, 24_200), (.aggressive, 8_100, 1_600, 8_200)
        ]
        for (mode, system, category, correction) in cases {
            value.setPredictionSettings(.init(lookaheadCharacterCount: 2, aggressiveness: mode))
            let result = try convert(value, "あいう")
            XCTAssertEqual(result.candidates.first { $0.text == "補完" }?.score, system)
            XCTAssertEqual(result.candidates.first { $0.text == "分類補完" }?.score, category)
            let corrected = try XCTUnwrap(result.candidates.first { $0.text == "訂正" })
            XCTAssertEqual(corrected.score, correction)
            XCTAssertEqual(corrected.rawText, "訂正\tていせい")
            XCTAssertEqual(corrected.correctedReading, "ていせい")
            XCTAssertEqual(corrected.range, NSRange(location: 0, length: 3))
        }
    }
    func testLongSystemInputUsesFlatPenaltyWhileCorrectionUsesExtraLength() throws {
        let value = service(try base(word: "あいうえおかき"))
        let cases: [(JapanesePredictionAggressiveness, Int64, Int64)] = [
            (.standard, 6_100, 8_200), (.conservative, 9_100, 12_200), (.aggressive, 3_100, 4_200)
        ]
        for (mode, system, correction) in cases {
            value.setPredictionSettings(.init(lookaheadCharacterCount: 1, aggressiveness: mode))
            let result = try convert(value, "あいうえおか")
            XCTAssertEqual(result.candidates.first { $0.text == "補完" }?.score, system)
            XCTAssertEqual(result.candidates.first { $0.text == "訂正" }?.score, correction)
        }
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "learning queue fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    private func signature(_ response: ConversionResponse) -> [String] {
        response.candidates.map { "\($0.text)|\($0.score)|\($0.range.location):\($0.range.length)" }
    }
    func testEnglishNumericSymbolAndExactMetadataRemainIndependent() throws {
        let root = try base(), value = service(root)
        let english = signature(try convert(value, "ca", english: true))
        XCTAssertTrue(english.contains { $0.hasPrefix("cat|") })
        let numeric = signature(try convert(value, "123"))
        let symbol = signature(try convert(value, "!"))
        value.setPredictionSettings(.init(lookaheadCharacterCount: 6, aggressiveness: .aggressive))
        XCTAssertEqual(signature(try convert(value, "ca", english: true)), english)
        XCTAssertEqual(signature(try convert(value, "123")), numeric)
        XCTAssertEqual(signature(try convert(value, "!")), symbol)
        let url = root.appendingPathComponent("learning.sqlite")
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "あいう", output: "学習", score: -10_000, leftID: 0, rightID: 0, lastUsedAt: 1, isPhrase: false)
        ])
        let original = try LearningStore(url: url).snapshot()
        value.setLearning(url: url)
        defer { value.setLearning(url: nil); fence(value) }
        for config in [JapanesePredictionSettings(lookaheadCharacterCount: 1), .init(lookaheadCharacterCount: 6, aggressiveness: .aggressive)] {
            value.setPredictionSettings(config)
            let row = try XCTUnwrap(try convert(value, "あいう").candidates.first { $0.text == "学習" })
            XCTAssertEqual(row.score, -10_000)
            XCTAssertEqual(row.leftID, 0); XCTAssertEqual(row.rightID, 0)
            XCTAssertTrue(row.dictionaries.contains("learning"))
        }
        XCTAssertEqual(try LearningStore(url: url).snapshot(), original)
    }
    func testPredictionChangeRejectsOldSelectionAndKeepsPendingSurfaceReading() throws {
        let root = try base(), value = service(root), url = root.appendingPathComponent("learning.sqlite")
        value.setLearning(url: url)
        defer { value.setLearning(url: nil); fence(value) }
        let response = try convert(value, "あいう")
        let oldGeneration = generation
        let rank = try XCTUnwrap(response.candidates.indices.first { response.candidates[$0].text == "補完" })
        value.setPredictionSettings(.init(lookaheadCharacterCount: 6, aggressiveness: .aggressive))
        value.commitSelection(generation: oldGeneration, candidate: response.candidates[rank], rank: rank,
            input: "あいう", remaining: "", learnFirst: true) { _ in }
        fence(value)
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
        let domain = "prediction-surface-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        defer { surface.invalidateComposition() }
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.liveConversion = true
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-ka" } as? Sumire.MultiStageFlickKey)
        let reading = "わたしはとうきょうにいきます"
        try XCTUnwrap(input.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        surface.predictionSettings = .init(lookaheadCharacterCount: 6, aggressiveness: .aggressive)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual((descendants(surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, reading)
        XCTAssertTrue(surface.hasComposition); XCTAssertTrue(commits.isEmpty)
    }
    func testTypedAggregateConfigurationKeepsFullFamilyAndPartialLeafSelection() throws {
        let root = try base()
        let ids = DictionaryCategoryCatalog.categories.filter { $0.legacyFamilies.contains("person") }.map(\.id)
        for id in ids {
            let url = root.appendingPathComponent(id + ".sud")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dictionary(reading: "あいうえお", text: "葉補完", cost: 100).write(to: url)
        }
        let incoming = root.appendingPathComponent("incoming.sud")
        try dictionary(reading: "あいうえお", text: "集約補完", cost: 100).write(to: incoming)
        let loaded = try DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
            .publish(importedFiles: [:], from: root, supportFallback: root,
                     legacyAggregateOverlays: [.init(rawValue: "person"): incoming], importMode: .typedLegacyAggregate)
        XCTAssertTrue(loaded.hasCurrentVerifiedReleaseProvenance)
        let value = ConversionService(sources: [.init(generation: loaded)])
        value.setEnglishReading(false); value.setCategoryIDs(ids)
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2))
        let full = try XCTUnwrap(try convert(value, "あいう").candidates.first { $0.text == "集約補完" })
        XCTAssertEqual(full.score, 3_100); XCTAssertEqual(full.classifiedCategories, ["legacy_aggregates/person"])
        value.setPredictionSettings(.init(lookaheadCharacterCount: 2, aggressiveness: .aggressive))
        XCTAssertEqual(try convert(value, "あいう").candidates.first { $0.text == "集約補完" }?.score, 1_600)
        value.setCategoryIDs(["actor"])
        let partial = try convert(value, "あいう")
        XCTAssertFalse(partial.candidates.contains { $0.text == "集約補完" })
        XCTAssertEqual(partial.candidates.first { $0.text == "葉補完" }?.score, 1_600)
    }

}
