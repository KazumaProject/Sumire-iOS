import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class UserDictionaryPrefixPredictionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; super.tearDown() }
    private func database() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root); return root.appendingPathComponent("learning.sqlite")
    }
    private func lexicon() -> PersonalLexicon {
        var value = PersonalLexicon()
        value.words = [.init(word: "固有ユーザー表記", reading: "あいうえお", posIndex: 1, posScore: 100),
            .init(word: "別固有ユーザー", reading: "あいうえか", posScore: 200),
            .init(word: "短い固有表記", reading: "a", posScore: 300),
            .init(word: "英語固有", reading: "abacus", posScore: 50)]
        return value
    }
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64,
                         english: Bool = false, bunsetsu: Bool = false, allowed: Bool = true) throws -> ConversionResponse {
        let done = expectation(description: "actual user prefix conversion")
        var value: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: english, includeBunsetsu: true,
                        bunsetsuSearch: bunsetsu, userDictionaryPredictionAllowed: allowed) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 30); return try XCTUnwrap(value).get()
    }
    private func fence(_ service: ConversionService) {
        let done = expectation(description: "Service learning fence"); service.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testLongerUserReadingReachesActualServiceSuggestions() throws {
        let service = ConversionService(); service.setPersonal(lexicon())
        let response = try convert(service, "あい", generation: 1)
        XCTAssertTrue(response.candidates.contains { $0.text == "固有ユーザー表記" },
            "Android default-ON user dictionary prefix candidate must reach actual Japanese suggestions")
        let row = try XCTUnwrap(response.candidates.first { $0.text == "固有ユーザー表記" })
        XCTAssertEqual(row.userDictionaryReading, "あいうえお")
        XCTAssertEqual(row.range, NSRange(location: 0, length: 2)); XCTAssertNil(row.leftID); XCTAssertNil(row.rightID)
        XCTAssertFalse(try XCTUnwrap(response.bunsetsuSnapshot).candidates.contains { $0.candidateID == row.id })
        XCTAssertEqual(Set(response.candidates.map(\.id)).count, response.candidates.count)
    }
    func testProviderOrderLimitAndExclusionsLeaveNativeAndEnglishPersonalEntriesEnabled() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "あいうえお", output: "学習先行候補", score: 9000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false)
        ])
        let service = ConversionService(); service.setPersonal(lexicon()); service.setLearning(url: url)
        defer { service.setLearning(url: nil); fence(service) }
        service.setLearnedPredictionSettings(.init(enabled: true, minimumInputLength: 2))
        service.setUserDictionaryPredictionSettings(.init(candidateLimit: 1))
        let ordered = try convert(service, "あい", generation: 1)
        XCTAssertEqual(ordered.candidates.prefix(2).map(\.text), ["学習先行候補", "固有ユーザー表記"])
        XCTAssertEqual(ordered.candidates.filter { $0.userDictionaryReading != nil }.count, 1)
        XCTAssertFalse(try convert(service, "あ", generation: 2).candidates.contains { $0.userDictionaryReading != nil })
        XCTAssertFalse(try convert(service, "あい", generation: 3, bunsetsu: true).candidates.contains { $0.userDictionaryReading != nil })
        XCTAssertFalse(try convert(service, "あい", generation: 4, allowed: false).candidates.contains { $0.userDictionaryReading != nil })
        service.setUserDictionaryPredictionSettings(.init(enabled: false))
        XCTAssertFalse(try convert(service, "あい", generation: 5).candidates.contains { $0.userDictionaryReading != nil })
        let exact = try convert(service, "あいうえお", generation: 6)
        let native = try XCTUnwrap(exact.candidates.first { $0.text == "固有ユーザー表記" })
        XCTAssertNil(native.userDictionaryReading); XCTAssertNotNil(native.leftID); XCTAssertNotNil(native.rightID)
        XCTAssertTrue(try XCTUnwrap(exact.bunsetsuSnapshot).candidates.contains { $0.candidateID == native.id })
        let english = try convert(service, "ab", generation: 7, english: true)
        XCTAssertTrue(english.candidates.contains { $0.text == "英語固有" })
        XCTAssertFalse(english.candidates.contains { $0.userDictionaryReading != nil })
    }
    func testExactLongAndWildcardShorterUserSelectionsNeverWriteLearning() throws {
        let url = try database()
        try LearningStore(url: url).upsertLearningEntries([
            .init(input: "旧", output: "既存学習", score: 100, leftID: 2641, rightID: nil, lastUsedAt: 1, isPhrase: false)
        ])
        let before = try LearningStore(url: url).snapshot()
        let service = ConversionService(); service.setPersonal(lexicon()); service.setLearning(url: url)
        defer { service.setLearning(url: nil); fence(service) }
        for (index, reading) in ["あい", "あいうえお", "a%"].enumerated() {
            let result = try convert(service, reading, generation: UInt64(index + 1))
            let text = index == 2 ? "短い固有表記" : "固有ユーザー表記"
            let rank = try XCTUnwrap(result.candidates.firstIndex { $0.text == text })
            let selected = result.candidates[rank]
            XCTAssertNotNil(selected.userDictionaryReading); XCTAssertNil(selected.leftID); XCTAssertNil(selected.rightID)
            XCTAssertEqual(selected.range, NSRange(location: 0, length: reading.utf16.count))
            service.commitSelection(generation: result.generation, candidate: selected, rank: rank,
                input: reading, remaining: "", learnFirst: true, onNotice: { XCTFail("type28 must not report saving: " + $0) })
            fence(service)
            XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
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
    func testActualSurfacePartialThenLongUserCompletionCancelsLearningAndSettingsKeepFreshReading() throws {
        let url = try database()
        try LearningStore(url: url).record(reading: "旧", text: "既存")
        let before = try LearningStore(url: url).snapshot()
        let domain = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.learnFirstCandidate = true
        surface.configureLearning(url: url)
        var personal = lexicon()
        personal.words.append(.init(word: "長い固有ユーザー", reading: "いきますあ", posScore: 100))
        surface.personalLexicon = personal
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text,_ in marked = text }
        try enter("わたしはとうきょうにいきます", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside); ready(surface)
        try key("gojuon-right", surface).sendActions(for: .touchUpInside); ready(surface)
        surface.candidateBar.onSelect?(0); fence(surface)
        XCTAssertEqual(commits, ["私は東京に"]); XCTAssertEqual(marked, "いきます")
        ready(surface, text: "長い固有ユーザー")
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "長い固有ユーザー")))
        fence(surface)
        XCTAssertEqual(commits, ["私は東京に", "長い固有ユーザー"]); XCTAssertFalse(surface.hasComposition)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
        try enter("あい", surface); ready(surface, text: "固有ユーザー表記")
        surface.configureUserDictionaryPrediction(settings: .init(minimumInputLength: 8))
        ready(surface)
        XCTAssertEqual((descendants(surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, "あい")
        XCTAssertFalse(surface.candidateBar.candidates.contains("固有ユーザー表記"))
        surface.configureUserDictionaryPrediction(settings: .init())
        // Invalidate a pending old-prefix request before entering another reading.
        surface.invalidateComposition(); try enter("かき", surface); ready(surface)
        XCTAssertFalse(surface.candidateBar.candidates.contains("固有ユーザー表記"))
        XCTAssertEqual((descendants(surface).first { $0.accessibilityIdentifier == "compositionReading" } as? UILabel)?.text, "かき")
        fence(surface); XCTAssertEqual(try LearningStore(url: url).snapshot(), before)
    }
    func testActualSurfaceFocusedAlternativesExcludeUserCompletionAndPreserveRemainder() throws {
        let url = try database(), domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true; surface.liveConversion = false; surface.configureLearning(url: url)
        var personal = PersonalLexicon()
        personal.words = [.init(word: "未入力を含む固有ユーザー", reading: "とうきょうと", posScore: -1000)]
        surface.personalLexicon = personal
        defer { surface.invalidateComposition(); surface.configureLearning(url: nil); fence(surface) }
        var commits: [String] = [], marked = ""
        surface.commitMarkedText = { commits.append($0) }
        surface.updateMarkedText = { marked = $0 }; surface.updateMarkedSelection = { text,_ in marked = text }
        try enter("とうきょうあ", surface)
        try key("gojuon-space", surface).sendActions(for: .touchUpInside)
        ready(surface, text: "東京")
        XCTAssertFalse(surface.candidateBar.candidates.contains("未入力を含む固有ユーザー"))
        surface.candidateBar.onSelect?(try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "東京")))
        fence(surface)
        XCTAssertEqual(commits, ["東京"]); XCTAssertEqual(marked, "あ"); XCTAssertTrue(surface.hasComposition)
        surface.invalidateComposition(); fence(surface)
        XCTAssertEqual(try LearningStore(url: url).snapshot(), [])
    }
}
