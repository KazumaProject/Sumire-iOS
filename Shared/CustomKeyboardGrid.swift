import UIKit
import SumireCore

/// Layout in Android half-cell units; slots remain fixed when key scale changes.
final class CustomKeyboardGrid: UIView {
    private let layout: ImportedCustomLayout
    private let controls: [(ImportedCustomLayout.Placement, UIView)]
    init(layout: ImportedCustomLayout, makeKey: (ImportedCustomLayout.Placement) -> UIView) {
        self.layout = layout
        controls = layout.placements.filter { !$0.isSpacer }.map { ($0, makeKey($0)) }
        super.init(frame: .zero)
        controls.forEach { addSubview($0.1) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width / CGFloat(layout.columns * 2)
        let height = bounds.height / CGFloat(layout.rows * 2)
        for (key, view) in controls {
            let slot = CGRect(x: CGFloat(key.column) * width, y: CGFloat(key.row) * height,
                              width: CGFloat(key.width) * width, height: CGFloat(key.height) * height)
            view.frame = slot.insetBy(dx: min(3, slot.width / 2), dy: min(3, slot.height / 2))
        }
    }
}
