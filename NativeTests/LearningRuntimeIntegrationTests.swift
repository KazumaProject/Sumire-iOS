import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor final class LearningRuntimeIntegrationTests: XCTestCase {
    private var directories: [URL] = []
    private var surfaces: [Sumire.KeyboardSurface] = []
    override func tearDown() {
        for surface in surfaces { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        surfaces = []
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }
    private func database() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir.appendingPathComponent("learning.sqlite")
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ id: String, _ surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func enter(_ text: String, _ surface: Sumire.KeyboardSurface) throws {
        for character in text {
            let target = descendants(surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }
                return (key, index)
            }.first
            let (key, index) = try XCTUnwrap(target)
            key.onFlick?(try XCTUnwrap(FlickDirection(rawValue: index)))
        }
    }
    private func surface(_ url: URL?, bunsetsu: Bool = false, first: Bool = false) -> Sumire.KeyboardSurface {
        let result = Sumire.KeyboardSurface()
        result.configureAppearancePreview(.gojuon, defaults: UserDefaults(suiteName: "learn-test-" + UUID().uuidString)!)
        result.bunsetsuSeparation = bunsetsu
        result.learnFirstCandidate = first
        result.configureLearning(url: url)
        surfaces.append(result)
        return result
    }
    private func ready(_ surface: Sumire.KeyboardSurface) {
        let value = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 30), .completed,
            "candidates=\(surface.candidateBar.candidates); labels=\(descendants(surface).compactMap { ($0 as? UILabel)?.text })")
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "learning queue fence")
        surface.synchronizeLearning { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64) throws -> ConversionResponse {
        let done = expectation(description: "native result")
        var value: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(value).get()
    }
    private func rows(_ url: URL) throws -> [LearningStore.Entry] { try LearningStore(url: url).snapshot() }
    private func partial(_ surface: Sumire.KeyboardSurface) throws {
        var marked = "", committed = ""
        let previousCommit = surface.commitMarkedText
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { committed += $0; previousCommit?($0) }
        try enter("わたしはとうきょうにいきます", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside)
        ready(surface)
        try key("gojuon-right", surface).sendActions(for: .touchUpInside)
        ready(surface)
        surface.candidateBar.onSelect?(0)
        XCTAssertTrue(surface.hasComposition)
        fence(surface)
        XCTAssertEqual(committed, "私は東京に")
        XCTAssertEqual(marked, "いきます")
    }

    func testOrdinaryNonfirstSelectionPersistsOnceAndAffectsNewExactService() throws {
        let url = try database(), surface = surface(try database())
        surface.configureLearning(url: url)
        let reference = try convert(ConversionService(), "あ", generation: 900)
        let rank = try XCTUnwrap(reference.candidates.indices.first { $0 > 0 && reference.candidates[$0].range == NSRange(location: 0, length: 1) })
        let selected = reference.candidates[rank]
        try enter("あ", surface); ready(surface)
        surface.candidateBar.onSelect?(rank); fence(surface)
        let saved = try rows(url)
        XCTAssertEqual(saved.count, 1)
        let row = try XCTUnwrap(saved.first)
        XCTAssertEqual(row.text, selected.text)
        XCTAssertEqual(row.score, LearningScorePolicy.initial(candidateScore: Int32(clamping: selected.score), candidateIndex: Int32(rank)))
        XCTAssertEqual(row.usageCount, 1); XCTAssertEqual(row.count, 1)
        XCTAssertNil(row.leftID); XCTAssertNil(row.rightID)
        let next = ConversionService(); next.setLearning(url: url)
        XCTAssertEqual(try convert(next, "あ", generation: 901).candidates.first?.text, selected.text)
    }

    func testRankZeroPreferenceControlsOrdinaryPersistence() throws {
        for enabled in [false, true] {
            let url = try database(), surface = surface(nil, first: enabled)
            surface.configureLearning(url: url)
            try enter("あ", surface); ready(surface)
            surface.candidateBar.onSelect?(0); fence(surface)
            XCTAssertEqual(try rows(url).count, enabled ? 1 : 0)
        }
    }

    func testBunsetsuPartialThenOrdinaryFinishSavesFragmentsAndFullPhraseOnce() throws {
        let url = try database(), surface = surface(nil, bunsetsu: true, first: true)
        surface.configureLearning(url: url)
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        try partial(surface)
        XCTAssertTrue(try rows(url).isEmpty, "A partial commit must not persist yet")
        ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertFalse(surface.hasComposition)
        let saved = try rows(url)
        XCTAssertTrue(saved.contains { $0.reading == "わたしはとうきょうにいきます" && $0.text == commits.joined() && $0.isPhrase })
        XCTAssertTrue(saved.contains { $0.reading == "わたしは" })
        XCTAssertTrue(saved.contains { $0.reading == "とうきょうに" })
        XCTAssertTrue(saved.contains { $0.reading == "いきます" })
        XCTAssertTrue(saved.allSatisfy { $0.usageCount == 1 && $0.count == 1 })
    }

    func testPartialDeletionAndHostInvalidationDoNotJoinEarlierInput() throws {
        for invalidate in [false, true] {
            let url = try database(), surface = surface(nil, bunsetsu: true, first: true)
            surface.configureLearning(url: url)
            try partial(surface)
            if invalidate { surface.invalidateComposition(); try enter("あ", surface) }
            else { try key("gojuon-delete", surface).sendActions(for: .touchUpInside) }
            ready(surface)
            surface.candidateBar.onSelect?(0); fence(surface)
            XCTAssertFalse(try rows(url).contains { $0.reading.hasPrefix("わたしは") || $0.text.contains("東京") })
        }
    }

    func testPartialAppendKeepsOneSessionUntilFinalCommit() throws {
        let url = try database(), surface = surface(nil, bunsetsu: true, first: true)
        surface.configureLearning(url: url)
        try partial(surface)
        try enter("あ", surface); ready(surface)
        surface.candidateBar.onSelect?(0)
        fence(surface)
        let saved = try rows(url)
        XCTAssertTrue(saved.contains { $0.reading == "わたしはとうきょうにいきます" && $0.isPhrase })
        XCTAssertTrue(saved.contains { $0.reading == "いきますあ" })
        XCTAssertTrue(saved.allSatisfy { $0.usageCount == 1 })
    }

    func testPauseAndURLRemovalCancelPartialSession() throws {
        for pause in [false, true] {
            let url = try database(), surface = surface(nil, bunsetsu: true, first: true)
            surface.configureLearning(url: url)
            try partial(surface)
            if pause { XCTAssertTrue(surface.toggleLearningPauseForSession()) }
            else { surface.configureLearning(url: nil) }
            ready(surface)
            surface.candidateBar.onSelect?(0); fence(surface)
            XCTAssertTrue(try rows(url).isEmpty)
        }
    }

    func testOrdinaryPrefixAndRemainderShareOneCompletedLearningBatch() throws {
        let url = try database(), surface = surface(nil, first: true)
        surface.configureLearning(url: url)
        let input = "わたしはとうきょうにいきます"
        let reference = try convert(ConversionService(), input, generation: 920)
        let rank = try XCTUnwrap(reference.candidates.indices.first {
            reference.candidates[$0].range.location == 0 && reference.candidates[$0].range.length < input.utf16.count
        }, "The actual dictionary must supply a production prefix candidate")
        let selected = reference.candidates[rank]
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        try enter(input, surface); ready(surface)
        surface.candidateBar.onSelect?(rank); fence(surface)
        XCTAssertEqual(commits, [selected.text])
        XCTAssertTrue(try rows(url).isEmpty)
        let remaining = (input as NSString).substring(from: selected.range.length)
        let tailResult = try convert(ConversionService(), remaining, generation: 921)
        let tailRank = try XCTUnwrap(tailResult.candidates.indices.first { tailResult.candidates[$0].range.length == remaining.utf16.count })
        ready(surface)
        surface.candidateBar.onSelect?(tailRank); fence(surface)
        XCTAssertFalse(surface.hasComposition)
        let saved = try rows(url)
        XCTAssertTrue(saved.contains { $0.reading == input && $0.text == commits.joined() && $0.isPhrase })
        XCTAssertTrue(saved.allSatisfy { $0.usageCount == 1 })
    }

    func testBunsetsuLocalRankZeroTapRespectsFirstCandidatePreference() throws {
        let url = try database(), surface = surface(nil, bunsetsu: true, first: false)
        surface.configureLearning(url: url)
        try partial(surface)
        ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        let saved = try rows(url)
        // Android IMEService:26071 sets explicit only for an override display
        // candidate, not for tapping a local rank-zero row.
        XCTAssertTrue(saved.isEmpty)
    }

    func testExplicitOwnedOverridePlanUsesRealQueueAndStore() throws {
        let url = try database(), service = ConversionService()
        service.setLearning(url: url)
        var session = try BunsetsuConversionSession(rawInput: "あ", conversionInput: "あ",
            wholeDisplayText: "あ", generation: 950,
            splitPatterns: [try BunsetsuSplitPattern(reading: "あ", boundaries: [])])
        let local = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: 950))
        XCTAssertTrue(session.installCandidates([
            .init(text: "あ", reference: .conversionResult(generation: 950, candidateID: 0), matchedReadingUTF16Length: 1)
        ], responseReading: "あ", responseGeneration: 950, for: local))
        let token = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 951))
        let candidate = BunsetsuSessionCandidate(text: "亜", reference: .zenzLiveResult(generation: 951, candidateID: 1),
            score: 3_000, matchedReadingUTF16Length: 1)
        XCTAssertTrue(session.installZenzLiveResult(candidate, responseReading: "あ", responseGeneration: 951, for: token))
        let item = try XCTUnwrap(session.focusedCandidateBarItems.first)
        XCTAssertEqual(session.selectFocusedCandidateBarItem(item), .zenzResultSelected)
        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.learningFragments.first?.candidateIndex, 0)
        XCTAssertEqual(plan.learningFragments.first?.explicitlySelected, true)
        service.commitLearningPlan(plan, learnFirst: false) { _ in }
        let done = expectation(description: "explicit plan queue fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
        XCTAssertEqual(try rows(url).map(\.text), ["亜"])
        service.setLearning(url: nil)
        let closed = expectation(description: "release fixture database")
        service.synchronizeLearning { closed.fulfill() }; wait(for: [closed], timeout: 10)
    }

    func testStaleServiceGenerationAndIneligibleNumbersDoNotPersist() throws {
        let url = try database(), service = ConversionService()
        service.setLearning(url: url)
        let old = try convert(service, "あ", generation: 700)
        _ = try convert(service, "い", generation: 701)
        service.commit(generation: 700, candidate: try XCTUnwrap(old.candidates.first).id, learn: true) { _ in }
        let numeric = try convert(service, "123", generation: 702)
        let candidate = try XCTUnwrap(numeric.candidates.first { $0.text == "123" })
        service.commit(generation: 702, candidate: candidate.id, learn: true) { _ in }
        let done = expectation(description: "service fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
        XCTAssertTrue(try rows(url).isEmpty)
    }
}
