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

    func testLongPressTrackpadKeepsHoldAliveDuringInitialDriftAndTracksDragUntilRelease() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let key = Sumire.DirectionalActionKey(frame: CGRect(x: 20, y: 20, width: 90, height: 60))
        controller.view.addSubview(key)
        key.longPressMilliseconds = 100
        key.longPressEnabled = { true }
        key.longPressDragEnabled = { true }
        var actions: [SumireSpecialKeyGesture] = []
        var dragDeltas: [CGFloat] = []
        var dragEnded = false
        let held = expectation(description: "trackpad hold starts")
        key.action = { action in actions.append(action); held.fulfill() }
        key.longPressDrag = { dragDeltas.append($0) }
        key.longPressDragEnded = { dragEnded = true }

        let touch = SampleTouch()
        touch.sample = CGPoint(x: 60, y: 50)
        key.touchesBegan([touch], with: nil)
        touch.sample.x += 3 // Small pre-threshold drift must not cancel the hold.
        key.touchesMoved([touch], with: nil)
        await fulfillment(of: [held], timeout: 2)
        touch.sample.x += 18
        key.touchesMoved([touch], with: nil)
        key.touchesEnded([touch], with: nil)

        XCTAssertEqual(actions, [.longPress])
        XCTAssertEqual(dragDeltas, [18])
        XCTAssertTrue(dragEnded)
    }
    func testTrackpadKeepsPreHoldDirectionalFlickAndEndCancelFeedbackDistinct() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let key = Sumire.DirectionalActionKey(frame: CGRect(x: 20, y: 20, width: 90, height: 60))
        controller.view.addSubview(key)
        key.longPressEnabled = { true }
        key.longPressDragEnabled = { true }
        key.longPressDrag = { _ in XCTFail("A flick before hold must not become a trackpad drag") }
        var actions: [SumireSpecialKeyGesture] = []
        key.action = { actions.append($0) }
        let router = KeyTouchRouter()
        key.touchRouter = router
        var releases = 0
        router.onEnd = { _ in releases += 1 }
        let touch = SampleTouch()
        touch.sample = CGPoint(x: 60, y: 50)
        key.touchesBegan([touch], with: nil)
        touch.sample.x -= 50
        key.touchesMoved([touch], with: nil)
        key.touchesEnded([touch], with: nil)
        XCTAssertEqual(actions, [.left])
        XCTAssertEqual(releases, 1)
        key.touchesBegan([touch], with: nil)
        key.touchesCancelled([touch], with: nil)
        XCTAssertEqual(actions, [.left])
        XCTAssertEqual(releases, 1, "Cancellation must retain #106's no-release-feedback contract")
    }

}
#endif
