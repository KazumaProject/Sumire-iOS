import Foundation

/// Keeps the original prefix stable while Android-compatible F6–F10 actions
/// are chained. Any other composition generation starts a fresh conversion.
public struct PhysicalKeyboardFunctionKeyConversionSource {
    private var originalPrefix: String?
    private var lastOutput: String?
    private var outputGeneration: UInt64?

    public init() {}

    /// Returns the original prefix only while the visible prefix and generation
    /// are exactly the output of the previous function-key conversion.
    public mutating func source(for currentPrefix: String, generation: UInt64) -> String {
        if let originalPrefix, let lastOutput, let outputGeneration,
           lastOutput == currentPrefix, outputGeneration == generation {
            return originalPrefix
        }

        reset()
        originalPrefix = currentPrefix
        return currentPrefix
    }

    public mutating func record(output: String, generation: UInt64) {
        lastOutput = output
        outputGeneration = generation
    }

    public mutating func reset() {
        originalPrefix = nil
        lastOutput = nil
        outputGeneration = nil
    }
}
