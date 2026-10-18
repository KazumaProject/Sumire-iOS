import Foundation

public enum KeyboardColorMode: String, CaseIterable {
    case system, light, dark
    public var title: String {
        switch self { case .system: return "システム"; case .light: return "ライト"; case .dark: return "ダーク" }
    }
}
public struct KeyboardTheme: Equatable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double
    public var mode: KeyboardColorMode
    public init(hue: Double = 0.73, mode: KeyboardColorMode = .system, saturation: Double = 0.5, brightness: Double = 0.7) {
        self.hue = hue.isFinite ? min(1, max(0, hue)) : 0.73
        self.saturation = saturation.isFinite ? min(1, max(0, saturation)) : 0.5
        self.brightness = brightness.isFinite ? min(1, max(0, brightness)) : 0.7
        self.mode = mode
    }
    public static func load(defaults: UserDefaults) -> Self {
        Self(hue: defaults.object(forKey: "theme.hue") == nil ? 0.73 : defaults.double(forKey: "theme.hue"),
             mode: KeyboardColorMode(rawValue: defaults.string(forKey: "theme.mode") ?? "") ?? .system,
             saturation: defaults.object(forKey: "theme.saturation") == nil ? 0.5 : defaults.double(forKey: "theme.saturation"),
             brightness: defaults.object(forKey: "theme.brightness") == nil ? 0.7 : defaults.double(forKey: "theme.brightness"))
    }
    public func save(defaults: UserDefaults) {
        let normalized = Self(hue: hue, mode: mode, saturation: saturation, brightness: brightness)
        defaults.set(normalized.hue, forKey: "theme.hue")
        defaults.set(normalized.saturation, forKey: "theme.saturation")
        defaults.set(normalized.brightness, forKey: "theme.brightness")
        defaults.set(normalized.mode.rawValue, forKey: "theme.mode")
    }
}

/// An opaque sRGB color from Material Color Utilities. HSV accessors remain for
/// source compatibility; they describe the computed color, not a tonal shortcut.
public struct KeyboardThemeTone: Equatable {
    public let argb: UInt32
    public var red: Double { Double((argb >> 16) & 255) / 255 }
    public var green: Double { Double((argb >> 8) & 255) / 255 }
    public var blue: Double { Double(argb & 255) / 255 }
    public var brightness: Double { max(red, green, blue) }
    public var saturation: Double {
        brightness == 0 ? 0 : (brightness - min(red, green, blue)) / brightness
    }
    public var hue: Double {
        let delta = brightness - min(red, green, blue)
        guard delta != 0 else { return 0 }
        let sector: Double
        if brightness == red { sector = (green - blue) / delta }
        else if brightness == green { sector = (blue - red) / delta + 2 }
        else { sector = (red - green) / delta + 4 }
        return (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
    }
    public init(argb: UInt32) { self.argb = argb | 0xff00_0000 }
}

public struct KeyboardThemeTones: Equatable {
    public let background: KeyboardThemeTone
    public let key: KeyboardThemeTone
    public let function: KeyboardThemeTone
    public let accent: KeyboardThemeTone
    public let foreground: KeyboardThemeTone
    public let functionForeground: KeyboardThemeTone
    public let accentForeground: KeyboardThemeTone
    public let keyPressed: KeyboardThemeTone
    public let functionPressed: KeyboardThemeTone
}

extension KeyboardTheme {
    /// Existing HSV preferences continue to represent the selected sRGB seed.
    /// Material color generation starts from this quantized opaque ARGB value.
    public var seedARGB: UInt32 {
        let seed = Self(hue: hue, mode: mode, saturation: saturation, brightness: brightness)
        let h = (seed.hue == 1 ? 0 : seed.hue) * 6
        let chroma = seed.brightness * seed.saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = seed.brightness - chroma
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (chroma, x, 0)
        case 1: rgb = (x, chroma, 0)
        case 2: rgb = (0, chroma, x)
        case 3: rgb = (0, x, chroma)
        case 4: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        func byte(_ value: Double) -> UInt32 { UInt32(((value + m) * 255).rounded()) }
        return 0xff00_0000 | byte(rgb.0) << 16 | byte(rgb.1) << 8 | byte(rgb.2)
    }

    public func tones(dark: Bool) -> KeyboardThemeTones {
        let roles = MaterialContentColors.resolve(seedARGB: seedARGB, dark: dark)
        func tone(_ argb: UInt32) -> KeyboardThemeTone { KeyboardThemeTone(argb: argb) }
        // Android Sumire 9506: keyboard_root_material and ten_keys_{center,side}_bg_material.
        return KeyboardThemeTones(
            background: tone(roles.surfaceContainer),
            key: tone(dark ? roles.surfaceContainerHighest : roles.surface),
            function: tone(roles.secondaryContainer),
            accent: tone(roles.primary),
            foreground: tone(roles.onSurface),
            functionForeground: tone(roles.onSecondaryContainer),
            accentForeground: tone(roles.onPrimary),
            keyPressed: tone(dark ? roles.surfaceContainerHigh : roles.surfaceVariant),
            // The dark drawable uses colorSecondaryVariant, explicitly set to
            // main_text_color (#D1D1D1) by the reference theme, not a dynamic role.
            functionPressed: tone(dark ? 0xffd1_d1d1 : roles.surfaceContainerHigh))
    }
}
