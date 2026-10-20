#if DEBUG
import XCTest
import SumireCore
@testable import Sumire

@MainActor
final class CustomDoubleTapControllerTests: XCTestCase {
    func testCommandReentryDoesNotFlushNextKeysPendingTap() {
        let controller = CustomDoubleTapController()
        var delivered: [CustomKeyAction] = []
        controller.onAction = {
            delivered.append($0)
            controller.interrupt() // Same entry used by pressed() command dispatch.
        }
        controller.committedTap(keyIdentity: "delete", action: .command(.delete), binding: .init(action: .text("D")))
        controller.committedTap(keyIdentity: "text", action: .text("B"), binding: .init(action: .text("BB")))
        XCTAssertEqual(delivered, [.command(.delete)])
        controller.interrupt()
        XCTAssertEqual(delivered, [.command(.delete), .text("B")])
        controller.cancel()
    }

    func testDetachDuringDeliveryDropsRemainingActionsAndAllowsReuse() {
        let controller = CustomDoubleTapController()
        var delivered: [CustomKeyAction] = []
        controller.onAction = {
            delivered.append($0)
            if $0 == .command(.nextKeyboard) { controller.cancel() }
        }
        controller.committedTap(keyIdentity: "switch", action: .command(.nextKeyboard), binding: .init(action: .text("D")))
        controller.committedTap(keyIdentity: "text", action: .text("B"), binding: nil)
        XCTAssertEqual(delivered, [.command(.nextKeyboard)])
        controller.committedTap(keyIdentity: "new", action: .text("C"), binding: nil)
        XCTAssertEqual(delivered, [.command(.nextKeyboard), .text("C")])
    }

    func testDetachWhileFlushingPendingTapDropsInterruptingGesture() {
        let controller = CustomDoubleTapController()
        var delivered: [CustomKeyAction] = []
        controller.onAction = { delivered.append($0); controller.cancel() }
        controller.committedTap(keyIdentity: "switch", action: .command(.nextKeyboard), binding: .init(action: .text("D")))
        controller.committedGesture(.text("flick"))
        XCTAssertEqual(delivered, [.command(.nextKeyboard)])
    }

    func testRunLoopDeliversExclusiveSingleTapOnce() {
        let controller = CustomDoubleTapController()
        let delivered = expectation(description: "single tap deadline")
        delivered.assertForOverFulfill = true
        controller.onAction = { XCTAssertEqual($0, .text("A")); delivered.fulfill() }
        controller.committedTap(keyIdentity: "key", action: .text("A"), binding: .init(action: .text("D")))
        wait(for: [delivered], timeout: 1)
        controller.interrupt()
        controller.cancel()
    }

    func testReplacedGridCannotDeliverDelayedTap() {
        let controller = CustomDoubleTapController()
        let delivered = expectation(description: "cancelled tap")
        delivered.isInverted = true
        controller.onAction = { _ in delivered.fulfill() }
        controller.committedTap(keyIdentity: "key", action: .text("A"), binding: .init(action: .text("D")))
        controller.deactivate()
        controller.committedTap(keyIdentity: "key", action: .text("A"), binding: nil)
        wait(for: [delivered], timeout: 0.4)
    }
}
#endif
