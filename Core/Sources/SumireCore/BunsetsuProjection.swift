import Foundation

/// Compares identity-bearing input and output exactly as UTF-16 code units.
/// Swift `String` equality treats canonically equivalent spellings as equal,
/// while Android's String checks at these projection boundaries do not.
func bunsetsuStringsMatchUTF16(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
}

/// Reading ranges use UTF-16, while surfaces remain whole lattice tokens.
public struct BunsetsuToken: Equatable {
    public let readingRange: NSRange
    public let text: String
    public init(readingRange: NSRange, text: String) {
        self.readingRange = readingRange
        self.text = text
    }
}

/// One candidate and the complete token path returned for the same reading.
/// Callers must retain candidate order from the whole-input snapshot.
public struct BunsetsuCandidatePath: Equatable {
    public let reading: String
    public let candidate: String
    public let tokens: [BunsetsuToken]

    public init(reading: String, candidate: String, tokens: [BunsetsuToken]) {
        self.reading = reading
        self.candidate = candidate
        self.tokens = tokens
    }
}

public struct BunsetsuSegment: Equatable {
    public let readingRange: NSRange
    public let reading: String
    public fileprivate(set) var text: String
    public let hasConvertedDisplay: Bool

    init(readingRange: NSRange, reading: String, text: String, hasConvertedDisplay: Bool = true) {
        self.readingRange = readingRange
        self.reading = reading
        self.text = text
        self.hasConvertedDisplay = hasConvertedDisplay
    }
}

public enum BunsetsuProjectionError: Error, Equatable {
    case invalidPath
    case invalidBoundary
    case invalidSelection
}

public enum BunsetsuProjection {
    /// Mirrors Android's split-position sanitizer using UTF-16 input length.
    public static func normalizedSplitPositions(in reading: String, positions: [Int]) -> [Int] {
        let length = reading.utf16.count
        return Array(Set(positions.filter { $0 > 0 && $0 < length })).sorted()
    }

    /// Projects one candidate's complete path. Never combine tokens from different
    /// candidates or slice a surface using its reading's character count.
    public static func project(reading: String, candidate: String,
                               tokens: [BunsetsuToken], boundaries: [Int]) throws -> [BunsetsuSegment] {
        let length = reading.utf16.count
        if length == 0 {
            guard candidate.isEmpty, tokens.isEmpty, boundaries.isEmpty else {
                throw BunsetsuProjectionError.invalidPath
            }
            return []
        }
        var cursor = 0
        var tokenEnds = Set<Int>()
        for token in tokens {
            let range = token.readingRange
            guard range.location == cursor, range.length > 0,
                  range.length <= length - cursor else {
                throw BunsetsuProjectionError.invalidPath
            }
            cursor += range.length
            tokenEnds.insert(cursor)
        }
        guard cursor == length,
              bunsetsuStringsMatchUTF16(tokens.map(\.text).joined(), candidate) else {
            throw BunsetsuProjectionError.invalidPath
        }
        let scalarBoundaries = unicodeScalarBoundaryOffsets(in: reading)
        var previous = 0
        for boundary in boundaries {
            guard boundary > previous, boundary < length,
                  tokenEnds.contains(boundary), scalarBoundaries.contains(boundary) else {
                throw BunsetsuProjectionError.invalidBoundary
            }
            previous = boundary
        }
        var result: [BunsetsuSegment] = []
        var start = 0
        var tokenIndex = 0
        for end in boundaries + [length] {
            var text = ""
            while tokenIndex < tokens.count && tokens[tokenIndex].readingRange.location < end {
                text += tokens[tokenIndex].text
                tokenIndex += 1
            }
            let range = NSRange(location: start, length: end - start)
            guard let swiftRange = Range(range, in: reading) else {
                throw BunsetsuProjectionError.invalidBoundary
            }
            result.append(BunsetsuSegment(readingRange: range, reading: String(reading[swiftRange]), text: text))
            start = end
        }
        return result
    }

    /// Projects each interval independently. A split may fall inside a whole-path
    /// token; in that case the affected interval keeps its reading until local
    /// candidates are loaded, while intervals bounded by complete tokens remain
    /// converted. Converted surfaces are never sliced by string length.
    public static func projectWithReadingFallback(
        reading: String,
        candidate: String,
        tokens: [BunsetsuToken],
        boundaries: [Int]
    ) throws -> [BunsetsuSegment] {
        let length = reading.utf16.count
        if length == 0 {
            guard candidate.isEmpty, tokens.isEmpty, boundaries.isEmpty else {
                throw BunsetsuProjectionError.invalidPath
            }
            return []
        }

        var cursor = 0
        var tokenEnds = Set<Int>()
        for token in tokens {
            let range = token.readingRange
            guard range.location == cursor, range.length > 0,
                  range.length <= length - cursor else {
                throw BunsetsuProjectionError.invalidPath
            }
            cursor += range.length
            tokenEnds.insert(cursor)
        }
        guard cursor == length,
              bunsetsuStringsMatchUTF16(tokens.map(\.text).joined(), candidate) else {
            throw BunsetsuProjectionError.invalidPath
        }

        let intervals = try splitIntervals(reading: reading, boundaries: boundaries)
        var result: [BunsetsuSegment] = []
        for (range, segmentReading) in intervals {
            let start = range.location
            let end = NSMaxRange(range)
            let isTokenAligned = (start == 0 || tokenEnds.contains(start)) && tokenEnds.contains(end)
            let text = isTokenAligned
                ? tokens.filter { $0.readingRange.location >= start && NSMaxRange($0.readingRange) <= end }
                    .map(\.text).joined()
                : segmentReading
            result.append(BunsetsuSegment(
                readingRange: range,
                reading: segmentReading,
                text: text,
                hasConvertedDisplay: isTokenAligned
            ))
        }
        return result
    }

    /// Produces selectable reading-form intervals when the whole-input result
    /// has no coherent token path. Local segment candidates can replace these
    /// readings later without inventing or slicing whole-result surfaces.
    public static func projectReadingOnly(
        reading: String,
        boundaries: [Int]
    ) throws -> [BunsetsuSegment] {
        try splitIntervals(reading: reading, boundaries: boundaries).map { range, segmentReading in
            BunsetsuSegment(
                readingRange: range,
                reading: segmentReading,
                text: segmentReading,
                hasConvertedDisplay: false
            )
        }
    }

    /// Mirrors Android's snapshot-level choice: prefer the first coherent
    /// candidate path that covers every split boundary; if none does, retain
    /// the first coherent whole-input path and let unaligned intervals show
    /// their readings.
    public static func selectCoherentCandidatePath(
        reading: String,
        boundaries: [Int],
        candidates: [BunsetsuCandidatePath]
    ) throws -> BunsetsuCandidatePath? {
        _ = try splitIntervals(reading: reading, boundaries: boundaries)

        var firstCoherent: BunsetsuCandidatePath?
        for candidate in candidates {
            guard bunsetsuStringsMatchUTF16(candidate.reading, reading) else { continue }
            guard let tokenEnds = coherentTokenEnds(
                reading: reading,
                candidate: candidate.candidate,
                tokens: candidate.tokens
            ) else { continue }
            if firstCoherent == nil {
                firstCoherent = candidate
            }
            if boundaries.allSatisfy(tokenEnds.contains) {
                return candidate
            }
        }
        return firstCoherent
    }

    private static func splitIntervals(
        reading: String,
        boundaries: [Int]
    ) throws -> [(NSRange, String)] {
        let length = reading.utf16.count
        if length == 0 {
            guard boundaries.isEmpty else { throw BunsetsuProjectionError.invalidBoundary }
            return []
        }

        let scalarBoundaries = unicodeScalarBoundaryOffsets(in: reading)
        var previous = 0
        for boundary in boundaries {
            guard boundary > previous, boundary < length,
                  scalarBoundaries.contains(boundary) else {
                throw BunsetsuProjectionError.invalidBoundary
            }
            previous = boundary
        }

        var intervals: [(NSRange, String)] = []
        var start = 0
        for end in boundaries + [length] {
            let range = NSRange(location: start, length: end - start)
            guard let swiftRange = Range(range, in: reading) else {
                throw BunsetsuProjectionError.invalidBoundary
            }
            intervals.append((range, String(reading[swiftRange])))
            start = end
        }
        return intervals
    }

    /// Android split offsets are UTF-16 based, so they may divide a grapheme
    /// such as a base letter plus combining mark. Swift strings can preserve
    /// those scalar-aligned pieces, but a cut inside a surrogate pair would
    /// create malformed UTF-16 and is rejected.
    private static func unicodeScalarBoundaryOffsets(in reading: String) -> Set<Int> {
        var offsets: Set<Int> = [0]
        var offset = 0
        for scalar in reading.unicodeScalars {
            offset += scalar.utf16.count
            offsets.insert(offset)
        }
        return offsets
    }

    private static func coherentTokenEnds(
        reading: String,
        candidate: String,
        tokens: [BunsetsuToken]
    ) -> Set<Int>? {
        let length = reading.utf16.count
        guard length > 0 else { return nil }

        var cursor = 0
        var tokenEnds = Set<Int>()
        for token in tokens {
            let range = token.readingRange
            guard range.location == cursor, range.length > 0,
                  range.length <= length - cursor else { return nil }
            cursor += range.length
            tokenEnds.insert(cursor)
        }
        guard cursor == length,
              bunsetsuStringsMatchUTF16(tokens.map(\.text).joined(), candidate) else { return nil }
        return tokenEnds
    }

    /// Returns the first segment's reading only when the projected path really
    /// divides the typed reading. The UTF-16 range must be scalar-aligned so
    /// callers can retain the suffix, even when the split is inside a grapheme.
    public static func firstReadingPrefix(in segments: [BunsetsuSegment], reading: String) -> String? {
        guard segments.count > 1, let first = segments.first,
              first.readingRange.location == 0,
              first.readingRange.length > 0,
              first.readingRange.length < reading.utf16.count,
              let range = Range(first.readingRange, in: reading) else { return nil }
        return String(reading[..<range.upperBound])
    }
}

/// Editing a selected bunsetsu preserves every other whole-sentence choice.
public struct BunsetsuSelection: Equatable {
    public private(set) var segments: [BunsetsuSegment]
    public private(set) var selectedIndex: Int
    public var text: String { segments.map(\.text).joined() }
    public var selectedReadingRange: NSRange? {
        segments.indices.contains(selectedIndex) ? segments[selectedIndex].readingRange : nil
    }
    public init(segments: [BunsetsuSegment]) {
        self.segments = segments
        self.selectedIndex = 0
    }
    public mutating func select(_ index: Int) throws {
        guard segments.indices.contains(index) else { throw BunsetsuProjectionError.invalidSelection }
        selectedIndex = index
    }
    public mutating func replaceSelected(text: String) throws {
        guard segments.indices.contains(selectedIndex), !text.isEmpty else {
            throw BunsetsuProjectionError.invalidSelection
        }
        segments[selectedIndex].text = text
    }
    /// Keep the whole-input result first when isolated segment alternatives arrive.
    public func alternatives(_ candidates: [String]) -> [String] {
        guard segments.indices.contains(selectedIndex) else { return [] }
        var seen = Set<String>()
        return ([segments[selectedIndex].text] + candidates).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
