import UIKit
import SumireCore

/// Repeats the key's normal action after a hold; the recognizer cancels the
/// ordinary release action so lifting a held key does not emit an extra edit.
final class RepeatingKey: UIButton, UIGestureRecognizerDelegate, KeyTouchParticipant {
    weak var touchRouter: KeyTouchRouter?
    var touchPolicy: (() -> (exclusive: Bool, blocksFollowing: Bool))?
    var exclusiveTouchAction = false
    /// The reference bypasses subsequent fingers on IME-switch / emoji keys
    /// even when independent multi-touch is disabled.
    var blocksSequentialTouches = false
    var longPressMilliseconds = 300 {
        didSet { hold.minimumPressDuration = Double(min(2000, max(100, longPressMilliseconds))) / 1000 }
    }
    var repeatEnabled: Bool?
    /// Custom layouts resolve only actual taps as double-tap candidates.
    var onCommittedPress: ((_ isTap: Bool) -> Void)?
    private var activeTouch: UITouch?
    private var emission = KeyPressEmission()
    private var inside = true

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, activeTouch == nil, let touch = touches.first else { return }
        let policy = touchPolicy?() ?? (exclusiveTouchAction, blocksSequentialTouches)
        guard touchRouter?.begin(self, exclusive: policy.0, blocksSequentialTouches: policy.1) != false else { return }
        activeTouch = touch; emission.begin(); inside = true
        super.touchesBegan([touch], with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        inside = bounds.contains(touch.location(in: self))
        super.touchesMoved([touch], with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let shouldEmit = emission.finish(inside: bounds.contains(touch.location(in: self)))
        clearInput(reportRelease: true)
        if shouldEmit, let onCommittedPress {
            super.touchesCancelled([touch], with: event)
            onCommittedPress(true)
        }
        else if shouldEmit { super.touchesEnded([touch], with: event) }
        else { super.touchesCancelled([touch], with: event) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Our hold recognizer cancels UIButton tracking to suppress its UP.
        // The router must retain ownership until that recognizer ends.
        if hold.state == .began || hold.state == .changed {
            super.touchesCancelled(touches, with: event)
            return
        }
        cancelActiveInput()
        super.touchesCancelled(touches, with: event)
    }
    func finishActiveInput() {
        guard activeTouch != nil else { return }
        let emit = emission.finish(inside: inside && isEnabled)
        clearInput(reportRelease: true)
        if emit { emitPress(isTap: true) }
    }
    func cancelActiveInput() {
        let touch = activeTouch
        clearInput(reportRelease: false)
        if let touch { super.touchesCancelled([touch], with: nil) }
        // Prevent a recognizer already tracking this finger from firing later.
        hold.isEnabled = false; hold.isEnabled = true
        isHighlighted = false
    }
    private func clearInput(reportRelease: Bool) {
        stopRepeating()
        activeTouch = nil
        emission.cancel()
        if reportRelease { touchRouter?.end(self) }
        else { touchRouter?.cancel(self) }
    }
    private var repeatTimer: Timer?
    private lazy var hold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        gesture.minimumPressDuration = 0.3
        gesture.allowableMovement = 20
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(hold)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === hold else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return repeatEnabled ?? ["削除", "⌫", "←", "→"].contains(accessibilityLabel ?? "")
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard activeTouch != nil else { return }
            emission.markEmitted()
            emitPress(isTap: false)
            guard window != nil, activeTouch != nil else { return }
            repeatTimer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.activeTouch != nil, self.window != nil, self.isEnabled,
                      self.bounds.contains(self.hold.location(in: self)) else {
                    self.stopRepeating(); return
                }
                self.emitPress(isTap: false)
            }
            RunLoop.main.add(repeatTimer!, forMode: .common)
        case .changed:
            if !bounds.contains(gesture.location(in: self)) { stopRepeating() }
        case .ended: clearInput(reportRelease: true)
        case .cancelled, .failed: clearInput(reportRelease: false)
        default: break
        }
    }
    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
    private func emitPress(isTap: Bool) {
        if let onCommittedPress { onCommittedPress(isTap) }
        else { sendActions(for: .touchUpInside) }
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        if let onCommittedPress { onCommittedPress(true); return true }
        return super.accessibilityActivate()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelActiveInput() }
    }
    deinit { repeatTimer?.invalidate() }
}
