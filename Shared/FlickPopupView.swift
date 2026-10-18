import UIKit

/// One noninteractive overlay per active key. Owned by that key rather than a
/// singleton, so independent touches cannot dismiss one another's previews.
final class FlickPopupView: UIView {
    private let labels = (0..<5).map { _ in UILabel() }
    private let cells = (0..<5).map { _ in UIView() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        for (cell, label) in zip(cells, labels) {
            cell.layer.cornerRadius = 8
            cell.layer.borderWidth = 0.5
            label.textAlignment = .center
            label.numberOfLines = 2
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            cell.addSubview(label)
            addSubview(cell)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(values: [String], selected: Int, fontSize: CGFloat,
                background: UIColor, foreground: UIColor, highlight: UIColor) {
        for i in 0..<5 {
            labels[i].text = values.indices.contains(i) ? values[i] : ""
            labels[i].font = .systemFont(ofSize: fontSize)
            labels[i].textColor = foreground
            cells[i].backgroundColor = i == selected ? highlight : background
            cells[i].layer.borderColor = foreground.withAlphaComponent(0.25).cgColor
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / 3, h = bounds.height / 3
        // tap, left, up, right, down (FlickDirection raw values).
        for (i, p) in [(1,1),(0,1),(1,0),(2,1),(1,2)].enumerated() {
            cells[i].frame = CGRect(x: CGFloat(p.0)*w, y: CGFloat(p.1)*h, width: w, height: h).insetBy(dx: 1, dy: 1)
            labels[i].frame = cells[i].bounds.insetBy(dx: 3, dy: 2)
        }
    }
    func place(keyRect: CGRect, within host: UIView, scale: CGFloat) {
        let available = host.bounds.insetBy(dx: 2, dy: 2)
        guard available.width > 0, available.height > 0 else { isHidden = true; return }
        isHidden = false
        let side = min(available.width, available.height, max(108, keyRect.width * 3) * scale)
        let x = min(max(keyRect.midX - side / 2, available.minX), available.maxX - side)
        let y = min(max(keyRect.midY - side / 2, available.minY), available.maxY - side)
        frame = CGRect(x: x, y: y, width: side, height: side)
    }
}
