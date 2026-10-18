import UIKit
import SumireCore

/// A spanning key occupies one view and one hit target. Geometry is recomputed
/// on bounds changes, without rebuilding controls or touching composition state.
final class KeyboardGrid: UIView {
    private let definition: KeyboardLayout
    private let controls: [UIView]
    private let horizontalGap: CGFloat
    private let verticalGap: CGFloat
    private let columnWeights: [CGFloat]
    init(layout: KeyboardLayout, horizontalGap: CGFloat, verticalGap: CGFloat,
         columnWeights: [CGFloat]? = nil,
         makeKey: (KeyboardLayout.Key) -> UIView) throws {
        try layout.validate()
        definition = layout
        controls = layout.keys.map(makeKey)
        self.horizontalGap = max(0, horizontalGap)
        self.verticalGap = max(0, verticalGap)
        if let columnWeights, columnWeights.count == layout.columns,
           columnWeights.allSatisfy({ $0.isFinite && $0 > 0 }) {
            self.columnWeights = columnWeights
        } else { self.columnWeights = Array(repeating: 1, count: layout.columns) }
        super.init(frame: .zero)
        controls.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let columns = CGFloat(definition.columns), rows = CGFloat(definition.rows)
        let gapX = min(horizontalGap, bounds.width / max(1, columns - 1))
        let gapY = min(verticalGap, bounds.height / max(1, rows - 1))
        let unitWidth = max(0, (bounds.width - gapX * (columns - 1)) / columnWeights.reduce(0, +))
        let offsets = columnWeights.reduce(into: [CGFloat(0)]) { $0.append($0.last! + $1 * unitWidth + gapX) }
        let height = max(0, (bounds.height - gapY * (rows - 1)) / rows)
        for (key, control) in zip(definition.keys, controls) {
            control.frame = CGRect(x: bounds.minX + offsets[key.column],
                                   y: bounds.minY + CGFloat(key.row) * (height + gapY),
                                   width: offsets[key.column + key.columnSpan] - offsets[key.column] - gapX,
                                   height: CGFloat(key.rowSpan) * (height + gapY) - gapY)
        }
    }
}

/// Shrinks the actual key rectangle while leaving its slot unchanged. Font sizes
/// remain in points, independent of the key's width and height.
final class SizedKey: UIView {
    let key: UIButton
    let scale: CGFloat
    init(_ key: UIButton, scale: CGFloat) {
        self.key = key; self.scale = scale
        super.init(frame: .zero)
        addSubview(key)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        key.frame = bounds.insetBy(dx: bounds.width * (1 - scale) / 2,
                                  dy: bounds.height * (1 - scale) / 2)
    }
}

/// Four QWERTY rows: inset home row, wider Shift/Delete, weighted bottom row.
/// Ratios follow the pinned Android qwerty_layout.xml (side keys 15%, bottom
/// weights .75/.5/1/1); home-row inset defaults to 23 points.
final class QwertyKeyboardGrid: UIView {
    private let rows: [[UIView]]
    private let letters: Bool
    private let gap: CGFloat
    init(rows: [[UIView]], letters: Bool, gap: CGFloat) {
        self.rows = rows; self.letters = letters; self.gap = gap
        super.init(frame: .zero)
        rows.flatMap { $0 }.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = max(0, (bounds.height - 3 * gap) / 4)
        for (rowIndex, controls) in rows.enumerated() {
            let inset: CGFloat = rowIndex == 1 && letters ? min(23, bounds.width * 0.08) : 0
            let available = max(0, bounds.width - 2 * inset - CGFloat(controls.count - 1) * gap)
            let weights: [CGFloat]
            if rowIndex == 3 { weights = controls.count == 5 ? [0.75, 0.75, 0.5, 1, 1] : [0.75, 0.5, 1, 1] }
            else if rowIndex == 2 {
                let middle = max(1, controls.count - 2)
                weights = [0.15] + Array(repeating: 0.7 / CGFloat(middle), count: middle) + [0.15]
            } else { weights = Array(repeating: 1, count: controls.count) }
            let total = weights.reduce(0, +)
            var x = inset
            for (control, weight) in zip(controls, weights) {
                let width = available * weight / total
                control.frame = CGRect(x: x, y: CGFloat(rowIndex) * (h + gap), width: width, height: h)
                x += width + gap
            }
        }
    }
}
