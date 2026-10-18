import Foundation

/// Reading ranges use UTF-16, while surfaces remain whole lattice tokens.
public struct BunsetsuToken: Equatable {
    public let readingRange: NSRange
    public let text: String
    public init(readingRange: NSRange, text: String) {
        self.readingRange = readingRange
        self.text = text
    }
}

public struct BunsetsuSegment: Equatable {
    public let readingRange: NSRange
    public let reading: String
    public fileprivate(set) var text: String
}

public enum BunsetsuProjectionError: Error, Equatable {
    case invalidPath
    case invalidBoundary
    case invalidSelection
}

public enum BunsetsuProjection {
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
        guard cursor == length, tokens.map(\.text).joined() == candidate else {
            throw BunsetsuProjectionError.invalidPath
        }
        // Reject boundaries inside a grapheme, even when a lattice token ends there.
        var characterEnds = Set<Int>()
        var offset = 0
        for character in reading {
            offset += String(character).utf16.count
            characterEnds.insert(offset)
        }
        var previous = 0
        for boundary in boundaries {
            guard boundary > previous, boundary < length,
                  tokenEnds.contains(boundary), characterEnds.contains(boundary) else {
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

    /// Returns the first segment's reading only when the projected path really
    /// divides the typed reading. The UTF-16 range must remain on Swift string
    /// boundaries so callers can safely retain the unconverted suffix.
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
