import XCTest
import UIKit
import SumireCore
@testable import Sumire

final class BunsetsuRuntimeIntegrationTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ id: String, in surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func enter(_ text: String, in surface: Sumire.KeyboardSurface) throws {
        for character in text {
            let target = descendants(surface).compactMap { $0 as? Sumire.FlickKey }.compactMap { key -> (Sumire.FlickKey, Int)? in
                guard let index = key.directionalValues?.firstIndex(of: String(character)) else { return nil }
                return (key, index)
            }.first
            let (key, index) = try XCTUnwrap(target, "Missing production gojuon output")
            key.onFlick?(try XCTUnwrap(FlickDirection(rawValue: index)))
        }
    }
    private func ready(_ surface: Sumire.KeyboardSurface) {
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && !surface.candidateBar.candidates.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 30), .completed)
    }
    private func makeSurface() -> Sumire.KeyboardSurface {
        let surface = Sumire.KeyboardSurface()
        let defaults = UserDefaults(suiteName: "bunsetsu-runtime-" + UUID().uuidString)!
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.bunsetsuSeparation = true
        return surface
    }
    func testProductionFocusCandidateTapCommitsPrefixAndRetainsReadingForEdit() throws {
        let surface = makeSurface()
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }
        try enter("わたしはとうきょうにいきます", in: surface)
        try key("gojuon-space", in: surface).sendActions(for: .touchUpInside)
        ready(surface)
        try key("gojuon-right", in: surface).sendActions(for: .touchUpInside)
        ready(surface)
        surface.candidateBar.onSelect?(0)
        XCTAssertEqual(commits, ["私は東京に"])
        XCTAssertTrue(surface.hasComposition)
        XCTAssertEqual(marked, "いきます")
        try enter("あ", in: surface)
        XCTAssertEqual(marked, "いきますあ")
        try key("gojuon-delete", in: surface).sendActions(for: .touchUpInside)
        XCTAssertEqual(marked, "いきます")
        surface.invalidateComposition()
    }
    func testOrdinaryCandidateSelectionAndDeleteRemainOnExistingRoute() throws {
        let surface = makeSurface()
        surface.bunsetsuSeparation = false
        var marked = "", commits: [String] = []
        surface.updateMarkedText = { marked = $0 }
        surface.updateMarkedSelection = { text, _ in marked = text }
        surface.commitMarkedText = { commits.append($0) }
        try enter("あい", in: surface)
        try key("gojuon-delete", in: surface).sendActions(for: .touchUpInside)
        XCTAssertEqual(marked, "あ")
        ready(surface)
        let candidate = try XCTUnwrap(surface.candidateBar.candidates.first)
        surface.candidateBar.onSelect?(0)
        XCTAssertEqual(commits, [candidate])
        XCTAssertFalse(surface.hasComposition)
    }

    func testPendingBunsetsuResponseCannotReviveInvalidatedComposition() throws {
        let surface = makeSurface()
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }
        try enter("わたしはとうきょうにいきます", in: surface)
        try key("gojuon-space", in: surface).sendActions(for: .touchUpInside)
        surface.invalidateComposition()
        // The next ordinary request fences queued old work on the same service.
        try enter("あ", in: surface)
        ready(surface)
        XCTAssertFalse(surface.candidateBar.candidates.contains("私は"))
        XCTAssertTrue(commits.isEmpty)
        surface.invalidateComposition()
    }
}
