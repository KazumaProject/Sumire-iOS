#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor
final class SpecialKeyGuideGestureTests: XCTestCase {
    private final class SampleTouch: UITouch {
        var sample = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { sample }
    }
    func testVisibleGuidesPreserveDirectionalRepeatAndLongPressWithoutReleaseDuplicate() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let key = Sumire.DirectionalActionKey(frame: CGRect(x: 20, y: 20, width: 90, height: 60))
        controller.view.addSubview(key)
        key.configureGuides(titles: [.left: "削除"], visible: true, fontSize: 11, color: .label)
        key.longPressMilliseconds = 100
        let repeated = expectation(description: "left gesture repeats")
        var actions: [SumireSpecialKeyGesture] = []
        key.repeats = { $0 == .left }
        key.action = { gesture in
            actions.append(gesture)
            if actions.count == 3 { key.cancelActiveInput(); repeated.fulfill() }
        }
        let touch = SampleTouch()
        touch.sample = CGPoint(x: 60, y: 50)
        key.touchesBegan([touch], with: nil)
        touch.sample.x -= 50
        key.touchesMoved([touch], with: nil)
        await fulfillment(of: [repeated], timeout: 2)
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(actions, [.left, .left, .left])
        let held = expectation(description: "central long press")
        actions = []
        key.longPressEnabled = { true }
        key.repeats = { _ in false }
        key.action = { actions.append($0); held.fulfill() }
        touch.sample = CGPoint(x: 60, y: 50)
        key.touchesBegan([touch], with: nil)
        await fulfillment(of: [held], timeout: 2)
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(actions, [.longPress])
    }
}
#endif
