import XCTest
import UIKit
@testable import Sumire
import SumireCore

@MainActor
final class PhysicalKeyboardShortcutDispatchTests: XCTestCase {
    func testPasteFallsThroughWhenTheExistingClipboardGateIsClosed() {
        let surface = Sumire.KeyboardSurface()
        surface.candidateBar.clipboardAccessAllowed = false
        var beforeInputCount = 0
        surface.beforeInput = { beforeInputCount += 1 }

        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.paste))
        XCTAssertEqual(beforeInputCount, 0)
    }

    func testHostCommandsAndUnsupportedAndroidActionsFallThrough() {
        let surface = Sumire.KeyboardSurface()
        let actions: [PhysicalKeyboardShortcutAction] = [
            .copy, .cut, .selectAll,
            .segmentFocusLeft, .segmentFocusRight,
            .segmentWidthShrink, .segmentWidthExpand
        ]

        for action in actions {
            XCTAssertFalse(
                surface.performPhysicalKeyboardShortcut(action),
                "\(action) must remain available to UIKit/the host until implemented"
            )
        }
    }

    func testKanaTransformShortcutsTransformTheMarkedReading() throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-shortcut-dispatch-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.reloadAppearance()

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        let key = try XCTUnwrap(descendants(of: surface).first {
            $0.accessibilityIdentifier == "gojuon-0-10"
        } as? UIButton)
        key.sendActions(for: .touchUpInside)
        XCTAssertTrue(surface.hasComposition)
        XCTAssertEqual(markedUpdates.last, "あ")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToFullKatakana))
        XCTAssertEqual(markedUpdates.last, "ア")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHiragana))
        XCTAssertEqual(markedUpdates.last, "あ")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfWidth))
        XCTAssertEqual(markedUpdates.last, "ｱ")
    }

    func testFunctionKeyConversionsAreConsumedWithoutAnActiveReading() {
        let surface = Sumire.KeyboardSurface()
        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        let actions: [PhysicalKeyboardShortcutAction] = [
            .convertToHiragana,
            .convertToFullKatakana,
            .convertToHalfWidth,
            .convertToFullAlphanumeric,
            .convertToHalfAlphanumeric
        ]

        for action in actions {
            XCTAssertTrue(
                surface.performPhysicalKeyboardShortcut(action),
                "Android consumes \(action) without an active composition"
            )
        }
        XCTAssertFalse(surface.hasComposition)
        XCTAssertTrue(markedUpdates.isEmpty)
    }

    func testF6ThroughF10ChainFromTheOriginalPrefix() throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-function-key-source-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.reloadAppearance()

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        let key = try XCTUnwrap(descendants(of: surface).first {
            $0.accessibilityIdentifier == "gojuon-0-10"
        } as? UIButton)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(markedUpdates.last, "あ")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfAlphanumeric))
        XCTAssertEqual(markedUpdates.last, "a")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHiragana))
        XCTAssertEqual(markedUpdates.last, "あ")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToFullKatakana))
        XCTAssertEqual(markedUpdates.last, "ア")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfWidth))
        XCTAssertEqual(markedUpdates.last, "ｱ")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToFullAlphanumeric))
        XCTAssertEqual(markedUpdates.last, "ａ")
    }

    func testF6ThroughF8ConvertAnEnglishCompositionFromItsOriginalRomaji() throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-japanese-script-dispatch-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        defaults.set("builtin:english", forKey: "keyboard.lastUsed")
        surface.reloadAppearance()

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.switchToEnglish))
        for character in "kana" {
            let key = try XCTUnwrap(descendants(of: surface).first {
                $0.accessibilityIdentifier == "qwerty-character-\(character)"
            } as? UIButton, "Missing QWERTY key for \(character)")
            key.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(markedUpdates.last, "kana")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHiragana))
        XCTAssertEqual(markedUpdates.last, "かな")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToFullKatakana))
        XCTAssertEqual(markedUpdates.last, "カナ")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfWidth))
        XCTAssertEqual(markedUpdates.last, "ｶﾅ")
    }

    func testF6UsesAndroidEditableMapNRuleForCustomRomajiProfile() throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-custom-romaji-dispatch-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        defaults.set("builtin:english", forKey: "keyboard.lastUsed")

        let standard = try RomajiConverter.standard()
        let profile = RomajiProfile(
            name: "カスタム",
            rules: standard.rules,
            ruleOrder: standard.ruleOrder,
            autoN: true
        )
        var library = RomajiLibrary()
        library.profiles = [profile]
        library.activeID = profile.id
        try library.save(defaults: defaults)
        surface.reloadRomaji()
        surface.reloadAppearance()

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        for character in "kanta" {
            let key = try XCTUnwrap(descendants(of: surface).first {
                $0.accessibilityIdentifier == "qwerty-character-\(character)"
            } as? UIButton, "Missing QWERTY key for \(character)")
            key.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(markedUpdates.last, "kanta")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHiragana))
        XCTAssertEqual(markedUpdates.last, "かんた")
    }

    func testRegularInputResetsTheRetainedFunctionKeySource() throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-function-key-reset-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.reloadAppearance()

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        let aKey = try XCTUnwrap(descendants(of: surface).first {
            $0.accessibilityIdentifier == "gojuon-0-10"
        } as? UIButton)
        aKey.sendActions(for: .touchUpInside)
        XCTAssertEqual(markedUpdates.last, "あ")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfAlphanumeric))
        XCTAssertEqual(markedUpdates.last, "a")

        let iKey = try XCTUnwrap(descendants(of: surface).first {
            $0.accessibilityIdentifier == "gojuon-1-10"
        } as? UIButton)
        iKey.sendActions(for: .touchUpInside)
        XCTAssertEqual(markedUpdates.last, "aい")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToFullAlphanumeric))
        XCTAssertEqual(markedUpdates.last, "ａｉ")
    }

    func testF10MarkedOutputSurvivesLiveConversionCandidatesAndToggle() async throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-function-key-live-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.reloadAppearance()
        let expectedF10Output = PhysicalKeyboardAlphabeticConversion.convert(
            "にほんご", to: .half, using: try RomajiConverter.standard()
        )
        let distinctiveLiveCandidate = "ライブ変換検証候補"
        var personalLexicon = PersonalLexicon()
        personalLexicon.words = [PersonalWord(
            word: distinctiveLiveCandidate,
            reading: expectedF10Output,
            posScore: -1_000_000
        )]
        surface.personalLexicon = personalLexicon
        surface.liveConversion = true

        var markedUpdates: [String] = []
        surface.updateMarkedText = { markedUpdates.append($0) }
        for identifier in ["gojuon-1-6", "gojuon-4-5", "gojuon-2-1", "gojuon-4-9", "gojuon-4-1"] {
            let key = try XCTUnwrap(descendants(of: surface).first {
                $0.accessibilityIdentifier == identifier
            } as? UIButton, "Missing Gojuon key \(identifier)")
            key.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(markedUpdates.last, "にほんご")

        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertToHalfAlphanumeric))
        XCTAssertNotEqual(expectedF10Output, "にほんご")
        XCTAssertEqual(markedUpdates.last, expectedF10Output)

        let candidatesReady = expectation(description: "live conversion candidates arrive for F10 output")
        Task { @MainActor in
            for _ in 0..<400 {
                if !surface.candidateBar.isUpdating {
                    candidatesReady.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        await fulfillment(of: [candidatesReady], timeout: 12)
        XCTAssertFalse(surface.candidateBar.isUpdating)
        let firstCandidate = try XCTUnwrap(surface.candidateBar.candidates.first)
        XCTAssertEqual(firstCandidate, distinctiveLiveCandidate, "The personal entry must drive a distinct live preview")
        XCTAssertNotEqual(firstCandidate, expectedF10Output, "The fixture must distinguish the live preview from the F10 output")
        XCTAssertEqual(markedUpdates.last, expectedF10Output, "Live conversion must not overwrite the explicit F10 output")

        surface.liveConversion = false
        surface.liveConversion = true
        XCTAssertEqual(markedUpdates.last, expectedF10Output, "Toggling live conversion must preserve the current F10 output")
    }

    func testPendingConversionCannotCycleOrPreviewPreviousGeneration() async throws {
        let surface = Sumire.KeyboardSurface()
        let suite = "physical-shortcut-pending-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.reloadAppearance()
        var updates: [String] = []
        surface.updateMarkedText = { updates.append($0) }
        let a = try XCTUnwrap(descendants(of: surface).first { $0.accessibilityIdentifier == "gojuon-0-10" } as? UIButton)
        a.sendActions(for: .touchUpInside)
        for _ in 0..<400 {
            if !surface.candidateBar.isUpdating { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(surface.candidateBar.isUpdating, "Initial conversion must finish")
        XCTAssertFalse(surface.candidateBar.candidates.isEmpty, "Need real initial candidates for stale-generation regression")
        let i = try XCTUnwrap(descendants(of: surface).first { $0.accessibilityIdentifier == "gojuon-1-10" } as? UIButton)
        i.sendActions(for: .touchUpInside)
        XCTAssertTrue(surface.candidateBar.isUpdating)
        XCTAssertEqual(updates.last, "あい")
        let before = updates
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convert))
        XCTAssertEqual(updates, before, "Space must wait for current-generation candidates")
        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertFalse(surface.performPhysicalKeyboardShortcut(.convertPrevious))
        XCTAssertEqual(updates, before, "Pending Down/Up must not preview old candidates")
        for _ in 0..<400 {
            if !surface.candidateBar.isUpdating { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(surface.candidateBar.isUpdating, "Current-generation conversion must finish")
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertNext))
        XCTAssertTrue(surface.performPhysicalKeyboardShortcut(.convertPrevious))
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
