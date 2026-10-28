import Foundation

/// A user-dictionary entry together with its position in the unfiltered source.
/// Keeping the source index lets UI lists edit and delete the correct item after sorting.
public struct PersonalDictionarySearchResult: Equatable, Identifiable {
    public let sourceIndex: Int
    public let word: PersonalWord

    public var id: Int { sourceIndex }

    public init(sourceIndex: Int, word: PersonalWord) {
        self.sourceIndex = sourceIndex
        self.word = word
    }
}

/// Android user-dictionary ordering and search: an unfiltered list is ordered by
/// SQLite's binary reading order; a query matches case-insensitive prefixes on
/// the surface or reading, with exact matches first, then shorter matching text.
public enum PersonalDictionarySearch {
    private struct RankedResult {
        let result: PersonalDictionarySearchResult
        let rank: Int
        let matchedLength: Int
    }

    public static func results(for entries: [PersonalWord], query rawQuery: String) -> [PersonalDictionarySearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return entries.enumerated()
                .map { PersonalDictionarySearchResult(sourceIndex: $0.offset, word: $0.element) }
                .sorted { lhs, rhs in
                    let readingOrder = compareSQLiteBinary(lhs.word.reading, rhs.word.reading)
                    if readingOrder != .orderedSame { return readingOrder == .orderedAscending }
                    return lhs.sourceIndex < rhs.sourceIndex
                }
        }

        let ranked = entries.enumerated().compactMap { index, word -> RankedResult? in
            let readingMatches = hasPrefix(word.reading, query: query)
            let surfaceMatches = hasPrefix(word.word, query: query)
            guard readingMatches || surfaceMatches else { return nil }

            let exact = equals(word.reading, query) || equals(word.word, query)
            let matchedLength = [readingMatches ? word.reading.utf16.count : nil,
                                 surfaceMatches ? word.word.utf16.count : nil]
                .compactMap { $0 }.min() ?? Int.max
            return RankedResult(
                result: PersonalDictionarySearchResult(sourceIndex: index, word: word),
                rank: exact ? 0 : 1,
                matchedLength: matchedLength
            )
        }

        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.matchedLength != rhs.matchedLength { return lhs.matchedLength < rhs.matchedLength }
            let readingOrder = compareUTF16(lhs.result.word.reading, rhs.result.word.reading)
            if readingOrder != .orderedSame { return readingOrder == .orderedAscending }
            let surfaceOrder = compareUTF16(lhs.result.word.word, rhs.result.word.word)
            if surfaceOrder != .orderedSame { return surfaceOrder == .orderedAscending }
            return lhs.result.sourceIndex < rhs.result.sourceIndex
        }.map(\.result)
    }

    private static func hasPrefix(_ value: String, query: String) -> Bool {
        value.range(of: query, options: [.anchored, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func equals(_ value: String, _ other: String) -> Bool {
        value.compare(other, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }

    /// Kotlin String comparison orders UTF-16 code units; use the same stable
    /// ordering for ties instead of the user's locale-sensitive display collation.
    private static func compareUTF16(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf16.elementsEqual(rhs.utf16) { return .orderedSame }
        return lhs.utf16.lexicographicallyPrecedes(rhs.utf16) ? .orderedAscending : .orderedDescending
    }

    /// Android's Room query uses `ORDER BY reading ASC` without a collation,
    /// which is SQLite BINARY ordering over the stored UTF-8 text.
    private static func compareSQLiteBinary(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf8.elementsEqual(rhs.utf8) { return .orderedSame }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
    }
}
