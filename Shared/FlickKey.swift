import UIKit
import SumireCore

/// Tracks a single touch and commits on release. Moving outside the original key
/// is allowed for flicks; cancellation emits nothing. No per-frame view creation.
final class FlickKey: UIButton, KeyTouchParticipant {
    weak var touchRouter: KeyTouchRouter?
    var touchPolicy: (() -> (exclusive: Bool, blocksFollowing: Bool))?
    var exclusiveTouchAction = false
    /// The reference bypasses subsequent fingers on IME-switch / emoji keys
    /// even when independent multi-touch is disabled.
    var blocksSequentialTouches = false
    var values = ""
    var directionalValues: [String]?
    private var outputs: [String] { directionalValues ?? values.map(String.init) }
    var restingAttributedTitle: NSAttributedString?
    var restingTitle: String?
    var thresholdShape: FlickThresholdShape = .rectangular
    var resolveDirection: ((Double, Double) -> FlickDirection)?
    var onFlick: ((FlickDirection) -> Void)?
    /// Set to the keyboard's overlay host, never the app-wide window.
    weak var popupHost: UIView?
    var feedbackSettings = TouchFeedbackSettings()
    var popupPalette: KeyboardPalette?
    /// Only use for an explicitly supported five-direction alternate map.
    /// TFBI / hierarchical maps need their own controller, not this adapter.
    var longPressValues: [String]?
    var onLongPressFlick: ((FlickDirection) -> Void)?
    private var gestureSettings = TouchFeedbackSettings()
    private var popup: FlickPopupView?
    private var holdTimer: Timer?
    private var selectedDirection: FlickDirection = .tap
    private var longPressActive = false

    private var guides: [UILabel] = []
    private var requestedTitleFont = UIFont.systemFont(ofSize: 24)
    private var requestedGuideFont = UIFont.systemFont(ofSize: 12)
    func configureGuides(visible: Bool, fontSize: CGFloat, color: UIColor) {
        requestedTitleFont = titleLabel?.font ?? .systemFont(ofSize: 24)
        requestedGuideFont = .systemFont(ofSize: fontSize)
        guides.forEach { $0.removeFromSuperview() }; guides = []
        guard visible else { return }
        for text in outputs.dropFirst().prefix(4) {
            let label = UILabel()
            label.text = String(text)
            label.font = .systemFont(ofSize: fontSize)
            label.textColor = color
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            addSubview(label); guides.append(label)
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let host = popupHost, let popup {
            popup.place(keyRect: convert(bounds, to: host), within: host,
                        scale: CGFloat(gestureSettings.popupScalePercent / 100))
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        if guides.isEmpty {
            // The vertically stacked brackets in 50-on need two full lines.
            // UILabel's width fitting alone lets a larger default overflow vertically.
            guard let label = titleLabel, label.numberOfLines > 1,
                  attributedTitle(for: .normal) == nil, let text = label.text else { return }
            let lines = text.components(separatedBy: "\n")
            let width = lines.map { ($0 as NSString).size(withAttributes: [.font: requestedTitleFont]).width }.max() ?? 0
            let height = requestedTitleFont.lineHeight * CGFloat(lines.count)
            let available = bounds.insetBy(dx: 3, dy: 2)
            let scale = max(0.01, min(1, available.width / max(1, width), available.height / max(1, height)))
            label.font = requestedTitleFont.withSize(requestedTitleFont.pointSize * scale)
            label.frame = available
            return
        }
        // Preserve configured sizes as upper bounds. Scale the five labels together
        // only when their combined extents cannot fit, keeping directional regions separate.
        let characters = outputs + [restingTitle ?? ""]
        let titleSize = characters.map { ($0 as NSString).size(withAttributes: [.font: requestedTitleFont]) }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        let guideSizes = guides.map { (($0.text ?? "") as NSString).size(withAttributes: [.font: requestedGuideFont]) }
        func guide(_ index: Int) -> CGSize { guideSizes.indices.contains(index) ? guideSizes[index] : .zero }
        let gap: CGFloat = 2
        let available = bounds.insetBy(dx: 3, dy: 2)
        let horizontal = titleSize.width + 2 * max(guide(0).width, guide(2).width)
        let vertical = titleSize.height + 2 * max(guide(1).height, guide(3).height)
        let scale = max(0.01, min(1, (available.width - gap * 2) / max(1, horizontal),
                                    (available.height - gap * 2) / max(1, vertical)))
        titleLabel?.font = requestedTitleFont.withSize(requestedTitleFont.pointSize * scale)
        let central = CGSize(width: titleSize.width * scale, height: titleSize.height * scale)
        titleLabel?.frame = CGRect(x: bounds.midX - central.width / 2, y: bounds.midY - central.height / 2,
                                  width: central.width, height: central.height)
        for (index, label) in guides.enumerated() {
            label.font = requestedGuideFont.withSize(requestedGuideFont.pointSize * scale)
            let size = guideSizes[index]
            let w = size.width * scale, h = size.height * scale
            let centre: CGPoint
            switch index {
            case 0: centre = CGPoint(x: available.minX + w / 2, y: bounds.midY)
            case 1: centre = CGPoint(x: bounds.midX, y: available.minY + h / 2)
            case 2: centre = CGPoint(x: available.maxX - w / 2, y: bounds.midY)
            default: centre = CGPoint(x: bounds.midX, y: available.maxY - h / 2)
            }
            label.frame = CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
        }
    }
    private var tracked: UITouch?
    private var start = CGPoint.zero
    private func direction(_ touch: UITouch) -> FlickDirection {
        let point = touch.location(in: window)
        if let resolveDirection { return resolveDirection(point.x - start.x, point.y - start.y) }
        return .resolve(dx: point.x - start.x, dy: point.y - start.y, shape: thresholdShape)
    }
    private func restore() {
        touchRouter?.end(self)
        holdTimer?.invalidate(); holdTimer = nil
        popup?.removeFromSuperview(); popup = nil
        longPressActive = false
        tracked = nil; isHighlighted = false
        setTitle(restingTitle ?? outputs.first, for: .normal)
        setAttributedTitle(restingAttributedTitle, for: .normal)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, tracked == nil, let touch = touches.first else { return }
        let policy = touchPolicy?() ?? (exclusiveTouchAction, blocksSequentialTouches)
        guard touchRouter?.begin(self, exclusive: policy.0, blocksSequentialTouches: policy.1) != false else { return }
        tracked = touch; start = touch.location(in: window); isHighlighted = true
        gestureSettings = feedbackSettings.normalized()
        selectedDirection = .tap
        updatePopup()
        scheduleHold()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        setAttributedTitle(nil, for: .normal)
        let next = direction(touch)
        if next != selectedDirection {
            selectedDirection = next
            longPressActive = false
            scheduleHold()
        }
        let index = next.rawValue
        setTitle(outputs.indices.contains(index) ? outputs[index] : "", for: .normal)
        updatePopup()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        finishActiveFlick()
    }
    /// Used by the keyboard-wide touch coordinator for the reference's default
    /// second-finger policy: commit the first key before starting the next.
    func finishActiveFlick() {
        guard let touch = tracked else { return }
        let selected = direction(touch)
        let useAlternate = longPressActive && selected == selectedDirection
        restore()
        if useAlternate { onLongPressFlick?(selected) } else { onFlick?(selected) }
    }
    func cancelActiveFlick() { restore() }
    func finishActiveInput() { finishActiveFlick() }
    func cancelActiveInput() { cancelActiveFlick() }
    private func scheduleHold() {
        holdTimer?.invalidate(); holdTimer = nil
        let index = selectedDirection.rawValue
        guard onLongPressFlick != nil, let values = longPressValues,
              values.indices.contains(index), !values[index].isEmpty else { return }
        let timer = Timer(timeInterval: Double(gestureSettings.longPressMilliseconds) / 1000, repeats: false) { [weak self] _ in
            guard let self, self.tracked != nil else { return }
            self.longPressActive = true
            self.updatePopup()
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updatePopup() {
        guard gestureSettings.popupVisible, let host = popupHost, tracked != nil else { return }
        if popup == nil {
            let view = FlickPopupView(frame: .zero)
            host.addSubview(view)
            popup = view
        }
        let values = longPressActive ? (longPressValues ?? outputs) : outputs
        let palette = popupPalette ?? KeyboardPalette(hue: 0.73, dark: traitCollection.userInterfaceStyle == .dark)
        popup?.update(values: values, selected: selectedDirection.rawValue,
                      fontSize: CGFloat(gestureSettings.popupTextSize),
                      background: palette.key, foreground: palette.foreground,
                      highlight: palette.accent, highlightForeground: palette.accentForeground)
        popup?.place(keyRect: convert(bounds, to: host), within: host,
                     scale: CGFloat(gestureSettings.popupScalePercent / 100))
    }
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { restore() }
        super.willMove(toWindow: newWindow)
    }
    deinit { holdTimer?.invalidate(); popup?.removeFromSuperview() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { restore() }
    override func accessibilityActivate() -> Bool { onFlick?(.tap); return true }
}
