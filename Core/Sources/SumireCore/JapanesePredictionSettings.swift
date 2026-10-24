import CoreFoundation
import Foundation

public enum JapanesePredictionAggressiveness: String, CaseIterable, Codable, Equatable {
    case conservative
    case standard
    case aggressive

    public var title: String {
        switch self {
        case .conservative: return "控えめ"
        case .standard: return "標準"
        case .aggressive: return "積極的"
        }
    }
}

/// The Android-compatible settings that affect dictionary completion candidates.
/// Values are kept in the App Group so the keyboard can read them with Full Access OFF.
public struct JapanesePredictionSettings: Equatable {
    public static let lookaheadStorageKey = "prediction.lookaheadCharacterCount"
    public static let aggressivenessStorageKey = "prediction.aggressiveness"
    public static let defaultLookaheadCharacterCount = 3
    public static let lookaheadRange = 1...6

    public let lookaheadCharacterCount: Int
    public let aggressiveness: JapanesePredictionAggressiveness

    public init(lookaheadCharacterCount: Int = defaultLookaheadCharacterCount,
                aggressiveness: JapanesePredictionAggressiveness = .standard) {
        self.lookaheadCharacterCount = min(Self.lookaheadRange.upperBound,
                                           max(Self.lookaheadRange.lowerBound, lookaheadCharacterCount))
        self.aggressiveness = aggressiveness
    }

    public static func load(defaults: UserDefaults) -> Self {
        let lookahead: Int
        if let number = defaults.object(forKey: lookaheadStorageKey) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            lookahead = number.intValue
        } else {
            lookahead = defaultLookaheadCharacterCount
        }
        let rawAggressiveness = defaults.object(forKey: aggressivenessStorageKey) as? String
        return Self(lookaheadCharacterCount: lookahead,
                    aggressiveness: rawAggressiveness.flatMap(JapanesePredictionAggressiveness.init(rawValue:)) ?? .standard)
    }

    /// Android accepts legacy labels as well as integer strings and clamps numeric values.
    public static func androidLookahead(_ value: String?) -> Int {
        guard let value else { return defaultLookaheadCharacterCount }
        let parsed: Int
        switch value {
        case "short": parsed = 1
        case "standard": parsed = defaultLookaheadCharacterCount
        case "long": parsed = lookaheadRange.upperBound
        default: parsed = Int(value) ?? defaultLookaheadCharacterCount
        }
        return min(lookaheadRange.upperBound, max(lookaheadRange.lowerBound, parsed))
    }

    public static func androidLookahead(_ value: Int) -> Int {
        min(lookaheadRange.upperBound, max(lookaheadRange.lowerBound, value))
    }
}
