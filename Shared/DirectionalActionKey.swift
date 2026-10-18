import UIKit
import SumireCore

/// Function-key gestures retain their direction while held outside the key.
/// A repeated gesture emits no additional action on release.
final class DirectionalActionKey: UIButton, KeyTouchParticipant {
    weak var touchRouter: KeyTouchRouter?
    var touchPolicy: (() -> (exclusive: Bool, blocksFollowing: Bool))?
    var exclusiveTouchAction = false
    /// The reference bypasses subsequent fingers on IME-switch / emoji keys
    /// even when independent multi-touch is disabled.
    var blocksSequentialTouches = false
    var longPressMilliseconds = 300
    var action: ((SumireSpecialKeyGesture) -> Void)?
    var repeats: ((SumireSpecialKeyGesture) -> Bool)?
    var longPressEnabled: (() -> Bool)?
    private var touch: UITouch?
    private var origin = CGPoint.zero
    private var direction = FlickDirection.tap
    private var emitted = false
    private var timer: Timer?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, touch == nil, let first = touches.first else { return }
        let policy = touchPolicy?() ?? (exclusiveTouchAction, blocksSequentialTouches)
        guard touchRouter?.begin(self, exclusive: policy.0, blocksSequentialTouches: policy.1) != false else { return }
        touch = first; origin = first.location(in: window)
        direction = .tap; emitted = false; isHighlighted = true
        scheduleInitialHold()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: window)
        let next = FlickDirection.resolve(dx: point.x - origin.x, dy: point.y - origin.y, shape: .rectangular)
        guard next != direction else { return }
        direction = next; emitted = false
        scheduleInitialHold()
    }
    private var gesture: SumireSpecialKeyGesture {
        switch direction {
        case .tap: return .tap
        case .up: return .up
        case .right: return .right
        case .down: return .down
        case .left: return .left
        }
    }
    private func scheduleInitialHold() {
        timer?.invalidate(); timer = nil
        if direction == .tap {
            guard longPressEnabled?() == true else { return }
            schedule(.longPress, after: Double(min(2000, max(100, longPressMilliseconds))) / 1000)
        } else if repeats?(gesture) == true {
            schedule(gesture, after: Double(min(2000, max(100, longPressMilliseconds))) / 1000)
        }
    }
    private func schedule(_ selected: SumireSpecialKeyGesture, after delay: TimeInterval) {
        timer?.invalidate(); timer = nil
        let value = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.touch != nil, self.window != nil, self.isEnabled else { return }
            self.emitted = true
            self.action?(selected)
            if self.touch != nil && self.window != nil && self.repeats?(selected) == true {
                self.schedule(selected, after: 0.07)
            }
        }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        finishActiveInput()
    }
    func finishActiveInput() {
        guard touch != nil else { return }
        let selected = gesture, shouldEmit = !emitted
        cancel()
        if shouldEmit { action?(selected) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    func cancelActiveInput() { cancel() }
    private func cancel() {
        touchRouter?.end(self)
        timer?.invalidate(); timer = nil; touch = nil; isHighlighted = false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancel() } }
    override func accessibilityActivate() -> Bool { action?(.tap); return true }
    deinit { timer?.invalidate() }
}
