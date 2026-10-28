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
            .convertToFullAlphanumeric, .convertToHalfAlphanumeric,
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
