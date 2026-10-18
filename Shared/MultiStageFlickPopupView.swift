import UIKit
import SumireCore

/// Dedicated nine-direction / circular overlay. It never intercepts the active
/// touch, and does not collapse diagonal or additional donut slots to five keys.
final class MultiStageFlickPopupView: UIView {
    enum Content {
        case grid([MultiFlickDirection: String], selected: MultiFlickDirection?)
        case circle([CircularFlickSlot: CircularFlickOutput], ranges: [CircularFlickSlot: CircularFlickRange], selected: CircularFlickSlot, expanded: Bool)
    }
    private var content = Content.grid([:], selected: nil)
    private var palette = KeyboardPalette(hue: 0.73, dark: false)
    private var fontSize: CGFloat = 20
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
        backgroundColor = .clear; isOpaque = false
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ content: Content, palette: KeyboardPalette, fontSize: CGFloat) {
        self.content = content; self.palette = palette; self.fontSize = fontSize
        setNeedsDisplay()
    }
    func place(keyRect: CGRect, host: UIView, scale: CGFloat, above: Bool) {
        let available = host.bounds.insetBy(dx: 2, dy: 2)
        guard available.width > 0, available.height > 0 else { isHidden = true; return }
        isHidden = false
        let width: CGFloat, height: CGFloat
        if case .circle = content {
            // Reference orbit radius is 170 px at scale 1 (420 dpi AVD).
            let diameter = min(available.width, available.height, 340 / 2.625 * scale)
            width = diameter; height = diameter
        } else {
            width = min(available.width, keyRect.width * 3 * scale)
            height = min(available.height, keyRect.height * 3 * scale)
        }
        let x = min(max(available.minX, keyRect.midX - width / 2), available.maxX - width)
        let proposedY = above ? keyRect.minY - height : keyRect.midY - height / 2
        let y = min(max(available.minY, proposedY), available.maxY - height)
        frame = CGRect(x: x, y: y, width: width, height: height)
    }
    private func text(_ text: String, in rect: CGRect, selected: Bool) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let fittedSize = min(fontSize, max(8, rect.width / CGFloat(max(1, text.count))))
        let font = UIFont.systemFont(ofSize: fittedSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: selected ? palette.functionForeground : palette.foreground, .paragraphStyle: paragraph]
        let height = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: rect.height), options: .usesLineFragmentOrigin, attributes: attributes, context: nil).height
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - min(rect.height, height) / 2, width: rect.width, height: rect.height), withAttributes: attributes)
    }
    override func draw(_ rect: CGRect) {
        switch content {
        case .grid(let values, let selected):
            let positions: [MultiFlickDirection: (Int, Int)] = [.tap:(1,1),.up:(1,0),.down:(1,2),.left:(0,1),.right:(2,1),.upLeft:(0,0),.upRight:(2,0),.downLeft:(0,2),.downRight:(2,2)]
            for direction in MultiFlickDirection.allCases {
                guard let value = values[direction], !value.isEmpty, let position = positions[direction] else { continue }
                let cell = CGRect(x: CGFloat(position.0) * bounds.width / 3, y: CGFloat(position.1) * bounds.height / 3, width: bounds.width / 3, height: bounds.height / 3)
                (direction == selected ? palette.function : palette.key).setFill()
                let path = UIBezierPath(roundedRect: cell, cornerRadius: 20 / 2.625)
                path.fill(); palette.foreground.setStroke(); path.lineWidth = 4 / 2.625; path.stroke()
                text(value, in: cell.insetBy(dx: 3, dy: 2), selected: direction == selected)
            }
        case .circle(let values, let ranges, let selected, let expanded):
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - 1, inner = radius * (64.0 / 170.0)
            for slot in CircularFlickSlot.allCases where slot != .tap {
                guard (expanded || slot == selected), let range = ranges[slot] else { continue }
                let start = CGFloat(range.start) * .pi / 180, end = CGFloat(range.start + range.sweep) * .pi / 180
                let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
                path.addArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: false); path.close()
                (slot == selected ? palette.function : palette.key).setFill(); path.fill()
                palette.foreground.withAlphaComponent(0.25).setStroke(); path.lineWidth = 0.5; path.stroke()
                let angle = (start + end) / 2, distance = (radius + inner) / 2
                let labelRect = CGRect(x: center.x + cos(angle) * distance - radius * 0.3,
                                       y: center.y + sin(angle) * distance - radius * 0.2,
                                       width: radius * 0.6, height: radius * 0.4)
                text(label(values[slot]), in: labelRect, selected: slot == selected)
            }
            let central = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)
            (selected == .tap ? palette.function : palette.key).setFill(); UIBezierPath(ovalIn: central).fill()
            text(label(values[.tap]), in: central.insetBy(dx: 2, dy: 2), selected: selected == .tap)
        }
    }
    private func label(_ output: CircularFlickOutput?) -> String {
        switch output {
        case .text(let text, let label): return label ?? text
        case .action(_, _, let label): return label
        case .mapSwitch: return "⇄"
        case .referenceAction(_, let label): return label ?? ""
        case nil: return ""
        }
    }
}
