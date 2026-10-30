import Foundation

public enum KeyFeedbackMoment: String, CaseIterable, Codable {
    case press
    case release
}

/// Android SoundEffectConstants categories. The keyboard adapter selects one
/// from the logical key; this is not a user-configurable sound choice.
public enum KeyFeedbackSoundType: String, CaseIterable, Codable {
    case standard
    case delete
    case enter
}

public enum KeyFeedbackKeyKind: String, CaseIterable, Codable {
    case ordinary
    case delete
    case enter

    public var soundType: KeyFeedbackSoundType {
        switch self {
        case .ordinary: return .standard
        case .delete: return .delete
        case .enter: return .enter
        }
    }

    /// Resolves the UIKit key metadata used by the keyboard surface. Custom
    /// imported key actions remain ordinary unless their stable ID or label
    /// identifies Android's delete/enter sound category.
    public static func resolve(identifier: String?, label: String?, title: String?) -> Self {
        let identity = identifier?.lowercased() ?? ""
        let visibleText = [label, title].compactMap { $0 }.joined(separator: " ")
        if identity.contains("delete") || visibleText.contains("削除") || visibleText.contains("⌫") {
            return .delete
        }
        // `return` in an accessibility identifier can name a navigation control
        // (for example, return from the custom English layout), not an enter key.
        if identity.contains("enter") ||
            visibleText.contains("改行") || visibleText.contains("↵") || visibleText.contains("⏎") {
            return .enter
        }
        return .ordinary
    }

    /// Resolves imported custom-key actions using their operation, not their
    /// user-defined label. Android classifies custom actions semantically, so
    /// a literal text key that happens to display a deletion/return glyph must
    /// keep the standard sound category.
    public static func resolve(action: CustomKeyAction) -> Self? {
        guard case .command(let command) = action else { return .ordinary }
        switch command {
        case .doNothing:
            return nil
        case .delete, .backspace, .deleteUntilBoundary, .deleteAfterCursor:
            return .delete
        case .enter, .newLine, .confirm:
            return .enter
        default:
            return .ordinary
        }
    }
}

/// Shared policy/settings model for Android-compatible key feedback preferences.
public struct KeyFeedbackSettings: Codable, Equatable {
    public enum VibrationTiming: String, CaseIterable, Codable {
        case press
        case release
        case both
        /// Used for unknown Android preference values so they do not vibrate.
        case disabled

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try? container.decode(String.self)
            self = rawValue.flatMap(Self.init(rawValue:)) ?? .disabled
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public static let storageKey = "input.keyFeedback"
    public static let maximumStorageBytes = 4096

    /// Android `vibration_preference`; enabled by default.
    public var isVibrationEnabled = true
    /// Android `vibration_timing`; Android's default is `both`.
    public var vibrationTiming: VibrationTiming = .both
    /// Android `key_sound_preference`; disabled by default.
    public var isKeySoundEnabled = false
    /// Android `key_sound_volume_percent_preference`. Zero means system default,
    /// not muted; muting is controlled by `isKeySoundEnabled`.
    public var keySoundVolumePercent = 0

    public init() {}

    public var normalized: Self {
        var value = self
        value.keySoundVolumePercent = min(100, max(0, value.keySoundVolumePercent))
        return value
    }

    public func shouldVibrate(at moment: KeyFeedbackMoment, isKeyboardLayoutEditing: Bool = false) -> Bool {
        guard !isKeyboardLayoutEditing else { return false }
        guard isVibrationEnabled else { return false }
        switch (vibrationTiming, moment) {
        case (.press, .press), (.release, .release), (.both, _): return true
        case (.press, .release), (.release, .press), (.disabled, _): return false
        }
    }

    /// Android emits a key sound on press only, and only while the ringer is
    /// in normal mode.
    public func shouldPlaySound(
        at moment: KeyFeedbackMoment,
        isRingerModeNormal: Bool,
        isKeyboardLayoutEditing: Bool = false
    ) -> Bool {
        moment == .press && isKeySoundEnabled && isRingerModeNormal && !isKeyboardLayoutEditing
    }

    /// `nil` requests the platform's system-default sound volume. A numeric
    /// value is the Android-compatible 0.01...1.0 multiplier.
    public var soundVolumeMultiplier: Double? {
        let volume = normalized.keySoundVolumePercent
        guard volume > 0 else { return nil }
        return Double(volume) / 100
    }

    public static func load(defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              data.count <= maximumStorageBytes,
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return value.normalized
    }

    public func save(defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized),
              data.count <= Self.maximumStorageBytes else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case isVibrationEnabled
        case vibrationTiming
        case isKeySoundEnabled
        case keySoundVolumePercent
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.isVibrationEnabled) {
            isVibrationEnabled = (try? container.decode(Bool.self, forKey: .isVibrationEnabled)) ?? true
        }
        if container.contains(.vibrationTiming) {
            if (try? container.decodeNil(forKey: .vibrationTiming)) == true {
                // A missing/null Android preference resolves to its `both` default.
                vibrationTiming = .both
            } else {
                // Android's VibrationTimingPolicy rejects unrecognized values.
                vibrationTiming = (try? container.decode(VibrationTiming.self, forKey: .vibrationTiming)) ?? .disabled
            }
        }
        if container.contains(.isKeySoundEnabled) {
            isKeySoundEnabled = (try? container.decode(Bool.self, forKey: .isKeySoundEnabled)) ?? false
        }
        if container.contains(.keySoundVolumePercent) {
            keySoundVolumePercent = (try? container.decode(Int.self, forKey: .keySoundVolumePercent)) ?? 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVibrationEnabled, forKey: .isVibrationEnabled)
        try container.encode(vibrationTiming, forKey: .vibrationTiming)
        try container.encode(isKeySoundEnabled, forKey: .isKeySoundEnabled)
        try container.encode(normalized.keySoundVolumePercent, forKey: .keySoundVolumePercent)
    }
}
