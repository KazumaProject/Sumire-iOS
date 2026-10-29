/// Request eligibility copied from the pinned Android Zenz live-generation path.
/// This value policy is not wired to the iOS request/runtime path yet.
public enum AndroidZenzRequestSource: Equatable {
    case automaticLive
    case manualConvertLongPress
    case bunsetsuSegment
}

public struct AndroidZenzRequestSettings: Equatable {
    public let zenzEnabled: Bool
    public let longPressConversionEnabled: Bool
    public let hardwareKeyboardConnected: Bool
    public let rerankEnabled: Bool
    public let zenzaiEnabled: Bool

    public init(
        zenzEnabled: Bool,
        longPressConversionEnabled: Bool,
        hardwareKeyboardConnected: Bool,
        rerankEnabled: Bool,
        zenzaiEnabled: Bool
    ) {
        self.zenzEnabled = zenzEnabled
        self.longPressConversionEnabled = longPressConversionEnabled
        self.hardwareKeyboardConnected = hardwareKeyboardConnected
        self.rerankEnabled = rerankEnabled
        self.zenzaiEnabled = zenzaiEnabled
    }
}

public enum AndroidZenzRequestBlockReason: Equatable {
    case emptyInput
    case longPressConversionDisabled
    case zenzDisabled
    case hardwareKeyboardConnected
    case inputTooShort
    case inputNotHiraganaWithSymbols
    case rerankRequiresZenzai
}

public enum AndroidZenzRequestPolicy {
    /// Returns the first Android-equivalent reason that prevents a request.
    public static func blockReason(
        for displayInput: String,
        source: AndroidZenzRequestSource,
        settings: AndroidZenzRequestSettings
    ) -> AndroidZenzRequestBlockReason? {
        if displayInput.isEmpty { return .emptyInput }

        if source == .manualConvertLongPress {
            if !settings.longPressConversionEnabled { return .longPressConversionDisabled }
        } else if !settings.zenzEnabled {
            return .zenzDisabled
        }

        if settings.hardwareKeyboardConnected { return .hardwareKeyboardConnected }
        // Android String.length counts UTF-16 code units.
        if displayInput.utf16.count <= 1 { return .inputTooShort }
        if !isAllHiraganaWithSymbols(displayInput) { return .inputNotHiraganaWithSymbols }

        if source != .manualConvertLongPress && settings.rerankEnabled && !settings.zenzaiEnabled {
            return .rerankRequiresZenzai
        }
        return nil
    }

    /// Mirrors Android's `Char.isHiraganaWithSymbols`, including its exact
    /// BMP range and punctuation set rather than a broader Unicode category.
    public static func isAllHiraganaWithSymbols(_ value: String) -> Bool {
        let units = value.utf16
        guard !units.isEmpty else { return false }
        return units.allSatisfy(isAllowedHiraganaOrSymbol)
    }

    private static func isAllowedHiraganaOrSymbol(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x3041...0x3096, 0x30FC, 0x002D, 0xFF1F, 0x003F, 0xFF01, 0x0021, 0x3002, 0x3001:
            return true
        default:
            return false
        }
    }
}

/// Validates Android Zenz output before it enters user-visible candidates.
/// The iOS live-result path does not call this policy yet.
public enum AndroidZenzOutputPolicy {
    private static let protocolMarkerRange: ClosedRange<UInt32> = 0xEE00...0xEE0F

    public static func acceptedTextOrNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty, isSafeUserVisibleText(value) else { return nil }
        return value
    }

    public static func isSafeUserVisibleText(_ value: String) -> Bool {
        isSafeUTF16CodeUnits(Array(value.utf16))
    }

    /// Kept internal so tests can cover malformed UTF-16 that Swift String
    /// cannot represent without replacement while matching Java's codePointAt.
    static func isSafeUTF16CodeUnits(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            let first = units[index]
            let codePoint: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    return false
                }
                let high = UInt32(first - 0xD800)
                let low = UInt32(units[index + 1] - 0xDC00)
                codePoint = 0x10000 + (high << 10) + low
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else { return false }
                codePoint = UInt32(first)
                index += 1
            }

            if protocolMarkerRange.contains(codePoint) ||
                codePoint < 0x20 || codePoint == 0x7F || codePoint == 0xFFFD {
                return false
            }
        }
        return true
    }
}
