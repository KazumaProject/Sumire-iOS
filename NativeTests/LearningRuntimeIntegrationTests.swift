import XCTest
import UIKit
import SumireCore
import SQLite3
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

    func testOrdinaryNonfirstSelectionPersistsOnceAndUsesStoredMetadataCost() throws {
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
        XCTAssertEqual(row.leftID, selected.leftID)
        XCTAssertEqual(row.rightID, selected.rightID)
        let next = ConversionService(); next.setLearning(url: url)
        let after = try convert(next, "あ", generation: 901)
        let retained = try XCTUnwrap(after.candidates.first { $0.text == selected.text })
        // Android uses persisted word cost plus the actual connection costs;
        // a nonfirst selection does not promise an unconditional first rank.
        let probeURL = try database()
        try LearningStore(url: probeURL).upsertLearningEntries([
            .init(input: "あ", output: "接続費用", score: 0,
                  leftID: row.leftID, rightID: row.rightID, lastUsedAt: 1, isPhrase: false)
        ])
        let probeService = ConversionService(); probeService.setLearning(url: probeURL)
        let probe = try XCTUnwrap(try convert(probeService, "あ", generation: 902).candidates.first {
            $0.text == "接続費用" && $0.dictionaries.contains("learning")
        })
        XCTAssertEqual(retained.score, min(selected.score, probe.score + Int64(row.score)),
                       "A cheaper existing node must survive Android's same-text/IDs deduplication")
        XCTAssertEqual(retained.leftID, row.leftID)
        XCTAssertEqual(retained.rightID, row.rightID)
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
    private func updateSQL(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testPersistedMetadataScoresAndIDsReachNativeOwnedResults() throws {
        let url = try database()
        let store = try LearningStore(url: url)
        try store.upsertLearningEntries([
            .init(input: "😀", output: "低学習", score: 0, leftID: 1, rightID: 2, lastUsedAt: 1, isPhrase: true),
            .init(input: "😀", output: "高学習", score: 1000, leftID: 1, rightID: 2, lastUsedAt: 2, isPhrase: true)
        ])
        let service = ConversionService(); service.setLearning(url: url)
        let result = try convert(service, "😀", generation: 1)
        let low = try XCTUnwrap(result.candidates.firstIndex { $0.text == "低学習" })
        let high = try XCTUnwrap(result.candidates.firstIndex { $0.text == "高学習" })
        XCTAssertLessThan(low, high)
        XCTAssertEqual(result.candidates[high].score - result.candidates[low].score, 1000)
        XCTAssertEqual(result.candidates[low].leftID, 1)
        XCTAssertEqual(result.candidates[low].rightID, 2)
        XCTAssertEqual(result.candidates[low].dictionaries, ["learning"])
        _ = try convert(service, "あ", generation: 2)
        XCTAssertEqual(result.candidates[low].text, "低学習")
        XCTAssertEqual(result.candidates[low].leftID, 1, "The result owns IDs after native replacement")
        let reopened = try rows(url)
        XCTAssertEqual(reopened.first { $0.text == "高学習" }?.score, 1000)
        XCTAssertTrue(reopened.allSatisfy(\.isPhrase))
    }

    func testNativeOverlayUsesInteriorReadingAndPhraseRows() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "😀い", output: "顔伊", score: 0, leftID: 1, rightID: 2, lastUsedAt: 1, isPhrase: false),
            .init(input: "あ😀い", output: "全句", score: 0, leftID: 1, rightID: 2, lastUsedAt: 2, isPhrase: true)
        ])
        let service = ConversionService(); service.setLearning(url: url)
        let result = try convert(service, "あ😀いあ", generation: 1)
        XCTAssertTrue(result.candidates.contains { $0.text.contains("顔伊") && $0.dictionaries.contains("learning") })
        XCTAssertTrue(result.candidates.contains { $0.text.contains("全句") && $0.dictionaries.contains("learning") })
        XCTAssertFalse(result.candidates.contains { $0.text == "顔伊" || $0.text == "全句" },
                       "Stored prefixes must not consume an unread suffix")
        XCTAssertTrue(result.candidates.filter { $0.dictionaries.contains("learning") }.allSatisfy {
            $0.range == NSRange(location: 0, length: "あ😀いあ".utf16.count)
        })
    }

    func testMissingEndpointsUseIndependentNativeFallbackWithoutRewritingStore() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "😀", output: "左欠", score: 0, leftID: nil, rightID: 1, lastUsedAt: 1, isPhrase: false),
            .init(input: "😀", output: "右欠", score: 0, leftID: 1, rightID: nil, lastUsedAt: 2, isPhrase: false)
        ])
        let service = ConversionService(); service.setLearning(url: url)
        let result = try convert(service, "😀", generation: 1)
        let left = try XCTUnwrap(result.candidates.first { $0.text == "左欠" })
        let right = try XCTUnwrap(result.candidates.first { $0.text == "右欠" })
        XCTAssertEqual(left.leftID, 1851); XCTAssertEqual(left.rightID, 1)
        XCTAssertEqual(right.leftID, 1); XCTAssertEqual(right.rightID, 1851)
        let saved = try rows(url)
        XCTAssertNil(saved.first { $0.text == "左欠" }?.leftID)
        XCTAssertEqual(saved.first { $0.text == "左欠" }?.rightID, 1)
        XCTAssertEqual(saved.first { $0.text == "右欠" }?.leftID, 1)
        XCTAssertNil(saved.first { $0.text == "右欠" }?.rightID)
    }

    func testPauseKeepsSuggestionsWhileURLRemovalAndInvalidRowsClearOldNativeOverlay() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "😀", output: "旧学習", score: 0, leftID: 1, rightID: 2, lastUsedAt: 1, isPhrase: false)
        ])
        let service = ConversionService(); service.setLearning(url: url)
        XCTAssertTrue(try convert(service, "😀", generation: 1).candidates.contains { $0.text == "旧学習" })
        service.setLearningPaused(true)
        let paused = try convert(service, "😀", generation: 2)
        let existing = try XCTUnwrap(paused.candidates.first { $0.text == "旧学習" })
        service.commit(generation: 2, candidate: existing.id, learn: true) { _ in
            XCTFail("Pausing must stop writes without hiding existing suggestions")
        }
        let pausedWriteFence = expectation(description: "paused write fence")
        service.synchronizeLearning { pausedWriteFence.fulfill() }
        wait(for: [pausedWriteFence], timeout: 10)
        XCTAssertEqual(try rows(url).first?.usageCount, 1)
        service.setLearningPaused(false)
        XCTAssertTrue(try convert(service, "😀", generation: 3).candidates.contains { $0.text == "旧学習" })
        service.setLearning(url: nil)
        XCTAssertFalse(try convert(service, "😀", generation: 4).candidates.contains { $0.text == "旧学習" })
        service.setLearning(url: url)
        XCTAssertTrue(try convert(service, "😀", generation: 5).candidates.contains { $0.text == "旧学習" })
        try updateSQL("UPDATE learned SET left_id=32767", at: url)
        let invalidID = try convert(service, "😀", generation: 6)
        XCTAssertNotNil(invalidID.warning)
        XCTAssertFalse(invalidID.candidates.contains { $0.text == "旧学習" })
        try updateSQL("UPDATE learned SET left_id=1", at: url)
        XCTAssertTrue(try convert(service, "😀", generation: 7).candidates.contains { $0.text == "旧学習" })
        try updateSQL("UPDATE learned SET text=''", at: url)
        let invalidText = try convert(service, "😀", generation: 8)
        XCTAssertNotNil(invalidText.warning)
        XCTAssertFalse(invalidText.candidates.contains { $0.text == "旧学習" })
        try updateSQL("UPDATE learned SET text='123'", at: url)
        XCTAssertFalse(try convert(service, "😀", generation: 9).candidates.contains { $0.text == "123" })
    }

    func testOrdinaryAndAlternateBunsetsuSelectionsPersistKnownEndpoints() throws {
        let ordinaryURL = try database(), ordinary = surface(nil)
        ordinary.configureLearning(url: ordinaryURL)
        let reference = try convert(ConversionService(), "あい", generation: 900)
        let rank = try XCTUnwrap(reference.candidates.indices.first {
            $0 > 0 && reference.candidates[$0].range == NSRange(location: 0, length: 2) &&
                reference.candidates[$0].leftID != nil && reference.candidates[$0].rightID != nil
        })
        let expected = reference.candidates[rank]
        try enter("あい", ordinary); ready(ordinary)
        XCTAssertEqual(ordinary.candidateBar.candidates[rank], expected.text)
        ordinary.candidateBar.onSelect?(rank); fence(ordinary)
        let ordinaryRow = try XCTUnwrap(try rows(ordinaryURL).first { $0.reading == "あい" && $0.text == expected.text })
        XCTAssertEqual(ordinaryRow.leftID, expected.leftID)
        XCTAssertEqual(ordinaryRow.rightID, expected.rightID)
        XCTAssertEqual(ordinaryRow.usageCount, 1)

        let url = try database(), segmented = surface(nil, bunsetsu: true, first: true)
        segmented.configureLearning(url: url)
        try enter("わたしはとうきょうにいきます", segmented)
        try key("gojuon-space", segmented).sendActions(for: .touchUpInside); ready(segmented)
        try key("gojuon-right", segmented).sendActions(for: .touchUpInside); ready(segmented)
        let local = try convert(ConversionService(), "とうきょうに", generation: 901)
        let choice = try XCTUnwrap(segmented.candidateBar.candidates.indices.dropFirst().compactMap { index -> (Int, ConversionCandidate)? in
            let text = segmented.candidateBar.candidates[index]
            guard let value = local.candidates.first(where: {
                $0.text == text && $0.leftID != nil && $0.rightID != nil && $0.range.length == "とうきょうに".utf16.count
            }) else { return nil }
            return (index, value)
        }.first)
        segmented.candidateBar.onSelect?(choice.0); fence(segmented)
        XCTAssertTrue(try rows(url).isEmpty)
        ready(segmented); segmented.candidateBar.onSelect?(0); fence(segmented)
        let stored = try XCTUnwrap(try rows(url).first { $0.reading == "とうきょうに" && $0.text == choice.1.text })
        XCTAssertEqual(stored.leftID, choice.1.leftID)
        XCTAssertEqual(stored.rightID, choice.1.rightID)
        XCTAssertEqual(stored.usageCount, 1)
        XCTAssertTrue(try rows(url).contains { $0.reading == "わたしはとうきょうにいきます" && $0.isPhrase })
    }

    private func fence(_ service: ConversionService) {
        let done = expectation(description: "mixed setting queue fence")
        service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    private func selectWhole(_ service: ConversionService, input: String, generation: UInt64) throws {
        let response = try convert(service, input, generation: generation)
        let rank = try XCTUnwrap(response.candidates.indices.first {
            response.candidates[$0].range == NSRange(location: 0, length: input.utf16.count) &&
            response.candidates[$0].text == input
        }, "Actual native result must expose a full raw candidate for this fixed fixture")
        service.commitSelection(generation: generation, candidate: response.candidates[rank], rank: rank,
            input: input, remaining: "", learnFirst: true) { _ in }
        fence(service)
    }
    func testMixedSettingControlsOnlyNewWritesAndKeepsPausedStoredSuggestions() throws {
        for enabled in [true, false] {
            let url = try database(), service = ConversionService()
            service.setLearning(url: url)
            if !enabled { service.setLearnMixedSymbolsAndNumbers(false) } // Absent setting defaults ON.
            try selectWhole(service, input: "あ1", generation: 1)
            XCTAssertEqual(try rows(url).contains { $0.reading == "あ1" && $0.text == "あ1" }, enabled)
            try selectWhole(service, input: "123", generation: 2)
            try selectWhole(service, input: "!", generation: 3)
            XCTAssertFalse(try rows(url).contains { $0.reading == "123" || $0.reading == "!" })
            service.setLearning(url: nil); fence(service)
        }
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "あ1", output: "保存済1", score: -20_000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false)
        ])
        let service = ConversionService(); service.setLearning(url: url)
        service.setLearnMixedSymbolsAndNumbers(false); service.setLearningPaused(true)
        let response = try convert(service, "あ1", generation: 10)
        XCTAssertTrue(response.candidates.contains { $0.text == "保存済1" && $0.dictionaries.contains("learning") })
        let original = try rows(url)
        try selectWhole(service, input: "あ1", generation: 11)
        XCTAssertEqual(try rows(url), original)
        service.setLearning(url: nil); fence(service)
    }
    func testMixedSettingChangeRejectsOldOrdinaryResponseButFreshPureInputLearns() throws {
        let url = try database(), service = ConversionService(); service.setLearning(url: url)
        let response = try convert(service, "あ", generation: 1)
        let rank = try XCTUnwrap(response.candidates.indices.first { response.candidates[$0].range == NSRange(location: 0, length: 1) })
        service.setLearnMixedSymbolsAndNumbers(false)
        service.commitSelection(generation: 1, candidate: response.candidates[rank], rank: rank,
            input: "あ", remaining: "", learnFirst: true) { _ in }
        fence(service)
        XCTAssertTrue(try rows(url).isEmpty, "Old async response cannot save after the setting boundary")
        try selectWhole(service, input: "あ", generation: 2)
        XCTAssertFalse(try rows(url).isEmpty, "OFF still learns pure Japanese after a fresh request")
        service.setLearning(url: nil); fence(service)
    }
    func testMixedSettingChangeCancelsSurfacePartialLearningChain() throws {
        let url = try database(), surface = surface(nil, bunsetsu: true, first: true)
        surface.configureLearning(url: url)
        try partial(surface)
        surface.learnMixedSymbolsAndNumbers = false
        for _ in 0..<5 where surface.hasComposition {
            ready(surface); surface.candidateBar.onSelect?(0)
        }
        fence(surface)
        XCTAssertFalse(surface.hasComposition)
        let saved = try rows(url)
        XCTAssertFalse(saved.isEmpty)
        XCTAssertFalse(saved.contains { $0.reading.contains("わたし") || $0.reading.contains("とうきょう") || $0.text.contains("私は東京に") })
    }

}
