import UIKit
import SumireCore

/// Repeats the key's normal action after a hold; the recognizer cancels the
/// ordinary release action so lifting a held key does not emit an extra edit.
final class RepeatingKey: UIButton, UIGestureRecognizerDelegate, KeyTouchParticipant {
    weak var touchRouter: KeyTouchRouter?
    var exclusiveTouchAction = false
    /// The reference bypasses subsequent fingers on IME-switch / emoji keys
    /// even when independent multi-touch is disabled.
    var blocksSequentialTouches = false
    var longPressMilliseconds = 300 {
        didSet { hold.minimumPressDuration = Double(min(2000, max(100, longPressMilliseconds))) / 1000 }
    }
    var repeatEnabled: Bool?
    private var activeTouch: UITouch?
    private var emission = KeyPressEmission()
    private var inside = true

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, activeTouch == nil, let touch = touches.first else { return }
        guard touchRouter?.begin(self, exclusive: exclusiveTouchAction, blocksSequentialTouches: blocksSequentialTouches) != false else { return }
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
        clearInput()
        if shouldEmit { super.touchesEnded([touch], with: event) }
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
        cancelActiveInput()
        if emit { sendActions(for: .touchUpInside) }
    }
    func cancelActiveInput() {
        let touch = activeTouch
        clearInput()
        if let touch { super.touchesCancelled([touch], with: nil) }
        // Prevent a recognizer already tracking this finger from firing later.
        hold.isEnabled = false; hold.isEnabled = true
        isHighlighted = false
    }
    private func clearInput() {
        stopRepeating()
        activeTouch = nil
        emission.cancel()
        touchRouter?.end(self)
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
            sendActions(for: .touchUpInside)
            guard window != nil, activeTouch != nil else { return }
            repeatTimer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.activeTouch != nil, self.window != nil, self.isEnabled,
                      self.bounds.contains(self.hold.location(in: self)) else {
                    self.stopRepeating(); return
                }
                self.sendActions(for: .touchUpInside)
            }
            RunLoop.main.add(repeatTimer!, forMode: .common)
        case .changed:
            if !bounds.contains(gesture.location(in: self)) { stopRepeating() }
        default: clearInput()
        }
    }
    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelActiveInput() }
    }
    deinit { repeatTimer?.invalidate() }
}
