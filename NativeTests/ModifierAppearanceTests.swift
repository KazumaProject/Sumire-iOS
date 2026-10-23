import XCTest
import UIKit
import SumireCore
#if DEBUG
@testable import Sumire

@MainActor
final class ModifierAppearanceTests: XCTestCase {
    func testNormalGroupControlsModifierSizeAndFontAcrossLayouts() throws {
        let domain = "modifier-appearance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("toggle", forKey: "sumire.keyArrangement")
        for kind in [KeyboardKind.tenKey, .gojuon, .sumire] {
            var normal = KeyboardAppearance.load(kind, group: .normal, defaults: defaults)
            normal.keyScale = 0.7; normal.keyFontSize = 31
            normal.save(kind, group: .normal, defaults: defaults)
            var special = KeyboardAppearance.load(kind, group: .special, defaults: defaults)
            special.keyScale = 1; special.keyFontSize = 12
            special.save(kind, group: .special, defaults: defaults)
            let surface = Sumire.KeyboardSurface()
            surface.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
            surface.configureAppearancePreview(kind, defaults: defaults)
            surface.layoutIfNeeded()
            let buttons = descendants(surface).compactMap { $0 as? UIButton }
            let modifierID = kind == .tenKey ? "keyboard-switch" : kind == .sumire ? "sumire-dakuten_toggle_key" : nil
            let modifier = try XCTUnwrap(buttons.first { key in
                if let modifierID { return key.accessibilityIdentifier == modifierID }
                return key.accessibilityLabel == "゛小"
            }, kind.title)
            let deleteID = kind == .tenKey ? "tenkey-delete" : kind == .gojuon ? "gojuon-delete" : "sumire-delete_key"
            let delete = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == deleteID })
            try assertStyle(modifier, scale: 0.7, font: 31)
            try assertStyle(delete, scale: 1, font: 12)
            let normalID = kind == .tenKey ? "tenkey-0-0" : kind == .gojuon ? "gojuon-0-0" : "sumire-a"
            let ordinary = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == normalID })
            XCTAssertEqual(modifier.backgroundColor, ordinary.backgroundColor)
            XCTAssertNotEqual(modifier.backgroundColor, delete.backgroundColor)
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func assertStyle(_ key: UIButton, scale: CGFloat, font: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let wrapper = try XCTUnwrap(key.superview, file: file, line: line)
        wrapper.layoutIfNeeded()
        XCTAssertGreaterThan(wrapper.bounds.width, 0, file: file, line: line)
        XCTAssertEqual(key.frame.width, wrapper.bounds.width * scale, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(key.frame.height, wrapper.bounds.height * scale, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(key.titleLabel?.font.pointSize, font, file: file, line: line)
    }
}

#endif
