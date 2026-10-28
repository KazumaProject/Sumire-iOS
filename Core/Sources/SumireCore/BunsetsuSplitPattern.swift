import Foundation

/// One coherent split of one complete conversion path. The token path is
/// projected before it enters the session; surfaces are never split by string
/// length.
public struct BunsetsuSplitPattern: Equatable {
    public let reading: String
    public let boundaries: [Int]
    public let sourceCandidate: String?
    public let segments: [BunsetsuSegment]

    /// Uses one coherent whole-input path when it can be selected; otherwise
    /// creates reading-form intervals that can still load local candidates.
    public init(
        reading: String,
        boundaries: [Int],
        candidatePaths: [BunsetsuCandidatePath]
    ) throws {
        let normalizedBoundaries = BunsetsuProjection.normalizedSplitPositions(
            in: reading,
            positions: boundaries
        )
        if let path = try BunsetsuProjection.selectCoherentCandidatePath(
            reading: reading,
            boundaries: normalizedBoundaries,
            candidates: candidatePaths
        ) {
            self.reading = reading
            self.boundaries = normalizedBoundaries
            self.sourceCandidate = path.candidate
            self.segments = try BunsetsuProjection.projectWithReadingFallback(
                reading: reading,
                candidate: path.candidate,
                tokens: path.tokens,
                boundaries: normalizedBoundaries
            )
        } else {
            self.reading = reading
            self.boundaries = normalizedBoundaries
            self.sourceCandidate = nil
            self.segments = try BunsetsuProjection.projectReadingOnly(
                reading: reading,
                boundaries: normalizedBoundaries
            )
        }
    }

    /// Creates selectable reading-form intervals when the whole-input query
    /// returned no coherent token path.
    public init(reading: String, boundaries: [Int]) throws {
        self.reading = reading
        let normalizedBoundaries = BunsetsuProjection.normalizedSplitPositions(
            in: reading,
            positions: boundaries
        )
        self.boundaries = normalizedBoundaries
        self.sourceCandidate = nil
        self.segments = try BunsetsuProjection.projectReadingOnly(
            reading: reading,
            boundaries: normalizedBoundaries
        )
    }
}
