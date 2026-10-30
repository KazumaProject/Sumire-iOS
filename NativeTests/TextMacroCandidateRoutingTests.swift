import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class TextMacroCandidateRoutingTests: XCTestCase {
    private final class Fixture {
        let domain = UUID().uuidString
        let defaults: UserDefaults
        let root: URL
        let url: URL
        let surface = Sumire.KeyboardSurface()
        let id = "11111111-1111-4111-8111-111111111111"
        var marked = "", commits: [String] = [], macroCalls: [String] = []
        init(groups: Bool = true, name: String = "マクロ表示", reading: String = "よみ", live: Bool = false, english: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            url = root.appendingPathComponent("learning.sqlite")
            try LearningStore(url: url).record(reading: "旧", text: "既存")
            if groups {
                try LearningStore(url: url).upsertLearningEntries([
                    .init(input: "よみあ", output: "学習先行", score: 100, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false)
                ])
            }
            surface.configureAppearancePreview(english ? .english : .gojuon, defaults: defaults)
            surface.liveConversion = live; surface.bunsetsuSeparation = false; surface.learnFirstCandidate = true
            surface.configureLearning(url: url)
            surface.configureLearnedPrediction(settings: .init(enabled: groups, minimumInputLength: 2))
            var personal = PersonalLexicon()
            if groups {
                personal.templates = [.init(word: "静的定型", reading: "よみ", posScore: 200)]
                personal.words = [.init(word: "ユーザー後続", reading: "よみあ", posScore: 300)]
            }
            personal.textMacros = [.init(id: id, name: name, reading: reading, body: "展開本文", enabled: true)]
            surface.personalLexicon = personal
            surface.updateMarkedText = { [weak self] in self?.marked = $0 }
            surface.updateMarkedSelection = { [weak self] text,_ in self?.marked = text }
            surface.commitMarkedText = { [weak self] in self?.commits.append($0) }
            surface.executeTextMacro = { [weak self] id,_ in self?.macroCalls.append(id) }
        }
    }
    private var fixtures: [Fixture] = []
    override func tearDown() {
        for f in fixtures {
            f.surface.invalidateComposition(); f.surface.configureLearning(url: nil)
            f.surface.personalLexicon = PersonalLexicon(); fence(f.surface)
            f.defaults.removePersistentDomain(forName: f.domain)
            try? FileManager.default.removeItem(at: f.root)
        }
        fixtures = []; super.tearDown()
    }
    private func fixture(groups: Bool = true, name: String = "マクロ表示", reading: String = "よみ", live: Bool = false, english: Bool = false) throws -> Fixture {
        let f = try Fixture(groups: groups, name: name, reading: reading, live: live, english: english)
        fixtures.append(f); return f
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func property(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == name }) { return value.value }
            mirror = current.superclassMirror
        }
        return nil
    }
    private func converted(_ f: Fixture) throws -> [Sumire.ConversionCandidate] {
        try XCTUnwrap(property(f.surface, "converted") as? [Sumire.ConversionCandidate])
    }
    private func presented(_ f: Fixture) throws -> [Sumire.ConversionCandidate] {
        try XCTUnwrap(property(f.surface, "presentedCandidates") as? [Sumire.ConversionCandidate])
    }
    private func enter(_ text: String, _ f: Fixture) throws {
        for character in text {
            let target = descendants(f.surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }; return (key,index)
            }.first
            let (key,index) = try XCTUnwrap(target); key.onFlick?(try XCTUnwrap(FlickDirection(rawValue: index)))
        }
    }
    private func ready(_ f: Fixture, text: String? = nil) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            !f.surface.candidateBar.isUpdating && !f.surface.candidateBar.candidates.isEmpty &&
                (text == nil || f.surface.candidateBar.candidates.contains(text!))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed, "candidates=\(f.surface.candidateBar.candidates)")
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "learning fence"); surface.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    private func rows(_ f: Fixture) throws -> [LearningStore.Entry] { try LearningStore(url: f.url).snapshot() }
    func testActualSurfaceProvidersPlaceMacroBetweenLegacyAndUser() throws {
        let f = try fixture(); try enter("よみ", f); ready(f, text: "マクロ表示")
        XCTAssertEqual(f.surface.candidateBar.candidates.prefix(4), ["学習先行", "静的定型", "マクロ表示", "ユーザー後続"])
        XCTAssertEqual(try presented(f).prefix(4).map(\.textMacroID), [nil,nil,f.id,nil])
    }
    func testActualMacroAndFollowingUserTapKeepDistinctRoutesAndDoNotWrite() throws {
        let f = try fixture(), before = try rows(f)
        try enter("よみ", f); ready(f, text: "マクロ表示")
        let macroIndex = try XCTUnwrap(try presented(f).firstIndex { $0.textMacroID == f.id })
        f.surface.candidateBar.onSelect?(macroIndex); fence(f.surface)
        XCTAssertEqual(f.macroCalls, [f.id]); XCTAssertEqual(f.commits, [])
        XCTAssertEqual(try rows(f), before)
        f.surface.invalidateComposition(); try enter("よみ", f); ready(f, text: "ユーザー後続")
        let userIndex = try XCTUnwrap(try presented(f).firstIndex { $0.text == "ユーザー後続" && $0.textMacroID == nil })
        XCTAssertGreaterThan(userIndex, macroIndex)
        f.surface.candidateBar.onSelect?(userIndex); fence(f.surface)
        XCTAssertEqual(f.commits, ["ユーザー後続"]); XCTAssertEqual(f.macroCalls, [f.id])
        XCTAssertEqual(try rows(f), before)
    }
    func testNativeAfterMacroKeepsLearningRankPreviewAndExpandedHighlight() throws {
        let f = try fixture(), before = try rows(f)
        try enter("よみ", f); ready(f, text: "マクロ表示")
        let nativeRows = try converted(f)
        let nativeIndex = try XCTUnwrap(nativeRows.indices.first { index in
            let c = nativeRows[index]
            return !c.dictionaries.contains(where: { ["learning","template","user"].contains($0) }) &&
                c.range == NSRange(location: 0, length: 2) && c.text != "よみ" && c.score > Int64(500 * (index + 1))
        })
        let selected = nativeRows[nativeIndex]
        let displayIndex = try XCTUnwrap(try presented(f).firstIndex { $0.textMacroID == nil && $0.id == selected.id })
        XCTAssertEqual(displayIndex, nativeIndex + 1)
        XCTAssertTrue(f.surface.performPhysicalKeyboardShortcut(.convert))
        for _ in 0..<nativeIndex { XCTAssertTrue(f.surface.performPhysicalKeyboardShortcut(.convertNext)) }
        XCTAssertEqual(f.surface.candidateBar.selectedIndex, displayIndex)
        XCTAssertEqual(f.marked, selected.text)
        f.surface.candidateBar.onExpand?()
        let expanded = try XCTUnwrap(descendants(f.surface).compactMap { $0 as? Sumire.CandidateBar }.first { $0 !== f.surface.candidateBar })
        XCTAssertEqual(expanded.selectedIndex, displayIndex)
        expanded.onSelect?(displayIndex); fence(f.surface)
        XCTAssertEqual(f.commits, [selected.text]); XCTAssertEqual(f.macroCalls, [])
        let saved = try rows(f)
        let row = try XCTUnwrap(saved.first { $0.reading == "よみ" && $0.text == selected.text })
        // Fixed Android initial learning cost uses Service candidate rank, not
        // the extra UI-only macro slot (which would subtract another 500).
        XCTAssertEqual(Int64(row.score), max(0, selected.score - Int64(500 * nativeIndex)))
        XCTAssertNotEqual(Int64(row.score), max(0, selected.score - Int64(500 * displayIndex)))
        XCTAssertEqual(row.leftID, selected.leftID); XCTAssertEqual(row.rightID, selected.rightID)
        for old in before { XCTAssertEqual(saved.first { $0.reading == old.reading && $0.text == old.text }, old) }
    }
    func testHomonymousActionAndTextRemainSeparateAndAutomaticMacroPreviewUsesRawReading() throws {
        let action = try fixture(groups: false, name: "読み"), before = try rows(action)
        try enter("よみ", action); ready(action, text: "読み")
        let macro = try XCTUnwrap(try presented(action).firstIndex { $0.text == "読み" && $0.textMacroID == action.id })
        let ordinary = try XCTUnwrap(try presented(action).firstIndex { $0.text == "読み" && $0.textMacroID == nil })
        XCTAssertNotEqual(macro, ordinary)
        action.surface.candidateBar.onSelect?(macro); fence(action.surface)
        XCTAssertEqual(action.macroCalls, [action.id]); XCTAssertEqual(action.commits, [])
        XCTAssertEqual(try rows(action), before)
        action.surface.invalidateComposition(); try enter("よみ", action); ready(action, text: "読み")
        let textIndex = try XCTUnwrap(try presented(action).firstIndex { $0.text == "読み" && $0.textMacroID == nil })
        action.surface.candidateBar.onSelect?(textIndex); fence(action.surface)
        XCTAssertEqual(action.commits, ["読み"]); XCTAssertEqual(action.macroCalls, [action.id])
        let automatic = try fixture(groups: false, name: "表示専用マクロ", live: true)
        try enter("よみ", automatic); ready(automatic, text: "表示専用マクロ")
        XCTAssertEqual(automatic.surface.candidateBar.candidates.first, "表示専用マクロ")
        XCTAssertEqual(automatic.marked, "よみ"); XCTAssertNil(automatic.surface.candidateBar.selectedIndex)
        automatic.surface.liveConversion = false; automatic.surface.liveConversion = true
        XCTAssertEqual(automatic.marked, "よみ"); XCTAssertEqual(automatic.macroCalls, [])
    }
    func testGlobalOffKeepsDefinitionAndExplicitToolbarExecutionAndRejectsStaleCandidateReply() throws {
        let f = try fixture(), before = try rows(f), definitions = f.surface.personalLexicon.textMacros
        f.surface.configureTextMacroCandidates(enabled: false)
        try enter("よみ", f); ready(f)
        XCTAssertFalse(try presented(f).contains { $0.textMacroID != nil })
        XCTAssertEqual(f.surface.personalLexicon.textMacros, definitions)
        f.surface.invalidateComposition(); f.surface.candidateBar.onTextMacros?()
        let explicit = try XCTUnwrap(descendants(f.surface).first { $0.accessibilityIdentifier == "text-macro-" + f.id } as? UIButton)
        XCTAssertTrue(explicit.isEnabled); explicit.sendActions(for: .touchUpInside); fence(f.surface)
        XCTAssertEqual(f.macroCalls, [f.id]); XCTAssertEqual(f.commits, [])
        XCTAssertEqual(try rows(f), before)
        f.surface.configureTextMacroCandidates(enabled: true)
        try enter("よみ", f); ready(f, text: "マクロ表示")
        f.surface.configureTextMacroCandidates(enabled: false); ready(f)
        XCTAssertEqual((descendants(f.surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, "よみ")
        XCTAssertFalse(try presented(f).contains { $0.textMacroID != nil })
        f.surface.configureTextMacroCandidates(enabled: true); f.surface.invalidateComposition()
        try enter("かき", f); ready(f)
        XCTAssertFalse(try presented(f).contains { $0.textMacroID != nil })
        XCTAssertEqual(f.marked, "かき"); fence(f.surface)
        XCTAssertEqual(try rows(f), before)
    }
    func testEnglishExistingPlacementIsPreservedAndFocusedBunsetsuNeverGetsNewMacro() throws {
        let english = try fixture(groups: false, name: "EnglishMacro", reading: "ab", english: true)
        for value in ["a","b"] {
            let key = try XCTUnwrap(descendants(english.surface).first { $0.accessibilityIdentifier == "qwerty-character-" + value } as? Sumire.FlickKey)
            try XCTUnwrap(key.onFlick)(.tap)
        }
        ready(english, text: "EnglishMacro")
        let originalNative = try converted(english).map(\.text)
        XCTAssertEqual(try presented(english).last?.textMacroID, english.id)
        english.surface.configureTextMacroCandidates(enabled: false); ready(english)
        XCTAssertFalse(try presented(english).contains { $0.textMacroID != nil })
        XCTAssertEqual(try converted(english).map(\.text), originalNative)
        let focused = try fixture(groups: false, name: "文節には混ぜない", reading: "とうきょう")
        focused.surface.bunsetsuSeparation = true
        try enter("とうきょうあ", focused)
        let space = try XCTUnwrap(descendants(focused.surface).first { $0.accessibilityIdentifier == "gojuon-space" } as? UIButton)
        space.sendActions(for: .touchUpInside); ready(focused, text: "東京")
        XCTAssertFalse(focused.surface.candidateBar.candidates.contains("文節には混ぜない"))
        XCTAssertEqual(focused.macroCalls, [])
    }
}
