import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor final class SumireEnglishQwertyIntegrationTests: XCTestCase {
    private final class Fixture {
        let domain = "sumire-qwerty-" + UUID().uuidString
        let defaults: UserDefaults
        let surface = Sumire.KeyboardSurface()
        var marked = "", commits: [String] = []
        init(enabled: Bool?) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            if let enabled { defaults.set(enabled, forKey: "sumire.englishQwerty") }
            surface.configureAppearancePreview(.sumire, defaults: defaults)
            surface.updateMarkedText = { [weak self] in self?.marked = $0 }
            surface.updateMarkedSelection = { [weak self] text, _ in self?.marked = text }
            surface.commitMarkedText = { [weak self] in self?.commits.append($0) }
        }
        deinit { defaults.removePersistentDomain(forName: domain) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func find(_ id: String) -> UIView? { descendants(surface).first { $0.accessibilityIdentifier == id } }
        func button(_ id: String) throws -> UIButton { try XCTUnwrap(find(id) as? UIButton, id) }
        func special(_ id: String) throws {
            let key = try XCTUnwrap(find("sumire-" + id) as? Sumire.DirectionalActionKey)
            try XCTUnwrap(key.action)(.tap)
        }
        func letter(_ value: String) throws {
            let key = try XCTUnwrap(find("qwerty-character-" + value) as? Sumire.FlickKey)
            try XCTUnwrap(key.onFlick)(.tap)
        }
        func text(_ reading: String) throws {
            let key = try XCTUnwrap(find("sumire-ka") as? Sumire.MultiStageFlickKey)
            try XCTUnwrap(key.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
                isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        }
    }
    private func ready(_ surface: Sumire.KeyboardSurface) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 30), .completed)
    }
    private func fence(_ surface: Sumire.KeyboardSurface) {
        let done = expectation(description: "learning fence")
        surface.synchronizeLearning { done.fulfill() }; wait(for: [done], timeout: 10)
    }
    func testEnabledEnglishModeShowsConnectedQwertyRoute() throws {
        let f = try Fixture(enabled: true)
        defer { f.surface.invalidateComposition() }
        try f.special("change_input_mode_key")
        let q = try XCTUnwrap(f.find("qwerty-character-q") as? Sumire.FlickKey)
        let back = try XCTUnwrap(f.find("sumire-qwerty-return") as? Sumire.RepeatingKey)
        XCTAssertNotNil(q.touchRouter)
        XCTAssertTrue(q.touchRouter === back.touchRouter, "Early-return QWERTY grid must share the Surface router")
        let router = try XCTUnwrap(q.touchRouter)
        XCTAssertNotNil(router.onBegin); XCTAssertNotNil(router.onEnd)
        let previousEnd = router.onEnd
        var endings = 0
        router.onEnd = { participant in endings += 1; previousEnd?(participant) }
        XCTAssertTrue(router.begin(q)); router.end(q)
        XCTAssertEqual(endings, 1)
        XCTAssertTrue(router.begin(back)); router.cancelAll()
        XCTAssertEqual(endings, 1, "Cancelled touches must not synthesize feedback release")
        XCTAssertEqual(router.activeCount, 0)
        try f.letter("q")
        XCTAssertEqual(f.marked, "q")
        XCTAssertTrue(f.commits.isEmpty)
    }
    func testAbsentAndFalseKeepExistingSumireEnglishLayout() throws {
        for enabled: Bool? in [nil, false] {
            let f = try Fixture(enabled: enabled)
            defer { f.surface.invalidateComposition() }
            try f.special("change_input_mode_key")
            XCTAssertNil(f.find("qwerty-character-q"))
            XCTAssertNil(f.find("sumire-qwerty-return"))
            XCTAssertNotNil(f.find("sumire-ka"))
            try f.text("a")
            XCTAssertEqual(f.marked, "a")
        }
    }
    func testShiftCapsAndNumberPageResetOnJapaneseReturnAndEnglishReentry() throws {
        let f = try Fixture(enabled: true)
        defer { f.surface.invalidateComposition() }
        try f.special("change_input_mode_key")
        try f.letter("q")
        try f.button("qwerty-shift").sendActions(for: .touchUpInside)
        try f.letter("q")
        XCTAssertEqual(f.marked, "qQ")
        XCTAssertEqual(try f.button("qwerty-shift").accessibilityValue, "OFF")
        try f.button("qwerty-shift").sendActions(for: .touchUpInside)
        try f.button("qwerty-shift").sendActions(for: .touchUpInside)
        XCTAssertEqual(try f.button("qwerty-shift").accessibilityValue, "Caps Lock")
        try f.letter("q"); try f.letter("q")
        XCTAssertEqual(f.marked, "qQQQ")
        try f.button("sumire-qwerty-return").sendActions(for: .touchUpInside)
        try f.special("change_input_mode_key")
        XCTAssertEqual(try f.button("qwerty-shift").accessibilityValue, "OFF")
        XCTAssertEqual(try f.button("qwerty-character-q").currentTitle, "q")
        try f.button("qwerty-page-toggle").sendActions(for: .touchUpInside)
        XCTAssertNotNil(f.find("qwerty-symbol-page-toggle"))
        XCTAssertNil(f.find("qwerty-character-q"))
        try f.button("sumire-qwerty-return").sendActions(for: .touchUpInside)
        XCTAssertNotNil(f.find("sumire-ka"))
        XCTAssertNil(f.find("qwerty-character-q"))
        XCTAssertEqual(f.marked, "qQQQ")
        XCTAssertTrue(f.commits.isEmpty)
        try f.special("change_input_mode_key")
        XCTAssertEqual(try f.button("qwerty-character-q").currentTitle, "q")
        XCTAssertEqual(try f.button("qwerty-shift").accessibilityValue, "OFF")
    }
    func testPendingJapaneseReadingSurvivesEnglishAndJapaneseReturn() throws {
        let f = try Fixture(enabled: true)
        defer { f.surface.invalidateComposition() }
        f.surface.liveConversion = true
        let reading = "わたしはとうきょうにいきます"
        try f.text(reading)
        try f.special("change_input_mode_key")
        try f.button("sumire-qwerty-return").sendActions(for: .touchUpInside)
        ready(f.surface)
        let raw = f.find("compositionReading") as? UILabel
        XCTAssertEqual(raw?.text, reading)
        XCTAssertTrue(f.surface.hasComposition)
        XCTAssertTrue(f.commits.isEmpty)
        XCTAssertNotNil(f.find("sumire-ka"))
    }
    func testPartialBunsetsuLearningKeepsCurrentRemainderAcrossModeRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("learning.sqlite")
        let f = try Fixture(enabled: true)
        defer { f.surface.invalidateComposition(); f.surface.configureLearning(url: nil); fence(f.surface) }
        f.surface.bunsetsuSeparation = true
        f.surface.learnFirstCandidate = true
        f.surface.configureLearning(url: url)
        let reading = "わたしはとうきょうにいきます"
        try f.text(reading)
        try f.special("space_convert_key"); ready(f.surface)
        let focusRight = try XCTUnwrap(f.find("sumire-cursor_left_key") as? Sumire.DirectionalActionKey)
        try XCTUnwrap(focusRight.action)(.right); ready(f.surface)
        f.surface.candidateBar.onSelect?(0)
        XCTAssertEqual(f.commits, ["私は東京に"])
        XCTAssertEqual(f.marked, "いきます")
        fence(f.surface)
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
        try f.special("change_input_mode_key")
        try f.button("sumire-qwerty-return").sendActions(for: .touchUpInside)
        XCTAssertEqual(f.marked, "いきます")
        ready(f.surface)
        f.surface.candidateBar.onSelect?(0); fence(f.surface)
        XCTAssertFalse(f.surface.hasComposition)
        let saved = try LearningStore(url: url).snapshot()
        XCTAssertTrue(saved.contains { $0.reading == reading && $0.text == f.commits.joined() && $0.isPhrase })
        XCTAssertTrue(saved.allSatisfy { $0.usageCount == 1 && $0.count == 1 })
    }
    func testPreferenceReloadKeepsReadingAndResetsQwertyPageState() throws {
        let f = try Fixture(enabled: true)
        defer { f.surface.invalidateComposition() }
        try f.special("change_input_mode_key")
        try f.letter("q")
        try f.button("qwerty-page-toggle").sendActions(for: .touchUpInside)
        XCTAssertNotNil(f.find("qwerty-symbol-page-toggle"))
        f.defaults.set(false, forKey: "sumire.englishQwerty")
        f.surface.reloadAppearance()
        XCTAssertNil(f.find("qwerty-character-q"))
        XCTAssertNotNil(f.find("sumire-ka"))
        f.defaults.set(true, forKey: "sumire.englishQwerty")
        f.surface.reloadAppearance()
        XCTAssertEqual(try f.button("qwerty-character-q").currentTitle, "q")
        XCTAssertEqual(try f.button("qwerty-shift").accessibilityValue, "OFF")
        XCTAssertEqual(f.marked, "q")
        XCTAssertTrue(f.commits.isEmpty)
    }

}
