import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class LearnedPrefixPredictionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []
        super.tearDown()
    }
    private func database() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root); return root.appendingPathComponent("learning.sqlite")
    }
    private func seed(_ url: URL) throws {
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "あいうえお", output: "固有表記", score: 500, leftID: 2641, rightID: nil, lastUsedAt: 1000, isPhrase: false),
            .init(input: "あいうえか", output: "別固有表記", score: 100, leftID: nil, rightID: nil, lastUsedAt: 1001, isPhrase: false)
        ])
    }
    private func convert(_ service: ConversionService, _ input: String, generation: UInt64,
                         allowed: Bool = true, bunsetsu: Bool = false, english: Bool = false) throws -> ConversionResponse {
        let done = expectation(description: "real learned prefix conversion")
        var response: Result<ConversionResponse, Error>?
        service.convert(input, generation: generation, editStart: 0, english: english, includeBunsetsu: true,
                        bunsetsuSearch: bunsetsu, learnedPredictionAllowed: allowed) { response = $0; done.fulfill() }
        wait(for: [done], timeout: 30); return try XCTUnwrap(response).get()
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "learning fence"); service.synchronizeLearning { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
    private func select(_ candidate: ConversionCandidate, in response: ConversionResponse, service: ConversionService, reading: String) throws {
        let rank = try XCTUnwrap(response.candidates.firstIndex { $0.id == candidate.id })
        service.commitSelection(generation: response.generation, candidate: candidate, rank: rank,
            input: reading, remaining: "", learnFirst: true, onNotice: { XCTAssertEqual($0, "学習しました") }); fence(service)
    }
    func testServiceLongerStoredReadingCandidate() throws {
        let url = try database(); try seed(url)
        let before = try LearningStore(url: url).snapshot()
        let service = ConversionService(); service.setLearning(url: url)
        service.setLearnedPredictionSettings(.init(enabled: true))
        let response = try convert(service, "あいうえ", generation: 1)
        let selected = try XCTUnwrap(response.candidates.first { $0.text == "固有表記" })
        XCTAssertEqual(response.candidates.prefix(2).map(\.text), ["別固有表記", "固有表記"])
        XCTAssertEqual(selected.learnedPredictionReading, "あいうえお")
        XCTAssertEqual(selected.range, NSRange(location: 0, length: 4))
        XCTAssertNil(selected.leftID); XCTAssertNil(selected.rightID)
        XCTAssertFalse(try XCTUnwrap(response.bunsetsuSnapshot).candidates.contains { $0.candidateID == selected.id })
        XCTAssertEqual(Set(response.candidates.map(\.id)).count, response.candidates.count)
        try select(selected, in: response, service: service, reading: "あいうえ")
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        try select(selected, in: response, service: service, reading: "あいうえ")
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        service.setLearning(url: nil); fence(service)
    }
    func testDefaultsThresholdRoutesPauseAndConfigurationFreshness() throws {
        let url = try database(); try seed(url)
        let before = try LearningStore(url: url).snapshot()
        let service = ConversionService(); service.setLearning(url: url)
        XCTAssertFalse(try convert(service, "あいうえ", generation: 1).candidates.contains { $0.learnedPredictionReading != nil })
        service.setLearnedPredictionSettings(.init(enabled: true))
        XCTAssertFalse(try convert(service, "あいう", generation: 2).candidates.contains { $0.learnedPredictionReading != nil })
        XCTAssertFalse(try convert(service, "あいうえ", generation: 3, allowed: false).candidates.contains { $0.learnedPredictionReading != nil })
        XCTAssertFalse(try convert(service, "あいうえ", generation: 4, bunsetsu: true).candidates.contains { $0.learnedPredictionReading != nil })
        XCTAssertFalse(try convert(service, "あいうえ", generation: 5, english: true).candidates.contains { $0.learnedPredictionReading != nil })
        service.setLearningPaused(true)
        let paused = try convert(service, "あいうえお", generation: 6)
        let exact = try XCTUnwrap(paused.candidates.first { $0.learnedPredictionReading == "あいうえお" })
        try select(exact, in: paused, service: service, reading: "あいうえお")
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        service.setLearningPaused(false)
        let stale = try convert(service, "あいうえお", generation: 7)
        let old = try XCTUnwrap(stale.candidates.first { $0.learnedPredictionReading != nil })
        service.setLearnedPredictionSettings(.init(enabled: false))
        try select(old, in: stale, service: service, reading: "あいうえお")
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        service.setLearnedPredictionSettings(.init(enabled: true)); service.setLearning(url: nil)
        XCTAssertFalse(try convert(service, "あいうえ", generation: 8).candidates.contains { $0.learnedPredictionReading != nil })
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
    }
    func testExactSyntheticSelectionReinforcesOnceAndPreservesStoredKnownAndNil() throws {
        let url = try database(); try seed(url)
        let before = try LearningStore(url: url).snapshot()
        let service = ConversionService(); service.setLearning(url: url)
        service.setLearnedPredictionSettings(.init(enabled: true))
        let response = try convert(service, "あいうえお", generation: 1)
        let exact = try XCTUnwrap(response.candidates.first { $0.learnedPredictionReading == "あいうえお" })
        try select(exact, in: response, service: service, reading: "あいうえお")
        let after = try LearningStore(url: url).snapshot()
        let row = try XCTUnwrap(after.first { $0.reading == "あいうえお" })
        XCTAssertEqual(row.count, 2); XCTAssertEqual(row.usageCount, 2)
        XCTAssertEqual(row.leftID, 2641); XCTAssertNil(row.rightID)
        XCTAssertEqual(after.first { $0.reading == "あいうえか" }, before.first { $0.reading == "あいうえか" })
        try select(exact, in: response, service: service, reading: "あいうえお")
        XCTAssertEqual(try LearningStore(url: url).snapshot(), after)
        service.setLearning(url: nil); fence(service)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ id: String, _ surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func enter(_ text: String, _ surface: Sumire.KeyboardSurface) throws {
        for character in text {
            let value = descendants(surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }; return (key, index)
            }.first
            let (key, index) = try XCTUnwrap(value); key.onFlick?(try XCTUnwrap(FlickDirection(rawValue: index)))
        }
    }
    private func ready(_ surface: Sumire.KeyboardSurface, text: String? = nil) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty &&
                (text == nil || surface.candidateBar.candidates.contains(text!))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed, "candidates=\(surface.candidateBar.candidates)")
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "Surface learning fence"); surface.synchronizeLearning { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
    func testActualSurfaceLongCompletionCancelsPendingPartialWithoutWritingAnyRow() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "いきますあ", output: "長い固有補完", score: 100, leftID: 2641, rightID: nil, lastUsedAt: 1, isPhrase: false)
        ])
        let before = try LearningStore(url: url).snapshot()
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.learnFirstCandidate = true
        surface.configureLearning(url: url); surface.configureLearnedPrediction(settings: .init(enabled: true))
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text, _ in marked = text }
        try enter("わたしはとうきょうにいきます", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface)
        try key("gojuon-right", surface).sendActions(for: .touchUpInside); ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["私は東京に"]); XCTAssertEqual(marked, "いきます")
        ready(surface, text: "長い固有補完")
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "長い固有補完")))
        fence(surface)
        XCTAssertEqual(commits, ["私は東京に", "長い固有補完"]); XCTAssertFalse(surface.hasComposition)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
    }
}
