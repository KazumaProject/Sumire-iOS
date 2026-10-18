import UIKit
import SumireCore

/// Function-key gestures retain their direction while held outside the key.
/// A repeated gesture emits no additional action on release.
final class DirectionalActionKey: UIButton {
    var action: ((FlickDirection) -> Void)?
    var repeats: ((FlickDirection) -> Bool)?
    private var touch: UITouch?
    private var origin = CGPoint.zero
    private var direction = FlickDirection.tap
    private var emitted = false
    private var timer: Timer?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first; origin = first.location(in: window)
        direction = .tap; emitted = false; isHighlighted = true
        schedule(after: 0.4)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: window)
        let next = FlickDirection.resolve(dx: point.x - origin.x, dy: point.y - origin.y, shape: .rectangular)
        guard next != direction else { return }
        direction = next; emitted = false
        schedule(after: 0.4)
    }
    private func schedule(after delay: TimeInterval) {
        timer?.invalidate(); timer = nil
        guard repeats?(direction) == true else { return }
        let value = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.touch != nil, self.window != nil, self.isEnabled else { return }
            self.emitted = true
            self.action?(self.direction)
            if self.touch != nil && self.window != nil { self.schedule(after: 0.07) }
        }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        let selected = direction, shouldEmit = !emitted
        cancel()
        if shouldEmit { action?(selected) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    private func cancel() {
        timer?.invalidate(); timer = nil; touch = nil; isHighlighted = false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancel() } }
    override func accessibilityActivate() -> Bool { action?(.tap); return true }
    deinit { timer?.invalidate() }
}
