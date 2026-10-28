import Foundation

/// The identity Android uses when it reconnects a displayed merged candidate
/// to a candidate in the native whole-reading result.
public struct BunsetsuCandidateDisplayIdentity {
    public let surface: String
    public let readingUTF16Length: Int

    public init(surface: String, readingUTF16Length: Int) {
        self.surface = surface
        self.readingUTF16Length = readingUTF16Length
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.readingUTF16Length == rhs.readingUTF16Length &&
            bunsetsuStringsMatchUTF16(lhs.surface, rhs.surface)
    }
}

extension BunsetsuCandidateDisplayIdentity: Equatable {}

public enum BunsetsuConversionSnapshotError: Error, Equatable {
    case readingLengthMismatch
    case readingIdentityMismatch
    case generationMismatch
}

/// A copied native candidate record. `mappedSplitPositions == nil` means the
/// engine returned no mapping for this surface; an empty array is an explicit
/// unsplit mapping and must not fall back to the primary split.
public struct BunsetsuSnapshotCandidate {
    public let nativeIndex: Int
    public let candidateID: UInt64
    public let score: Int64
    public let identity: BunsetsuCandidateDisplayIdentity
    /// Native token path in UTF-16 reading coordinates. It stores converted
    /// token surfaces and ranges, not a second copy of the source reading.
    public let tokenPath: [BunsetsuToken]?
    public let mappedSplitPositions: [Int]?

    public init(
        nativeIndex: Int,
        candidateID: UInt64,
        score: Int64,
        identity: BunsetsuCandidateDisplayIdentity,
        tokenPath: [BunsetsuToken]?,
        mappedSplitPositions: [Int]?
    ) {
        self.nativeIndex = nativeIndex
        self.candidateID = candidateID
        self.score = score
        self.identity = identity
        self.tokenPath = tokenPath
        self.mappedSplitPositions = mappedSplitPositions
    }
}

/// Immutable, owned data copied from one native whole-reading bunsetsu result.
/// Native candidate order and token paths are retained for later Android-style
/// split resolution and candidate-specific projection. Candidates are sorted
/// by their original native index so omissions or bridge reordering cannot
/// change which duplicate display identity wins.
public struct BunsetsuConversionSnapshot {
    /// The native result generation reported for the request that produced
    /// this snapshot. Callers must compare it with the generation they are
    /// about to display before projecting any path or split metadata.
    public let requestGeneration: UInt64
    /// Exact UTF-16 units from the source request. Swift String equality uses
    /// canonical equivalence, so request freshness must compare these units.
    private let sourceReadingUTF16Identity: [UInt16]
    public var readingUTF16Length: Int { sourceReadingUTF16Identity.count }
    // Raw native boundaries and paths stay module-internal. Public consumers
    // must use the request-validated resolution/projection APIs below.
    let splitPatterns: [[Int]]
    let primarySplitPositions: [Int]
    let candidates: [BunsetsuSnapshotCandidate]
    /// Native indexes must identify exactly one candidate each. An invalid
    /// set is retained for diagnosis, but is never used to resolve splits.
    let hasValidNativeIndices: Bool

    public init(
        requestGeneration: UInt64,
        reading: String,
        splitPatterns: [[Int]],
        primarySplitPositions: [Int],
        candidates: [BunsetsuSnapshotCandidate]
    ) {
        self.requestGeneration = requestGeneration
        self.sourceReadingUTF16Identity = Array(reading.utf16)
        self.splitPatterns = splitPatterns
        self.primarySplitPositions = primarySplitPositions
        self.hasValidNativeIndices = candidates.allSatisfy { $0.nativeIndex >= 0 } &&
            Set(candidates.map(\.nativeIndex)).count == candidates.count
        self.candidates = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.nativeIndex != rhs.element.nativeIndex {
                return lhs.element.nativeIndex < rhs.element.nativeIndex
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Mirrors Android's first full-reading candidate selection. A mapped
    /// empty array is authoritative; only an unmapped first native candidate
    /// may fall back to the result's primary positions. The request identity
    /// is mandatory so stale native splits cannot be resolved against new text.
    public func initialSplitPositions(
        reading: String,
        requestGeneration: UInt64,
        for orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) throws -> [Int] {
        try validateRequest(reading: reading, requestGeneration: requestGeneration)
        return initialSplitPositionsUnchecked(for: orderedDisplayCandidates)
    }

    private func initialSplitPositionsUnchecked(
        for orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) -> [Int] {
        guard hasValidNativeIndices else { return [] }

        let fullReadingLength = readingUTF16Length
        for displayCandidate in orderedDisplayCandidates {
            guard displayCandidate.readingUTF16Length == fullReadingLength,
                  let candidatePosition = candidates.firstIndex(where: {
                      $0.identity == displayCandidate
                  }) else {
                continue
            }

            let candidate = candidates[candidatePosition]
            if let mappedPositions = candidate.mappedSplitPositions {
                return Self.sanitize(mappedPositions, readingUTF16Length: fullReadingLength)
            }
            if candidate.nativeIndex == 0 {
                return Self.sanitize(primarySplitPositions, readingUTF16Length: fullReadingLength)
            }
        }
        return []
    }

    /// Mirrors Android normalization: put the resolved initial pattern first,
    /// then append distinct native result patterns in engine order. The
    /// request identity is required for the same reason as initial resolution.
    public func normalizedSplitPatterns(
        reading: String,
        requestGeneration: UInt64,
        for orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) throws -> [[Int]] {
        try validateRequest(reading: reading, requestGeneration: requestGeneration)
        return normalizedSplitPatternsUnchecked(for: orderedDisplayCandidates)
    }

    private func normalizedSplitPatternsUnchecked(
        for orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) -> [[Int]] {
        let initial = initialSplitPositionsUnchecked(for: orderedDisplayCandidates)
        var normalized = [initial]
        for pattern in splitPatterns {
            let sanitized = Self.sanitize(pattern, readingUTF16Length: readingUTF16Length)
            if !normalized.contains(sanitized) {
                normalized.append(sanitized)
            }
        }
        return normalized
    }

    /// Builds ordered split projections from this owned snapshot. The request
    /// owner supplies the reading, which must exactly match the native result's
    /// UTF-16 identity before any copied paths or boundaries are used.
    /// Swift cannot represent the isolated surrogate halves Android can create
    /// by substringing inside a UTF-16 pair, so unsafe split/token boundaries
    /// are omitted and those intervals remain in reading form.
    public func projectedSplitPatterns(
        reading: String,
        requestGeneration: UInt64,
        orderedDisplayCandidates: [BunsetsuCandidateDisplayIdentity]
    ) throws -> [BunsetsuSplitPattern] {
        try validateRequest(reading: reading, requestGeneration: requestGeneration)

        let scalarBoundaries = Self.scalarBoundaryOffsets(in: reading)
        let candidatePaths: [BunsetsuCandidatePath] = hasValidNativeIndices
            ? candidates.compactMap { candidate in
                guard candidate.identity.readingUTF16Length == readingUTF16Length,
                      let tokenPath = candidate.tokenPath,
                      Self.hasOnlyScalarAlignedTokenBoundaries(
                          tokenPath,
                          readingUTF16Length: readingUTF16Length,
                          scalarBoundaries: scalarBoundaries
                      ) else {
                    return nil
                }
                return BunsetsuCandidatePath(
                    reading: reading,
                    candidate: candidate.identity.surface,
                    tokens: tokenPath
                )
            }
            : []

        var safeBoundaryPatterns: [[Int]] = []
        for pattern in normalizedSplitPatternsUnchecked(for: orderedDisplayCandidates) {
            let safePattern = pattern.filter(scalarBoundaries.contains)
            if !safeBoundaryPatterns.contains(safePattern) {
                safeBoundaryPatterns.append(safePattern)
            }
        }

        return try safeBoundaryPatterns.map { boundaries in
            var projectionPaths = candidatePaths
            // Android preserves the first plain whole-input candidate for an
            // unsplit interval even when it has no lattice path. Native snapshot
            // candidates have no source/presentation override; commit is surface.
            if boundaries.isEmpty, !reading.isEmpty, hasValidNativeIndices,
               let first = candidates.first, first.nativeIndex == 0,
               first.identity.readingUTF16Length == readingUTF16Length {
                projectionPaths = [BunsetsuCandidatePath(
                    reading: reading,
                    candidate: first.identity.surface,
                    tokens: [BunsetsuToken(
                        readingRange: NSRange(location: 0, length: readingUTF16Length),
                        text: first.identity.surface
                    )]
                )]
            }
            return try BunsetsuSplitPattern(
                reading: reading,
                boundaries: boundaries,
                candidatePaths: projectionPaths
            )
        }
    }

    private func validateRequest(reading: String, requestGeneration: UInt64) throws {
        guard requestGeneration == self.requestGeneration else {
            throw BunsetsuConversionSnapshotError.generationMismatch
        }
        let readingUnits = reading.utf16
        guard readingUnits.count == readingUTF16Length else {
            throw BunsetsuConversionSnapshotError.readingLengthMismatch
        }
        guard readingUnits.elementsEqual(sourceReadingUTF16Identity) else {
            throw BunsetsuConversionSnapshotError.readingIdentityMismatch
        }
    }

    private static func sanitize(_ positions: [Int], readingUTF16Length: Int) -> [Int] {
        Array(Set(positions.filter { $0 > 0 && $0 < readingUTF16Length })).sorted()
    }

    private static func hasOnlyScalarAlignedTokenBoundaries(
        _ tokens: [BunsetsuToken],
        readingUTF16Length: Int,
        scalarBoundaries: Set<Int>
    ) -> Bool {
        var cursor = 0
        for token in tokens {
            let range = token.readingRange
            guard range.location == cursor,
                  range.location >= 0,
                  range.length > 0,
                  range.location <= readingUTF16Length,
                  range.length <= readingUTF16Length - range.location else {
                return false
            }
            cursor += range.length
            guard scalarBoundaries.contains(cursor) else { return false }
        }
        return cursor == readingUTF16Length
    }

    private static func scalarBoundaryOffsets(in reading: String) -> Set<Int> {
        var offsets: Set<Int> = [0]
        var offset = 0
        for scalar in reading.unicodeScalars {
            offset += scalar.utf16.count
            offsets.insert(offset)
        }
        return offsets
    }
}
