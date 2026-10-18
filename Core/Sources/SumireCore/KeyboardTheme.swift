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

/// HSV tones, independent of UIKit, shared by the keyboard and settings preview.
/// This is a Sumire tonal palette, not the Material HCT algorithm.
public struct KeyboardThemeTone: Equatable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double
}

public struct KeyboardThemeTones: Equatable {
    public let background: KeyboardThemeTone
    public let key: KeyboardThemeTone
    public let function: KeyboardThemeTone
    public let accent: KeyboardThemeTone
}

extension KeyboardTheme {
    public func tones(dark: Bool) -> KeyboardThemeTones {
        let base = Self(hue: hue, mode: mode, saturation: saturation, brightness: brightness)
        func tone(_ saturation: Double, _ brightness: Double) -> KeyboardThemeTone {
            KeyboardThemeTone(hue: base.hue,
                              saturation: min(1, saturation * base.saturation / 0.5),
                              brightness: min(1, max(0, brightness)))
        }
        // Keep neutral surfaces readable while allowing the selected seed color to tint them.
        let shift = (base.brightness - 0.7) * 0.06
        return KeyboardThemeTones(
            background: tone(dark ? 0.20 : 0.08, (dark ? 0.14 : 0.94) + shift),
            key: tone(dark ? 0.15 : 0.025, (dark ? 0.27 : 1) + shift),
            function: tone(dark ? 0.28 : 0.14, (dark ? 0.36 : 0.86) + shift),
            accent: tone(0.5, base.brightness + (dark ? 0.05 : 0)))
    }
}
