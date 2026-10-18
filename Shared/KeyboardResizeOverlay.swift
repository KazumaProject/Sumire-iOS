import UIKit

final class KeyboardResizeOverlay: UIView {
    enum Handle: Int { case top, left, right }
    var onBegin: (() -> Void)?
    var onDrag: ((Handle, CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onDone: (() -> Void)?
    var onReset: (() -> Void)?
    private var origin = CGPoint.zero
    private let top = UIView(), left = UIView(), right = UIView()
    private let done = UIButton(type: .system), reset = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderColor = UIColor.systemBlue.cgColor; layer.borderWidth = 2; layer.cornerRadius = 10
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        for (index, handle) in [top, left, right].enumerated() {
            handle.tag = index
            handle.backgroundColor = .systemBlue
            handle.layer.cornerRadius = 6
            handle.isAccessibilityElement = true
            handle.accessibilityLabel = ["キーボードの高さ", "キーボードの左端", "キーボードの右端"][index]
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
            addSubview(handle)
        }
        done.setImage(KeyboardIcon.done.image, for: .normal)
        done.accessibilityLabel = "サイズ変更を完了"
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        reset.setTitle("リセット", for: .normal)
        reset.accessibilityLabel = "この向きのサイズをリセット"
        reset.addAction(UIAction { [weak self] _ in self?.onReset?() }, for: .touchUpInside)
        addSubview(done); addSubview(reset)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        top.frame = CGRect(x: max(44, bounds.midX - 38), y: 0, width: 76, height: 28)
        left.frame = CGRect(x: 0, y: bounds.midY - 30, width: 28, height: 60)
        right.frame = CGRect(x: bounds.width - 28, y: bounds.midY - 30, width: 28, height: 60)
        done.frame = CGRect(x: bounds.width - 52, y: 30, width: 44, height: 44)
        reset.frame = CGRect(x: 8, y: 30, width: 88, height: 44)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view, let handle = Handle(rawValue: view.tag) else { return }
        let point = recognizer.location(in: window)
        switch recognizer.state {
        case .began: origin = point; onBegin?()
        case .changed: onDrag?(handle, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        case .ended, .cancelled: onEnd?()
        default: break
        }
    }
}
