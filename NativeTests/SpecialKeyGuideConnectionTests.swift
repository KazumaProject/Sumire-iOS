#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor
final class SpecialKeyGuideConnectionTests: XCTestCase {
    func testSpecialGuidesFollowAppearanceAndComposition() throws {
        let domain = "special-guides-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("builtin:sumire", forKey: "keyboard.lastUsed")
        defaults.set("toggle", forKey: "sumire.keyArrangement")
        var special = KeyboardAppearance.load(.sumire, group: .special, defaults: defaults)
        special.guidesVisible = true
        special.guideFontSize = 8
        special.save(.sumire, group: .special, defaults: defaults)
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.reloadAppearance()
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        surface.layoutIfNeeded()
        func deleteKey() throws -> Sumire.DirectionalActionKey {
            try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-delete_key" } as? Sumire.DirectionalActionKey)
        }
        func leftGuide(_ key: UIView) throws -> UILabel {
            try XCTUnwrap(descendants(key).first { $0.accessibilityIdentifier == "flick-guide-left" } as? UILabel)
        }
        XCTAssertEqual(try leftGuide(deleteKey()).text, "区切削除")
        let character = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-a" } as? UIButton)
        XCTAssertTrue(character.accessibilityActivate())
        XCTAssertEqual(try leftGuide(deleteKey()).text, "全削除")
        special.guidesVisible = false
        special.save(.sumire, group: .special, defaults: defaults)
        surface.reloadAppearance()
        XCTAssertFalse(descendants(try deleteKey()).contains {
            $0.accessibilityIdentifier == "flick-guide-left" && !$0.isHidden
        })
    }
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
#endif
