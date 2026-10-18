import UIKit
import SumireCore

/// Adapts the shared Material SchemeContent roles to UIKit sRGB colors.
struct KeyboardPalette {
    let background: UIColor
    let key: UIColor
    let function: UIColor
    let accent: UIColor
    let foreground: UIColor
    let accentForeground: UIColor
    let functionForeground: UIColor
    let keyPressed: UIColor
    let functionPressed: UIColor
    init(hue: CGFloat, dark: Bool, saturation: CGFloat = 0.5, brightness: CGFloat = 0.7) {
        let tones = KeyboardTheme(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness)).tones(dark: dark)
        func color(_ tone: KeyboardThemeTone) -> UIColor {
            UIColor(red: tone.red, green: tone.green, blue: tone.blue, alpha: 1)
        }
        background = color(tones.background)
        key = color(tones.key)
        function = color(tones.function)
        accent = color(tones.accent)
        foreground = color(tones.foreground)
        functionForeground = color(tones.functionForeground)
        accentForeground = color(tones.accentForeground)
        keyPressed = color(tones.keyPressed)
        functionPressed = color(tones.functionPressed)
    }
}
