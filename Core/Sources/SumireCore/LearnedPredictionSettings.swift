import Foundation

/// Android-compatible settings for candidates retrieved from the learned dictionary.
/// The feature is disabled by default, matching Android's preference default.
public struct LearnedPredictionSettings: Equatable, Sendable {
    public var enabled: Bool
    public var minimumInputLength: Int
    public var candidateLimit: Int

    public init(enabled: Bool = false, minimumInputLength: Int = 4, candidateLimit: Int = 4) {
        self.enabled = enabled
        self.minimumInputLength = min(8, max(1, minimumInputLength))
        self.candidateLimit = min(8, max(1, candidateLimit))
    }

    public func allows(reading: String) -> Bool {
        enabled && reading.utf16.count >= minimumInputLength
    }
}
