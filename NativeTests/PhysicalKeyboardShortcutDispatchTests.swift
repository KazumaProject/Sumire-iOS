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

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
