import Foundation

/// Candidate-strip visibility only; stored definitions and explicit list execution remain independent.
public enum TextMacroCandidateSettings {
    public static let enabledKey = "textMacroCandidatesEnabled"
    public static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
}
