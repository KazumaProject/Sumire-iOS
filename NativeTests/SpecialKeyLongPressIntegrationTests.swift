import XCTest
import UIKit
import SumireCore
@testable import Sumire

final class SpecialKeyLongPressIntegrationTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func ready(_ surface: Sumire.KeyboardSurface) {
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 30), .completed)
    }
    func testSpaceConvertPreviewRestoresAcceptedLiveCandidateBeforeNoOpAndCommit() throws {
        let reading = "わたしはとうきょうにいきます"
        let domain = "bunsetsu-space-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var specialKeys = SumireSpecialKeySettings()
        try specialKeys.set(.doNothing, for: .cursorLeft, gesture: .tap,
                            arrangement: .toggle, mode: .japanese)
        try specialKeys.save(defaults: defaults)

        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }
        surface.liveConversion = true
        let input = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-ka"
        } as? Sumire.MultiStageFlickKey)
        let inputCallback = try XCTUnwrap(input.onCommit)
        inputCallback(.init(output: .text(reading), isTap: false, wasFlick: true,
                            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        ready(surface)
        let acceptedCandidate = try XCTUnwrap(surface.candidateBar.candidates.first)
        let acceptedPreview = marked
        XCTAssertFalse(acceptedPreview.isEmpty)
        XCTAssertNotEqual(acceptedPreview, reading)

        let space = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-space_convert_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(space.action)(.longPress)
        XCTAssertEqual(marked, reading,
                       "The first live-conversion toggle presents the hiragana form")

        let noOp = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-cursor_left_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(noOp.action)(.tap)
        XCTAssertEqual(marked, acceptedPreview,
                       "A non-confirm action must restore the accepted live-conversion display")

        let enter = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-enter_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(enter.action)(.tap)
        XCTAssertEqual(commits, [acceptedCandidate],
                       "The candidate shown again after preview dismissal must be the one committed")
        surface.invalidateComposition()
    }

    func testPendingLiveConversionResponseDoesNotReplaceSpaceKanaTogglePreview() throws {
        let reading = "わたしはとうきょうにいきます"
        let domain = "bunsetsu-space-pending-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var specialKeys = SumireSpecialKeySettings()
        try specialKeys.set(.doNothing, for: .cursorLeft, gesture: .tap,
                            arrangement: .toggle, mode: .japanese)
        try specialKeys.save(defaults: defaults)

        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.liveConversion = true
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }

        let input = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-ka"
        } as? Sumire.MultiStageFlickKey)
        try XCTUnwrap(input.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))

        // The conversion completion is dispatched asynchronously to the main
        // queue. Toggle before yielding so the response arrives during preview.
        let space = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-space_convert_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(space.action)(.longPress)
        XCTAssertEqual(marked, reading)

        ready(surface)
        XCTAssertEqual(marked, reading,
                       "A late live-conversion response must leave the temporary kana preview visible")
        let acceptedCandidate = try XCTUnwrap(surface.candidateBar.candidates.first)

        let noOp = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-cursor_left_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(noOp.action)(.tap)
        XCTAssertNotEqual(marked, reading,
                          "A non-confirm action restores the accepted live-conversion preview")

        let enter = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-enter_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(enter.action)(.tap)
        XCTAssertEqual(commits, [acceptedCandidate])
        surface.invalidateComposition()
    }

    func testSpaceConvertLongPressCyclesSplitPatternInActiveBunsetsuSession() throws {
        let reading = "わたしはとうきょうにいきます"
        let domain = "bunsetsu-space-split-cycle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.bunsetsuSeparation = true
        var marked = ""
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }

        let input = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-ka"
        } as? Sumire.MultiStageFlickKey)
        try XCTUnwrap(input.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        let space = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-space_convert_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(space.action)(.tap)
        ready(surface)
        let beforeCycleCandidates = surface.candidateBar.candidates
        XCTAssertFalse(beforeCycleCandidates.isEmpty)
        let beforeCyclePreview = marked
        let beforeCycleStatus = try XCTUnwrap(descendants(surface).compactMap { $0 as? UILabel }
            .first { $0.text?.hasPrefix("文節 ") == true }?.text)

        try XCTUnwrap(space.action)(.longPress)
        ready(surface)
        let afterCycleStatus = try XCTUnwrap(descendants(surface).compactMap { $0 as? UILabel }
            .first { $0.text?.hasPrefix("文節 ") == true }?.text)
        XCTAssertTrue(surface.candidateBar.candidates != beforeCycleCandidates ||
                      marked != beforeCyclePreview || afterCycleStatus != beforeCycleStatus,
                      "Long-pressing Space in an active session must visibly cycle the split pattern")
        surface.invalidateComposition()
    }

    func testEmptySpaceLongPressTracksHorizontalCursorMovementUntilRelease() throws {
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire,
            defaults: UserDefaults(suiteName: "space-trackpad-" + UUID().uuidString)!)
        var leftMoves = 0, rightMoves = 0
        surface.moveCursorLeft = { leftMoves += 1 }
        surface.moveCursorRight = { rightMoves += 1 }
        let space = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-space_convert_key"
        } as? Sumire.DirectionalActionKey)

        XCTAssertTrue(try XCTUnwrap(space.longPressDragEnabled)())
        try XCTUnwrap(space.action)(.longPress)
        XCTAssertTrue(surface.spaceCursorMoveModeActive)

        try XCTUnwrap(space.longPressDrag)(-30)
        XCTAssertEqual(leftMoves, 2)
        XCTAssertEqual(rightMoves, 0)
        try XCTUnwrap(space.longPressDrag)(18)
        XCTAssertEqual(leftMoves, 2)
        XCTAssertEqual(rightMoves, 1)

        try XCTUnwrap(space.longPressDragEnded)()
        XCTAssertFalse(surface.spaceCursorMoveModeActive)
        try XCTUnwrap(space.longPressDrag)(24)
        XCTAssertEqual(rightMoves, 1, "Dragging after release must not move the host caret")
        surface.invalidateComposition()
    }

    func testManualSpaceKanaTogglePreservesUTF16CaretAndCommitsDisplayedForm() throws {
        try verifyMiddleCaretKana()
        for count in [1, 2] {
            let domain = "space-kana-manual-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let surface = Sumire.KeyboardSurface()
            surface.configureAppearancePreview(.sumire, defaults: defaults)
            var marked = "", commits: [String] = [], selection = NSRange()
            surface.updateMarkedText = { marked = $0 }
            surface.updateMarkedSelection = { marked = $0; selection = $1 }
            surface.commitMarkedText = { commits.append($0) }
            let input = try XCTUnwrap(descendants(surface).first {
                $0.accessibilityIdentifier == "sumire-ka"
            } as? Sumire.MultiStageFlickKey)
            try XCTUnwrap(input.onCommit)(.init(output: .text("あ😀い"), isTap: false, wasFlick: true,
                isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
            let space = try XCTUnwrap(descendants(surface).first {
                $0.accessibilityIdentifier == "sumire-space_convert_key"
            } as? Sumire.DirectionalActionKey)
            for _ in 0..<count { try XCTUnwrap(space.action)(.longPress) }
            let expected = count == 1 ? "ア😀イ" : "あ😀い"
            XCTAssertEqual(marked, expected)
            XCTAssertEqual(selection, NSRange(location: 4, length: 0))
            ready(surface)
            XCTAssertEqual(marked, expected)
            let enter = try XCTUnwrap(descendants(surface).first {
                $0.accessibilityIdentifier == "sumire-enter_key"
            } as? Sumire.DirectionalActionKey)
            try XCTUnwrap(enter.action)(.tap)
            XCTAssertEqual(commits, [expected])
            XCTAssertFalse(surface.hasComposition)
            surface.invalidateComposition()
        }
    }

    func testRapidSplitCyclesKeepReadingAndLearningThroughPartialCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.sqlite")
        let domain = "space-split-learning-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.sumire, defaults: defaults)
        surface.bunsetsuSeparation = true
        surface.learnFirstCandidate = true
        surface.configureLearning(url: url)
        defer {
            surface.invalidateComposition()
            surface.configureLearning(url: nil)
            let closed = expectation(description: "learning store closed")
            surface.synchronizeLearning { closed.fulfill() }
            wait(for: [closed], timeout: 10)
        }
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        let input = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-ka"
        } as? Sumire.MultiStageFlickKey)
        let reading = "わたしはとうきょうにいきます"
        try XCTUnwrap(input.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
            isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
        let space = try XCTUnwrap(descendants(surface).first {
            $0.accessibilityIdentifier == "sumire-space_convert_key"
        } as? Sumire.DirectionalActionKey)
        try XCTUnwrap(space.action)(.tap)
        ready(surface)
        // Each switch starts another asynchronous candidate load. Only the
        // current pattern's token may install its result.
        try XCTUnwrap(space.action)(.longPress)
        try XCTUnwrap(space.action)(.longPress)
        ready(surface)
        XCTAssertTrue(surface.hasComposition)
        XCTAssertTrue(commits.isEmpty)
        let status = try XCTUnwrap(descendants(surface).compactMap { $0 as? UILabel }
            .first { $0.text?.hasPrefix("文節 ") == true }?.text)
        XCTAssertFalse(status.hasPrefix("文節 1/1 "), "Fixture must retain a partial-commit boundary")
        surface.candidateBar.onSelect?(0)
        XCTAssertTrue(surface.hasComposition)
        let partialFence = expectation(description: "partial learning fence")
        surface.synchronizeLearning { partialFence.fulfill() }
        wait(for: [partialFence], timeout: 10)
        XCTAssertTrue(try LearningStore(url: url).snapshot().isEmpty)
        ready(surface)
        // Select the remainder's conversion candidate. A raw-reading Enter
        // intentionally cancels learning under the existing Android contract.
        surface.candidateBar.onSelect?(0)
        XCTAssertFalse(surface.hasComposition)
        let finalFence = expectation(description: "complete learning fence")
        surface.synchronizeLearning { finalFence.fulfill() }
        wait(for: [finalFence], timeout: 10)
        let entries = try LearningStore(url: url).snapshot()
        let full = try XCTUnwrap(entries.first { $0.reading == reading && $0.text == commits.joined() })
        XCTAssertEqual(full.usageCount, 1)
        XCTAssertEqual(full.count, 1)
    }


    private func verifyMiddleCaretKana() throws {
        for live in [false, true] {
            for count in [1, 2] {
                for reading in ["あいう", "あ😀う"] {
                    let domain = "space-kana-middle-" + UUID().uuidString
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
                    defer { defaults.removePersistentDomain(forName: domain) }
                    let surface = Sumire.KeyboardSurface()
                    surface.configureAppearancePreview(.sumire, defaults: defaults)
                    surface.liveConversion = live
                    var marked = "", selection = NSRange(), commits: [String] = []
                    surface.updateMarkedText = { marked = $0 }
                    surface.updateMarkedSelection = { marked = $0; selection = $1 }
                    surface.commitMarkedText = { commits.append($0) }
                    let input = try XCTUnwrap(descendants(surface).first {
                        $0.accessibilityIdentifier == "sumire-ka"
                    } as? Sumire.MultiStageFlickKey)
                    try XCTUnwrap(input.onCommit)(.init(output: .text(reading), isTap: false, wasFlick: true,
                        isLongPress: false, direction: .up, secondDirection: nil, circularSlot: nil))
                    let left = try XCTUnwrap(descendants(surface).first {
                        $0.accessibilityIdentifier == "sumire-cursor_left_key"
                    } as? Sumire.DirectionalActionKey)
                    try XCTUnwrap(left.action)(.tap)
                    let prefix = String(reading.dropLast())
                    let caret = NSRange(location: prefix.utf16.count, length: 0)
                    XCTAssertEqual(marked, reading)
                    XCTAssertEqual(selection, caret)
                    let space = try XCTUnwrap(descendants(surface).first {
                        $0.accessibilityIdentifier == "sumire-space_convert_key"
                    } as? Sumire.DirectionalActionKey)
                    // Do not yield before toggling: old/end-caret and current
                    // middle-caret conversions must not replace this display.
                    for _ in 0..<count { try XCTUnwrap(space.action)(.longPress) }
                    let katakana = live ? count == 2 : count == 1
                    let expected = (katakana
                        ? (prefix.applyingTransform(.hiraganaToKatakana, reverse: false) ?? prefix)
                        : prefix) + "う"
                    XCTAssertEqual(marked, expected)
                    XCTAssertEqual(selection, caret)
                    ready(surface)
                    XCTAssertEqual(marked, expected)
                    XCTAssertEqual(selection, caret)
                    let enter = try XCTUnwrap(descendants(surface).first {
                        $0.accessibilityIdentifier == "sumire-enter_key"
                    } as? Sumire.DirectionalActionKey)
                    try XCTUnwrap(enter.action)(.tap)
                    XCTAssertEqual(commits, [expected])
                    XCTAssertFalse(surface.hasComposition)
                    surface.invalidateComposition()
                }
            }
        }
    }

}
