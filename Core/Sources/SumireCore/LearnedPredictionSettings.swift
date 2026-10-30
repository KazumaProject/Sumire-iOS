import Foundation

/// Android-compatible settings for candidates retrieved from the learned dictionary.
/// The feature is disabled by default, matching Android's preference default.
public struct LearnedPredictionSettings: Equatable, Sendable {
    public static let enabledKey = "learnedPredictionEnabled"
    public static let minimumInputLengthKey = "learnedPredictionMinimumInputLength"
    public static let candidateLimitKey = "learnedPredictionCandidateLimit"

    public static func load(defaults: UserDefaults) -> Self {
        Self(enabled: defaults.bool(forKey: enabledKey),
             minimumInputLength: defaults.object(forKey: minimumInputLengthKey) == nil ? 4 : defaults.integer(forKey: minimumInputLengthKey),
             candidateLimit: defaults.object(forKey: candidateLimitKey) == nil ? 4 : defaults.integer(forKey: candidateLimitKey))
    }

    public let enabled: Bool
    public let minimumInputLength: Int
    public let candidateLimit: Int

    public init(enabled: Bool = false, minimumInputLength: Int = 4, candidateLimit: Int = 4) {
        self.enabled = enabled
        self.minimumInputLength = min(8, max(1, minimumInputLength))
        self.candidateLimit = min(8, max(1, candidateLimit))
    }

    public func allows(reading: String) -> Bool {
        enabled && reading.utf16.count >= minimumInputLength
    }
}
