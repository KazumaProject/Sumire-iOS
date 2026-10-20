import XCTest
import UIKit
import SumireCore
#if DEBUG
@testable import Sumire

@MainActor
final class SpecialKeyGuideTests: XCTestCase {
    private let titles: [FlickDirection: String] = [.tap: "無視", .left: "全消", .up: "前", .right: "右", .down: "次"]
    private func guides(_ key: UIButton) -> [UILabel] {
        key.subviews.compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier?.hasPrefix("flick-guide-") == true }
    }

    func testDefaultOffAndReconfigurationReuseLabelsWithoutChangingCenterOrActivation() {
        let key = Sumire.DirectionalActionKey(frame: CGRect(x: 0, y: 0, width: 90, height: 64))
        key.setTitle("削除", for: .normal)
        let font = UIFont.systemFont(ofSize: 18)
        key.titleLabel?.font = font
        var actions: [SumireSpecialKeyGesture] = []
        key.action = { actions.append($0) }
        key.layoutIfNeeded()
        XCTAssertTrue(guides(key).isEmpty)
        key.configureGuides(titles: titles, visible: false, fontSize: 10, color: .blue)
        XCTAssertTrue(guides(key).isEmpty)
        key.configureGuides(titles: titles, visible: true, fontSize: 10, color: .blue)
        key.layoutIfNeeded()
        let original = guides(key)
        XCTAssertEqual(original.count, 4)
        XCTAssertEqual(Set(original.compactMap(\.accessibilityIdentifier)), Set(["flick-guide-left", "flick-guide-up", "flick-guide-right", "flick-guide-down"]))
        XCTAssertTrue(original.allSatisfy { !$0.isUserInteractionEnabled && !$0.isAccessibilityElement })
        key.configureGuides(titles: titles, visible: true, fontSize: 10, color: .blue)
        XCTAssertEqual(Set(guides(key).map(ObjectIdentifier.init)), Set(original.map(ObjectIdentifier.init)))
        key.configureGuides(titles: [.left: "戻す", .right: ""], visible: true, fontSize: 8, color: .red)
        key.layoutIfNeeded()
        XCTAssertEqual(guides(key).filter { !$0.isHidden }.map(\.text), ["戻す"])
        XCTAssertEqual(guides(key).first { !$0.isHidden }?.textColor, .red)
        key.configureGuides(titles: titles, visible: false, fontSize: 8, color: .red)
        key.layoutIfNeeded()
        XCTAssertTrue(guides(key).allSatisfy(\.isHidden))
        XCTAssertEqual(key.currentTitle, "削除")
        XCTAssertEqual(key.titleLabel?.font, font)
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(actions, [.tap])
    }

    func testGuidesStayInsideSmallKeysAndOutsideTitleAndIcon() throws {
        for size in [CGSize(width: 90, height: 64), CGSize(width: 44, height: 44), CGSize(width: 24, height: 24)] {
            for useImage in [false, true] {
                let key = Sumire.DirectionalActionKey(frame: CGRect(origin: .zero, size: size))
                let icon = try XCTUnwrap(UIImage(systemName: "delete.left"))
                if useImage { key.setImage(icon, for: .normal) }
                else { key.setTitle("削除", for: .normal) }
                key.configureGuides(titles: titles, visible: true, fontSize: 22, color: .label)
                key.layoutIfNeeded()
                let center = key.contentRect(forBounds: key.bounds)
                let labels = guides(key).filter { !$0.isHidden }
                XCTAssertEqual(labels.count, 4)
                for label in labels {
                    XCTAssertTrue(key.bounds.contains(label.frame))
                    XCTAssertFalse(label.frame.intersects(center))
                    XCTAssertGreaterThan(label.font.pointSize, 0)
                    XCTAssertLessThanOrEqual(label.font.pointSize, 22)
                    for other in labels where other !== label { XCTAssertFalse(label.frame.intersects(other.frame)) }
                }
                if useImage {
                    XCTAssertEqual(key.currentImage, icon)
                    XCTAssertTrue(center.contains(key.imageRect(forContentRect: center)))
                } else {
                    XCTAssertEqual(key.currentTitle, "削除")
                    XCTAssertTrue(center.contains(key.titleRect(forContentRect: center)))
                }
            }
        }
    }
}
#endif
