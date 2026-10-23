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
        var actions = SumireSpecialKeySettings()
        try actions.set(.insertColon, for: .delete, gesture: .right, arrangement: .toggle, mode: .japanese)
        try actions.save(defaults: defaults)
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.reloadAppearance()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = controller.view!
        container.addSubview(surface)
        NSLayoutConstraint.activate([surface.widthAnchor.constraint(equalToConstant: 390),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor)])
        container.layoutIfNeeded()
        surface.layoutIfNeeded()
        func deleteKey() throws -> Sumire.DirectionalActionKey {
            try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "sumire-delete_key" } as? Sumire.DirectionalActionKey)
        }
        func leftGuide(_ key: UIView) throws -> UILabel {
            try XCTUnwrap(descendants(key).first { $0.accessibilityIdentifier == "flick-guide-left" } as? UILabel)
        }
        XCTAssertEqual(try leftGuide(deleteKey()).text, "区切削除")
        let right = try XCTUnwrap(descendants(try deleteKey()).first {
            $0.accessibilityIdentifier == "flick-guide-right"
        } as? UILabel)
        XCTAssertEqual(right.text, ":")
        let originalGuideSize = right.font.pointSize
        special.guideFontSize = 12
        special.save(.sumire, group: .special, defaults: defaults)
        surface.reloadAppearance()
        container.layoutIfNeeded()
        surface.layoutIfNeeded()
        let largerGuide = try XCTUnwrap(descendants(try deleteKey()).first {
            $0.accessibilityIdentifier == "flick-guide-right"
        } as? UILabel)
        let measuredKey = try deleteKey()
        XCTAssertGreaterThan(largerGuide.font.pointSize, originalGuideSize, "key=\(measuredKey.bounds) guide=\(largerGuide.frame) surface=\(surface.bounds)")
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
