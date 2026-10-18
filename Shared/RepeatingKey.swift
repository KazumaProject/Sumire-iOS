import UIKit

/// Repeats the key's normal action after a hold; the recognizer cancels the
/// ordinary release action so lifting a held key does not emit an extra edit.
final class RepeatingKey: UIButton, UIGestureRecognizerDelegate {
    var repeatEnabled: Bool?
    private var repeatTimer: Timer?
    private lazy var hold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        gesture.minimumPressDuration = 0.4
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
            sendActions(for: .touchUpInside)
            guard window != nil else { return }
            repeatTimer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.window != nil, self.isEnabled,
                      self.bounds.contains(self.hold.location(in: self)) else {
                    self.stopRepeating(); return
                }
                self.sendActions(for: .touchUpInside)
            }
            RunLoop.main.add(repeatTimer!, forMode: .common)
        case .changed:
            if !bounds.contains(gesture.location(in: self)) { stopRepeating() }
        default: stopRepeating()
        }
    }
    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }
    deinit { repeatTimer?.invalidate() }
}
