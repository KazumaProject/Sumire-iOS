import UIKit

/// Tonal palette for the native prototype. Android Material parity remains a separate validation gate.
struct KeyboardPalette {
    let background: UIColor
    let key: UIColor
    let function: UIColor
    let accent: UIColor
    let foreground: UIColor
    let accentForeground: UIColor
    init(hue: CGFloat, dark: Bool) {
        background = UIColor(hue: hue, saturation: dark ? 0.20 : 0.08, brightness: dark ? 0.14 : 0.94, alpha: 1)
        key = UIColor(hue: hue, saturation: dark ? 0.15 : 0.025, brightness: dark ? 0.27 : 1, alpha: 1)
        function = UIColor(hue: hue, saturation: dark ? 0.28 : 0.14, brightness: dark ? 0.36 : 0.86, alpha: 1)
        accent = UIColor(hue: hue, saturation: 0.5, brightness: dark ? 0.75 : 0.70, alpha: 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        accentForeground = luminance > 0.179 ? .black : .white
        foreground = dark ? .white : UIColor(white: 0.10, alpha: 1)
    }
}
