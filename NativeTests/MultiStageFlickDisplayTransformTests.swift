import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor
final class MultiStageFlickDisplayTransformTests: XCTestCase {
    func testRefreshingGuidesRetainsViewsAndCanonicalCommit() throws {
        let key = Sumire.MultiStageFlickKey(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        key.definition = .single(.standard, map: [.tap: "a", .left: "b"], alternate: [:])
        key.configureGuides(visible: true, fontSize: 10, color: .label)
        let guide = try XCTUnwrap(key.subviews.compactMap { $0 as? UILabel }.first { $0.text == "b" })
        key.displayTransform = { $0.uppercased() }
        key.refreshDisplayedText()
        XCTAssertEqual(guide.text, "B")
        XCTAssertTrue(guide.superview === key)
        key.refreshDisplayedText()
        key.displayTransform = { $0 }
        key.refreshDisplayedText()
        XCTAssertEqual(guide.text, "b", "Refresh must start from canonical text")
        key.displayTransform = { $0.uppercased() }
        key.refreshDisplayedText()
        var committed: String?
        key.onCommit = { event in
            if case .text(let text, _) = event.output { committed = text }
        }
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(committed, "a", "Presentation must not rewrite committed output")
    }

    func testPopupDrawTransformsRawTextWithoutReplacingContent() {
        let popup = Sumire.MultiStageFlickPopupView(frame: CGRect(x: 0, y: 0, width: 150, height: 150))
        popup.update(.grid([.tap: "a", .left: "b"], selected: .tap),
                     palette: Sumire.KeyboardPalette(hue: 0.73, dark: false), fontSize: 20)
        var observed: [String] = []
        popup.displayTransform = { observed.append($0); return $0.uppercased() }
        let renderer = UIGraphicsImageRenderer(size: popup.bounds.size)
        for _ in 0..<2 {
            _ = renderer.image { _ in popup.draw(popup.bounds) }
        }
        XCTAssertEqual(observed.filter { $0 == "a" }.count, 2)
        XCTAssertEqual(observed.filter { $0 == "b" }.count, 2)
        XCTAssertFalse(observed.contains("A"))
        XCTAssertFalse(observed.contains("B"))
    }
}
