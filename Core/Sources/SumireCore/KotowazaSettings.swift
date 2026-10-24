import Foundation

/// Controls the optional Android-compatible proverb completion dictionary.
public enum KotowazaSettings {
    public static let enabledKey = "kotowaza.enabled"

    /// Android defaults this preference to enabled when no value was saved.
    public static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
}
