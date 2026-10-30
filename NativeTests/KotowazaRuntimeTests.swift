import XCTest
import UIKit
import CryptoKit
@testable import SumireCore
@testable import Sumire

@MainActor final class KotowazaRuntimeTests: XCTestCase {
    private var generation: UInt64 = 0
    private func convert(_ service: ConversionService, _ reading: String, bunsetsu: Bool = false) throws -> ConversionResponse {
        generation += 1
        let done = expectation(description: "real proverb conversion")
        var result: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, includeBunsetsu: true, bunsetsuSearch: bunsetsu) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "conversion queue fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testPinnedRawArchiveRealImporterStoreAndService() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_SOURCE_ZIP"])
        let archive = URL(fileURLWithPath: path)
        let archiveHash = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(archiveHash, "c4257ea563dd981678f045d38afdcdb65dadc36a9fc8e2ce45663e6706fac5cd")
        let bundle = try XCTUnwrap(ConversionService.bundledDictionary)
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("kotowaza-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        // No converter or validator closures: this is the production pipeline.
        let outcome = DictionaryArchiveImporter.perform(archive: archive, sharedContainer: container,
            categoryInterpretation: .legacyAggregate, storeImportMode: .typedLegacyAggregate, bundledSupport: bundle)
        XCTAssertTrue(outcome.succeeded, outcome.message + outcome.diagnostics.joined())
        XCTAssertEqual(Set(outcome.convertedFiles), ["connection.sud", "kotowaza.sud"])
        let store = DictionaryGenerationStore(directory: container.appendingPathComponent("Sumire/Dictionaries"))
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertTrue(loaded.hasCurrentVerifiedReleaseProvenance)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.directory.appendingPathComponent("kotowaza.sud").path))
        let value = ConversionService(sources: [.init(generation: loaded)])
        value.setEnglishReading(false)
        let response = try convert(value, "あっか")
        let row = try XCTUnwrap(response.candidates.first { $0.text == "圧巻" && $0.dictionaries.contains("kotowaza") })
        let nativeRows = try XCTUnwrap(response.bunsetsuSnapshot).candidates.filter { $0.identity.surface == "圧巻" }
        let nativeProverb = try XCTUnwrap(nativeRows.first { $0.score == 11_000 && $0.leftID == 1851 && $0.rightID == 1851 })
        XCTAssertEqual(nativeProverb.identity.readingUTF16Length, 3)
        // Existing Android display merger keeps the first candidate's behavior;
        // a later matching proverb adds provenance, not replacement metadata.
        let nativeFirst = try XCTUnwrap(nativeRows.first)
        XCTAssertEqual(row.score, nativeFirst.score)
        XCTAssertEqual(row.leftID, nativeFirst.leftID); XCTAssertEqual(row.rightID, nativeFirst.rightID)
        XCTAssertEqual(row.range, NSRange(location: 0, length: 3))
        XCTAssertTrue(try convert(value, "あっ").candidates.allSatisfy { !$0.dictionaries.contains("kotowaza") })
        XCTAssertFalse(try convert(value, "あぶは").candidates.contains { $0.text == "虻蜂取らず" && $0.dictionaries.contains("kotowaza") })
        value.setPredictionSettings(.init(lookaheadCharacterCount: 4, aggressiveness: .aggressive))
        let longer = try XCTUnwrap(try convert(value, "あぶは").candidates.first { $0.text == "虻蜂取らず" && $0.dictionaries.contains("kotowaza") })
        XCTAssertEqual(longer.score, 19_000)
        XCTAssertEqual(longer.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(longer.leftID, 1851); XCTAssertEqual(longer.rightID, 1851)
        let bunsetsu = try convert(value, "あっか", bunsetsu: true)
        XCTAssertTrue(bunsetsu.candidates.contains { $0.text == "圧巻" && $0.dictionaries.contains("kotowaza") })
        value.setKotowazaEnabled(false)
        XCTAssertTrue(try convert(value, "あっか").candidates.allSatisfy { !$0.dictionaries.contains("kotowaza") })
        XCTAssertTrue(try convert(value, "あっか", bunsetsu: true).candidates.allSatisfy { !$0.dictionaries.contains("kotowaza") })
        value.setKotowazaEnabled(true)
        let database = container.appendingPathComponent("learning.sqlite")
        value.setLearning(url: database); fence(value)
        // Obtain a fresh selection after the store change closes the native session.
        let selection = try convert(value, "あぶは")
        let selected = try XCTUnwrap(selection.candidates.first { $0.text == "虻蜂取らず" && $0.dictionaries.contains("kotowaza") })
        value.commitSelection(generation: generation, candidate: selected, rank: try XCTUnwrap(selection.candidates.firstIndex { $0.id == selected.id }), input: "あぶは", remaining: "", learnFirst: true) { _ in }
        fence(value)
        let saved = try XCTUnwrap(try LearningStore(url: database).snapshot().first { $0.text == "虻蜂取らず" })
        XCTAssertEqual(saved.reading, "あぶは"); XCTAssertEqual(saved.leftID, 1851); XCTAssertEqual(saved.rightID, 1851)
        value.setLearning(url: nil); fence(value)
        // Unrelated publication retains this independent optional dictionary.
        let republished = try store.publish(importedFiles: [:], from: loaded.directory, supportFallback: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: republished.directory.appendingPathComponent("kotowaza.sud").path))
    }
    func testSettingChangeInvalidatesOldSelectionAndPreservesSurfaceReading() throws {
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let value = ConversionService(directory: directory), database = temp.appendingPathComponent("learning.sqlite")
        value.setLearning(url: database)
        defer { value.setLearning(url: nil); fence(value) }
        let response = try convert(value, "あいう")
        let rank = try XCTUnwrap(response.candidates.indices.first)
        value.setKotowazaEnabled(false)
        value.commitSelection(generation: generation, candidate: response.candidates[rank], rank: rank,
            input: "あいう", remaining: "", learnFirst: true) { _ in }
        fence(value)
        XCTAssertTrue(try LearningStore(url: database).snapshot().isEmpty)
        let domain = "kotowaza-surface-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface(); defer { surface.invalidateComposition() }
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        var commits: [String] = []; surface.commitMarkedText = { commits.append($0) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-ka" } as? Sumire.MultiStageFlickKey)
        try XCTUnwrap(input.onCommit)(.init(output: .text("あいう"), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        surface.kotowazaEnabled = false
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !surface.candidateBar.isUpdating }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertEqual((descendants(surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, "あいう")
        XCTAssertTrue(surface.hasComposition); XCTAssertTrue(commits.isEmpty)
    }
}
