import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class LegacyTemplateCandidateTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; super.tearDown() }
    private func database() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root); return root.appendingPathComponent("learning.sqlite")
    }
    private func lexicon() -> PersonalLexicon {
        var lexicon = PersonalLexicon()
        lexicon.templates = (1...9).map { id in
            var row = PersonalWord(word: "定型固有\(id)", reading: "よみ", posScore: id * 100)
            row.id = Int64(id); return row
        }
        lexicon.words = [.init(word: "ユーザー後続", reading: "よみあ", posScore: 1000),
            .init(word: "通常登録語", reading: "かな", posScore: -1000)]
        return lexicon
    }
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64,
                         english: Bool = false, bunsetsu: Bool = false) throws -> ConversionResponse {
        let done = expectation(description: "actual legacy template candidates")
        var value: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: english, includeBunsetsu: true,
                        bunsetsuSearch: bunsetsu) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 30); return try XCTUnwrap(value).get()
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "Service learning fence"); service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testSelectsLatestEightBeforeStableScoreAndKeepsProviderPriority() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "よみあ", output: "学習先行", score: 9000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false)
        ])
        let service = ConversionService(); service.setPersonal(lexicon()); service.setLearning(url: url)
        defer { service.setLearning(url: nil); fence(service) }
        service.setLearnedPredictionSettings(.init(enabled: true, minimumInputLength: 2))
        let response = try convert(service, "よみ", generation: 1)
        let expected = (2...9).map { "定型固有\($0)" }
        XCTAssertEqual(response.candidates.filter { $0.text.hasPrefix("定型固有") }.map(\.text), expected)
        XCTAssertEqual(response.candidates.prefix(10).map(\.text), ["学習先行"] + expected + ["ユーザー後続"])
        let native = try XCTUnwrap(response.bunsetsuSnapshot)
        XCTAssertFalse(native.candidates.contains { $0.identity.surface.hasPrefix("定型固有") })
        for row in response.candidates where row.legacyTemplateReading != nil {
            XCTAssertEqual(row.legacyTemplateReading, "よみ"); XCTAssertNil(row.leftID); XCTAssertNil(row.rightID)
            XCTAssertEqual(row.range, NSRange(location: 0, length: 2))
            XCTAssertFalse(native.candidates.contains { $0.candidateID == row.id })
        }
        XCTAssertEqual(Set(response.candidates.map(\.id)).count, response.candidates.count)
        let explicit = try convert(service, "よみ", generation: 2, bunsetsu: true)
        XCTAssertEqual(explicit.candidates.filter { $0.legacyTemplateReading != nil }.map(\.text), expected)
        XCTAssertFalse(try XCTUnwrap(explicit.bunsetsuSnapshot).candidates.contains { $0.identity.surface.hasPrefix("定型固有") })
    }
    func testGateCannotLeakNativeTemplatesAndCachedEnglishRoundTripKeepsOldContract() throws {
        var personal = lexicon()
        personal.templates += (1...9).map { index in
            var row = PersonalWord(word: "EnglishTemplate\(index)", reading: "ab", posScore: -index * 1000)
            row.id = Int64(100 + index); return row
        }
        let service = ConversionService(); service.setPersonal(personal)
        service.setLegacyTemplatesEnabled(false)
        let off = try convert(service, "よみ", generation: 1)
        XCTAssertFalse(off.candidates.contains { $0.dictionaries.contains("template") || $0.text.hasPrefix("定型固有") })
        let ordinaryWord = try convert(service, "かな", generation: 2)
        XCTAssertTrue(ordinaryWord.candidates.contains { $0.text == "通常登録語" && $0.dictionaries.contains("user") })
        let english = try convert(service, "ab", generation: 3, english: true)
        XCTAssertEqual(english.candidates.filter { $0.text.hasPrefix("EnglishTemplate") }.count, 9)
        XCTAssertTrue(english.candidates.filter { $0.text.hasPrefix("EnglishTemplate") }.allSatisfy {
            $0.legacyTemplateReading == nil && $0.leftID == 0 && $0.rightID == 0
        })
        // This JP ASCII input reuses the English-loaded engine. Its personal
        // registration still must exclude all native templates while OFF.
        let cachedJP = try convert(service, "ab", generation: 4)
        XCTAssertFalse(cachedJP.candidates.contains { $0.text.hasPrefix("EnglishTemplate") })
        let englishAgain = try convert(service, "ab", generation: 5, english: true)
        XCTAssertEqual(englishAgain.candidates.filter { $0.text.hasPrefix("EnglishTemplate") }.count, 9)
        service.setLegacyTemplatesEnabled(true)
        let on = try convert(service, "ab", generation: 6)
        XCTAssertEqual(on.candidates.filter { $0.legacyTemplateReading != nil }.count, 8)
        XCTAssertFalse(on.candidates.contains { $0.text == "EnglishTemplate1" })
        XCTAssertTrue(on.candidates.filter { $0.legacyTemplateReading != nil }.allSatisfy { $0.leftID == nil && $0.rightID == nil })
        let noPrefix = try convert(service, "よ", generation: 7)
        XCTAssertFalse(noPrefix.candidates.contains { $0.legacyTemplateReading != nil })
    }
    func testOrdinaryLegacyTemplateSelectionDoesNotWriteLearning() throws {
        let url = try database(); try LearningStore(url: url).record(reading: "旧", text: "既存")
        let before = try LearningStore(url: url).snapshot()
        let service = ConversionService(); service.setPersonal(lexicon()); service.setLearning(url: url)
        defer { service.setLearning(url: nil); fence(service) }
        let response = try convert(service, "よみ", generation: 1)
        let rank = try XCTUnwrap(response.candidates.firstIndex { $0.legacyTemplateReading != nil })
        let selected = response.candidates[rank]
        service.commitSelection(generation: response.generation, candidate: selected, rank: rank,
            input: "よみ", remaining: "", learnFirst: true, onNotice: { XCTFail("Ordinary type46 must not save: " + $0) })
        fence(service); XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func property(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == name }) { return child.value }
            mirror = current.superclassMirror
        }
        return nil
    }
    private func session(_ surface: Sumire.KeyboardSurface) -> BunsetsuConversionSession? {
        guard let raw = property(surface, "bunsetsuSession") else { return nil }
        if let session = raw as? BunsetsuConversionSession { return session }
        return Mirror(reflecting: raw).children.first?.value as? BunsetsuConversionSession
    }
    private func key(_ id: String, _ surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func enter(_ text: String, _ surface: Sumire.KeyboardSurface) throws {
        for character in text {
            let target = descendants(surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }; return (key,index)
            }.first
            let (key,index) = try XCTUnwrap(target); key.onFlick?(try XCTUnwrap(FlickDirection(rawValue: index)))
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
        let done = expectation(description: "Surface learning fence"); surface.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testActualSurfaceOrdinaryTemplateCancelsPartialLearningAndKeepsSettingsFresh() throws {
        let url = try database(); try LearningStore(url: url).record(reading: "旧", text: "既存")
        let before = try LearningStore(url: url).snapshot(), domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.learnFirstCandidate = true
        surface.configureLearning(url: url)
        var personal = lexicon()
        personal.templates.append(.init(word: "静的{{cursor}}本文", reading: "いきます", posScore: 100))
        surface.personalLexicon = personal
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        surface.executeTextMacro = { _,_ in XCTFail("A static template is not a text-macro action") }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text,_ in marked = text }
        try enter("わたしはとうきょうにいきます", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface)
        try key("gojuon-right", surface).sendActions(for: .touchUpInside); ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["私は東京に"]); XCTAssertEqual(marked, "いきます")
        ready(surface, text: "静的{{cursor}}本文")
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "静的{{cursor}}本文")))
        fence(surface)
        XCTAssertEqual(commits, ["私は東京に", "静的{{cursor}}本文"]); XCTAssertFalse(surface.hasComposition)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        try enter("よみ", surface); ready(surface, text: "定型固有2")
        surface.configureLegacyTemplates(enabled: false); ready(surface)
        XCTAssertFalse(surface.candidateBar.candidates.contains { $0.hasPrefix("定型固有") })
        XCTAssertEqual((descendants(surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, "よみ")
        surface.configureLegacyTemplates(enabled: true); surface.invalidateComposition()
        try enter("かき", surface); ready(surface)
        XCTAssertFalse(surface.candidateBar.candidates.contains { $0.hasPrefix("定型固有") })
        fence(surface); XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
    }
    func testActualFocusedTemplateKeepsNilFragmentAndPersistsThroughRemainder() throws {
        let url = try database(); try LearningStore(url: url).record(reading: "旧", text: "既存")
        let original = try XCTUnwrap(try LearningStore(url: url).snapshot().first), domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.learnFirstCandidate = true
        surface.configureLearning(url: url)
        var personal = PersonalLexicon()
        personal.templates = [.init(word: "定型東京", reading: "とうきょう", posScore: 2000)]
        surface.personalLexicon = personal
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text,_ in marked = text }
        try enter("とうきょうあ", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface, text: "定型東京")
        var active = try XCTUnwrap(session(surface))
        let record = try XCTUnwrap(active.focusedSegment?.candidateRecords.first { $0.text == "定型東京" })
        XCTAssertNil(record.leftID); XCTAssertNil(record.rightID); XCTAssertEqual(record.score, 2000)
        let item = try XCTUnwrap(active.focusedCandidateBarItems.first { $0.text == "定型東京" })
        guard case let .segmentCandidateSelected(plan?) = active.selectFocusedCandidateBarItem(item) else { return XCTFail("Expected actual focused template plan") }
        let fragment = try XCTUnwrap(plan.learningFragments.first)
        XCTAssertEqual(fragment.reading, "とうきょう"); XCTAssertEqual(fragment.output, "定型東京")
        XCTAssertNil(fragment.leftID); XCTAssertNil(fragment.rightID)
        // df1 mergeBunsetsuCandidates retains initial 東京 before the template row.
        XCTAssertEqual(fragment.candidateScore, 2000); XCTAssertEqual(fragment.candidateIndex, 1)
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "定型東京")))
        fence(surface)
        XCTAssertEqual(commits, ["定型東京"]); XCTAssertEqual(marked, "あ"); XCTAssertTrue(surface.hasComposition)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), [original])
        ready(surface)
        let tail = try XCTUnwrap(surface.candidateBar.candidates.first)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["定型東京", tail]); XCTAssertFalse(surface.hasComposition)
        let saved = try LearningStore(url: url).snapshot()
        let persisted = try XCTUnwrap(saved.first { $0.reading == "とうきょう" && $0.text == "定型東京" })
        XCTAssertNil(persisted.leftID); XCTAssertNil(persisted.rightID)
        XCTAssertEqual(persisted.score, 1500); XCTAssertEqual(persisted.count, 1)
        XCTAssertTrue(saved.contains { $0.reading == "とうきょうあ" && $0.text == "定型東京" + tail && $0.isPhrase })
        XCTAssertEqual(saved.first { $0.reading == original.reading && $0.text == original.text }, original)
    }
    func testActualUnsplitWholeTemplateRemainsInitialChoiceInNew24() throws {
        let domain = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.personalLexicon = lexicon()
        defer { surface.invalidateComposition() }
        var marked = ""
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text,_ in marked = text }
        try enter("よみ", surface); ready(surface, text: "定型固有2")
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface, text: "定型固有2")
        XCTAssertEqual(surface.candidateBar.candidates.first, "定型固有2",
            "df1 unsplit projection must retain the first merged plain whole-reading template")
        XCTAssertEqual(marked, "定型固有2")
        surface.invalidateComposition()
        var whole = PersonalLexicon()
        whole.templates = [.init(word: "全体定型本文", reading: "わたしはとうきょうにいきます", posScore: 100)]
        surface.personalLexicon = whole
        try enter("わたしはとうきょうにいきます", surface); ready(surface, text: "全体定型本文")
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface)
        let split = try XCTUnwrap(session(surface))
        XCTAssertGreaterThan(split.segments.count, 1)
        XCTAssertEqual(split.eligibleWholeCandidateDisplayText, "全体定型本文")
        XCTAssertNotEqual(marked, "全体定型本文", "The whole override must not replace split intervals")
        XCTAssertEqual(marked, split.displayText)
    }

}
