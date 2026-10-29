import XCTest
@testable import SumireCore

final class KeyTouchRouterTests: XCTestCase {
    private final class Key: KeyTouchParticipant {
        var finished = 0
        var cancelled = 0
        var onFinish: (() -> Void)?
        func finishActiveInput() { finished += 1; onFinish?() }
        func cancelActiveInput() { cancelled += 1 }
    }
    func testDefaultCommitsPreviousAndIgnoresSameKey() {
        let router = KeyTouchRouter(), a = Key(), b = Key()
        XCTAssertTrue(router.begin(a))
        XCTAssertFalse(router.begin(a))
        XCTAssertTrue(router.begin(b))
        XCTAssertEqual(a.finished, 1)
        XCTAssertEqual(router.activeCount, 1)
        router.end(a)
        XCTAssertEqual(router.activeCount, 1)
        router.end(b)
        XCTAssertEqual(router.activeCount, 0)
    }
    func testSequentialBarrierAndIncomingExclusiveStillCommits() {
        let router = KeyTouchRouter(), a = Key(), menu = Key()
        XCTAssertTrue(router.begin(a))
        XCTAssertTrue(router.begin(menu, exclusive: true, blocksSequentialTouches: true))
        XCTAssertEqual(a.finished, 1)
        XCTAssertEqual(a.cancelled, 0)
        XCTAssertFalse(router.begin(a))
        router.end(menu)
        XCTAssertTrue(router.begin(a, exclusive: true))
        XCTAssertTrue(router.begin(menu))
        XCTAssertEqual(a.finished, 2)
    }
    func testIndependentAndExclusiveCancellation() {
        let router = KeyTouchRouter(), a = Key(), b = Key(), menu = Key()
        router.independentMultiTouch = true
        XCTAssertTrue(router.begin(a)); XCTAssertTrue(router.begin(b))
        XCTAssertEqual(a.finished, 0)
        XCTAssertTrue(router.begin(menu, exclusive: true))
        XCTAssertEqual(a.cancelled, 1); XCTAssertEqual(b.cancelled, 1)
        XCTAssertFalse(router.begin(a))
        router.end(menu)
        XCTAssertTrue(router.begin(a))
        router.cancelAll()
        XCTAssertEqual(a.cancelled, 2)
        XCTAssertEqual(router.activeCount, 0)
    }
    func testSettingSnapshotAndReentrantKeyboardRebuild() {
        let router = KeyTouchRouter(), a = Key(), b = Key()
        XCTAssertTrue(router.begin(a))
        router.independentMultiTouch = true
        a.onFinish = { router.cancelAll() }
        XCTAssertFalse(router.begin(b))
        XCTAssertEqual(a.finished, 1)
        XCTAssertEqual(router.activeCount, 0)
    }
    func testOrdinaryReleaseAndForcedFinishEmitOnce() {
        var press = KeyPressEmission()
        press.begin()
        XCTAssertTrue(press.finish())
        XCTAssertFalse(press.finish())
        press.begin(); press.markEmitted(); press.markEmitted()
        XCTAssertFalse(press.finish())
        XCTAssertFalse(press.finish())
        press.begin(); press.cancel()
        XCTAssertFalse(press.finish())
        press.begin()
        XCTAssertFalse(press.finish(inside: false))
    }
    func testIndependentReleaseOrderAndWeakOwnership() {
        let router = KeyTouchRouter(), a = Key(), b = Key()
        router.independentMultiTouch = true
        XCTAssertTrue(router.begin(a)); XCTAssertTrue(router.begin(b))
        b.finishActiveInput(); router.end(b)
        XCTAssertEqual(a.finished, 0)
        a.finishActiveInput(); router.end(a)
        XCTAssertEqual(b.finished, 1); XCTAssertEqual(a.finished, 1)
        var temporary: Key? = Key()
        XCTAssertTrue(router.begin(temporary!))
        temporary = nil
        XCTAssertEqual(router.activeCount, 0)
    }
    func testFeedbackCallbacksFollowAcceptedTouchesAndIgnoreCancellation() {
        let router = KeyTouchRouter(), first = Key(), second = Key(), exclusive = Key()
        router.independentMultiTouch = true
        var events: [String] = []
        router.onBegin = { key in events.append(key === first ? "down:first" : key === second ? "down:second" : "down:exclusive") }
        router.onEnd = { key in events.append(key === first ? "up:first" : key === second ? "up:second" : "up:exclusive") }

        XCTAssertTrue(router.begin(first))
        XCTAssertFalse(router.begin(first)) // Rejected duplicate: no second down event.
        XCTAssertTrue(router.begin(second))
        router.end(second)
        XCTAssertTrue(router.begin(exclusive, exclusive: true))
        router.end(exclusive)
        XCTAssertEqual(events, ["down:first", "down:second", "up:second", "down:exclusive", "up:exclusive"])
    }
    func testExplicitCancelDoesNotEmitReleaseFeedback() {
        let router = KeyTouchRouter(), key = Key()
        var events: [String] = []
        router.onBegin = { _ in events.append("down") }
        router.onEnd = { _ in events.append("up") }

        XCTAssertTrue(router.begin(key))
        router.cancel(key)
        XCTAssertEqual(events, ["down"])
        XCTAssertEqual(router.activeCount, 0)

        XCTAssertTrue(router.begin(key))
        router.end(key)
        XCTAssertEqual(events, ["down", "down", "up"])
    }
    func testFeedbackBackupRoundTripAndInvalidData() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var feedback = TouchFeedbackSettings()
        feedback.independentMultiTouch = true
        feedback.save(defaults: defaults)
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        defaults.removeObject(forKey: TouchFeedbackSettings.storageKey)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(TouchFeedbackSettings.load(defaults: defaults), feedback)
        var invalid = snapshot
        feedback.longPressMilliseconds = 1
        invalid.values[TouchFeedbackSettings.storageKey] = .data(try JSONEncoder().encode(feedback))
        XCTAssertThrowsError(try invalid.validate())
    }
}
