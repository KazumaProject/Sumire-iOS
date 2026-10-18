import UIKit
import SumireCore

/// Tonal palette for the native prototype. Android Material parity remains a separate validation gate.
struct KeyboardPalette {
    let background: UIColor
    let key: UIColor
    let function: UIColor
    let accent: UIColor
    let foreground: UIColor
    let accentForeground: UIColor
    init(hue: CGFloat, dark: Bool, saturation: CGFloat = 0.5, brightness: CGFloat = 0.7) {
        let tones = KeyboardTheme(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness)).tones(dark: dark)
        func color(_ tone: KeyboardThemeTone) -> UIColor {
            UIColor(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness, alpha: 1)
        }
        background = color(tones.background)
        key = color(tones.key)
        function = color(tones.function)
        accent = color(tones.accent)
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
