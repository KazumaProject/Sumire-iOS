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
    private var guideLabels: [FlickDirection: UILabel] = [:]
    private var guideTitles: [FlickDirection: String] = [:]
    private var originalTitleFont: UIFont?
    private var fittedTitleFont: UIFont?
    private var guidesVisible = false
    private var guideFontSize: CGFloat = 9
    private var guideColor = UIColor.label
    private static let guideDirections: [(FlickDirection, String)] = [
        (.left, "left"), (.up, "up"), (.right, "right"), (.down, "down")
    ]
    private var hasGuides: Bool { guidesVisible && !guideTitles.isEmpty }

    func configureGuides(titles: [FlickDirection: String], visible: Bool,
                         fontSize: CGFloat, color: UIColor) {
        let titles = titles.filter { $0.key != .tap && !$0.value.isEmpty }
        let size = fontSize.isFinite ? min(64, max(1, fontSize)) : 9
        guard titles != guideTitles || visible != guidesVisible ||
                size != guideFontSize || !color.isEqual(guideColor) else { return }
        guideTitles = titles; guidesVisible = visible
        guideFontSize = size; guideColor = color
        for (direction, name) in Self.guideDirections {
            let title = titles[direction]
            if visible && title != nil && guideLabels[direction] == nil {
                let label = UILabel()
                label.accessibilityIdentifier = "flick-guide-" + name
                label.isUserInteractionEnabled = false
                label.isAccessibilityElement = false
                label.textAlignment = .center
                label.lineBreakMode = .byClipping
                label.clipsToBounds = true
                addSubview(label)
                guideLabels[direction] = label
            }
            if let label = guideLabels[direction] {
                label.text = title
                label.textColor = color
                label.isHidden = !visible || title == nil
            }
        }
        if !hasGuides, let originalTitleFont {
            // Respect a caller's new font even when it disables the guides in
            // the same update, rather than restoring an obsolete font.
            if titleLabel?.font == fittedTitleFont { titleLabel?.font = originalTitleFont }
            self.originalTitleFont = nil
            fittedTitleFont = nil
        }
        setNeedsLayout()
    }

    private func fitCenterTitle() {
        guard hasGuides, currentAttributedTitle == nil,
              let title = currentTitle, !title.isEmpty, let label = titleLabel else { return }
        if originalTitleFont == nil || label.font != fittedTitleFont {
            originalTitleFont = label.font
        }
        guard let font = originalTitleFont else { return }
        let rect = contentRect(forBounds: bounds)
        let size = (title as NSString).size(withAttributes: [.font: font])
        let ratio = min(1, rect.width / max(1, size.width), rect.height / max(1, size.height))
        let fitted = font.withSize(max(1, font.pointSize * ratio))
        label.font = fitted
        fittedTitleFont = fitted
    }

    private func guideArea(in rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite, rect.width > 4, rect.height > 4 else { return .zero }
        return rect.insetBy(dx: 2, dy: 2)
    }
    private func guideCenter(in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - rect.width * 0.23, y: rect.midY - rect.height * 0.225,
               width: rect.width * 0.46, height: rect.height * 0.45)
    }
    override func contentRect(forBounds bounds: CGRect) -> CGRect {
        let rect = super.contentRect(forBounds: bounds)
        return hasGuides ? guideCenter(in: guideArea(in: rect)) : rect
    }
    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        hasGuides ? contentRect : super.titleRect(forContentRect: contentRect)
    }
    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        guard hasGuides, let image = currentImage else { return super.imageRect(forContentRect: contentRect) }
        let scale = min(1, contentRect.width / max(1, image.size.width), contentRect.height / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: contentRect.midX - size.width / 2, y: contentRect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    override func layoutSubviews() {
        fitCenterTitle()
        super.layoutSubviews()
        guard hasGuides else { return }
        let rect = guideArea(in: super.contentRect(forBounds: bounds))
        let center = guideCenter(in: rect)
        let gap: CGFloat = 1
        let frames: [FlickDirection: CGRect] = [
            .up: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, center.minY - rect.minY - gap)),
            .down: CGRect(x: rect.minX, y: center.maxY + gap, width: rect.width, height: max(0, rect.maxY - center.maxY - gap)),
            .left: CGRect(x: rect.minX, y: center.minY, width: max(0, center.minX - rect.minX - gap), height: center.height),
            .right: CGRect(x: center.maxX + gap, y: center.minY, width: max(0, rect.maxX - center.maxX - gap), height: center.height)
        ]
        for (direction, label) in guideLabels {
            guard let title = guideTitles[direction], let frame = frames[direction] else { continue }
            label.frame = frame
            label.isHidden = frame.width < 1 || frame.height < 1
            let measured = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: guideFontSize)])
            let ratio = min(1, frame.width / max(1, measured.width), frame.height / max(1, measured.height))
            label.font = .systemFont(ofSize: max(1, guideFontSize * ratio))
        }
    }

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
        endActiveInput()
        if shouldEmit { action?(selected) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    func cancelActiveInput() { cancel() }
    private func endActiveInput() {
        touchRouter?.end(self)
        resetActiveInput()
    }
    private func cancel() {
        touchRouter?.cancel(self)
        resetActiveInput()
    }
    private func resetActiveInput() {
        timer?.invalidate(); timer = nil; touch = nil; isHighlighted = false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancel() } }
    override func accessibilityActivate() -> Bool { action?(.tap); return true }
    deinit { timer?.invalidate() }
}
