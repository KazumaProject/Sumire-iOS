import XCTest
@testable import SumireCore

final class CustomDoubleTapDispatcherTests: XCTestCase {
    let normal = CustomKeyAction.command(.delete)
    let double = CustomDoubleTapBinding(action: .command(.paste))
    func testExclusiveTimeoutAndMinimumIntervalBoundaries() {
        var d = CustomDoubleTapDispatcher()
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 0), [])
        XCTAssertEqual(d.deadline, 300)
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 39), [])
        XCTAssertEqual(d.deadline, 300)
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 40), [.command(.paste)])
        XCTAssertNil(d.deadline)
        XCTAssertEqual(d.flush(at: 300), [])
        _ = d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 400)
        XCTAssertEqual(d.flush(at: 699), [])
        XCTAssertEqual(d.flush(at: 700), [normal])
    }
    func testInclusiveDoubleTimeoutAndExpiredTapStartsNewWindow() {
        var d = CustomDoubleTapDispatcher()
        _ = d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 0)
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 300), [double.action])
        _ = d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 400)
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 701), [normal])
        XCTAssertEqual(d.deadline, 1001)
    }
    func testInterruptOrderingDifferentBindingsAndCancellation() {
        var d = CustomDoubleTapDispatcher()
        _ = d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 0)
        XCTAssertEqual(d.committedTap(keyIdentity: "b", normalAction: .text("b"), binding: nil, at: 20), [normal, .text("b")])
        _ = d.committedTap(keyIdentity: "a", normalAction: normal, binding: double, at: 50)
        let changed = CustomDoubleTapBinding(action: .text("changed"))
        XCTAssertEqual(d.committedTap(keyIdentity: "a", normalAction: normal, binding: changed, at: 100), [normal])
        d.cancel()
        XCTAssertEqual(d.interrupt(), [])
        XCTAssertEqual(d.flush(at: 1000), [])
    }
    func testPromoteDispatchesFirstTapButDoesNotRepeatAtTimeoutOrInterrupt() {
        var d = CustomDoubleTapDispatcher()
        let promoted = CustomDoubleTapBinding(action: .text("caps"), policy: .promote)
        XCTAssertEqual(d.committedTap(keyIdentity: "shift", normalAction: .text("shift"), binding: promoted, at: 0), [.text("shift")])
        XCTAssertEqual(d.committedTap(keyIdentity: "shift", normalAction: .text("shift"), binding: promoted, at: 100), [.text("caps")])
        _ = d.committedTap(keyIdentity: "shift", normalAction: normal, binding: promoted, at: 200)
        XCTAssertEqual(d.flush(at: 500), [])
        _ = d.committedTap(keyIdentity: "shift", normalAction: normal, binding: promoted, at: 600)
        XCTAssertEqual(d.interrupt(), [])
    }
    func testEffectiveBindingsFollowAndroidImportDefaultsAndIgnorePersistedPolicy() throws {
        let targets = CustomLayoutTargets(layouts: [])
        func binding(_ json: String) throws -> CustomDoubleTapBinding? {
            let value = try JSONDecoder().decode(LayoutJSON.self, from: Data(json.utf8))
            return .effective(definition: value, normalAction: .tap(value["action"]?.string ?? "", targets: targets), targets: targets)
        }
        XCTAssertNil(try binding(#"{"doubleTapAction":"Paste"}"#))
        XCTAssertNil(try binding(#"{"isSpecialKey":true,"doubleTapEnabled":false,"doubleTapAction":"Paste"}"#))
        XCTAssertNil(try binding(#"{"isSpecialKey":true,"doubleTapEnabled":true,"action":"ShiftKeyPressed"}"#))
        XCTAssertEqual(try binding(#"{"isSpecialKey":true,"action":"ShiftKeyPressed"}"#)?.policy, .promote)
        let shift = try JSONDecoder().decode(LayoutJSON.self, from: Data(#"{"isSpecialKey":true,"action":"ShiftKeyPressed","doubleTapAction":"CapLockKey"}"#.utf8))
        XCTAssertEqual(CustomDoubleTapBinding.effective(definition: shift, normalAction: .command(.delete), targets: targets)?.policy, .exclusive)
        XCTAssertEqual(try binding(#"{"isSpecialKey":true,"action":"Delete","doubleTapAction":"Paste","doubleTapPolicy":"PROMOTE","keyType":"CIRCULAR_FLICK"}"#), double)
    }
}
