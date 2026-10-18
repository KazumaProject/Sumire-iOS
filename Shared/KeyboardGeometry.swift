import UIKit

/// Shape is independent of palette. Values are in points; candidate row height
/// remains 44 regardless of key styling. Tuned against the iOS 26.4 Simulator
/// standard keyboard screenshot; not a claim of pixel parity on other versions.
struct KeyboardGeometry {
    var keyCornerRadius: CGFloat = 10
    var surfaceCornerRadius: CGFloat = 24
    var horizontalInset: CGFloat = 8
    var keySpacing: CGFloat = 6
    var rowSpacing: CGFloat = 7
}
