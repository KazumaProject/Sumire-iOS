import Foundation
import SQLite3

/// UI prefix suggestions only. Native personal graph entries stay enabled.
public struct UserDictionaryPredictionSettings: Equatable, Sendable {
    public static let enabledKey = "userDictionaryPredictionEnabled"
    public static let minimumInputLengthKey = "userDictionaryPredictionMinimumInputLength"
    public static let candidateLimitKey = "userDictionaryPredictionCandidateLimit"
    public let enabled: Bool
    public let minimumInputLength: Int
    public let candidateLimit: Int
    public init(enabled: Bool = true, minimumInputLength: Int = 2, candidateLimit: Int = 4) {
        self.enabled = enabled
        self.minimumInputLength = min(8, max(2, minimumInputLength))
        self.candidateLimit = min(8, max(1, candidateLimit))
    }
    public static func load(defaults: UserDefaults) -> Self {
        Self(enabled: defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey),
             minimumInputLength: defaults.object(forKey: minimumInputLengthKey) == nil ? 2 : defaults.integer(forKey: minimumInputLengthKey),
             candidateLimit: defaults.object(forKey: candidateLimitKey) == nil ? 4 : defaults.integer(forKey: candidateLimitKey))
    }
}

public enum UserDictionaryPredictionPolicy {
    /// df1 UserWordDao: reading LIKE prefix||'%' without ESCAPE, then
    /// posScore ASC, SQLite LENGTH(reading) ASC, id DESC, LIMIT.
    /// Portable rows may have no Android ID: known IDs precede nil on a tie;
    /// nil/equal IDs retain source-array order rather than inventing IDs.
    public static func candidates(in words: [PersonalWord], reading: String,
                                  settings: UserDictionaryPredictionSettings) throws -> [PersonalWord] {
        guard reading.utf16.count <= 8192, reading.utf8.count <= 32768,
              !reading.contains("\0"), words.count <= 100000 else {
            throw PersonalDataError("ユーザー辞書の補完検索条件が不正です")
        }
        guard settings.enabled, reading.utf16.count >= settings.minimumInputLength else { return [] }
        let pattern = reading + "%"
        var matches: [(index: Int, word: PersonalWord, length: Int)] = []
        for (index, word) in words.enumerated() {
            try word.validate()
            let matched = pattern.withCString { pattern in
                word.reading.withCString { sqlite3_strlike(pattern, $0, 0) == 0 }
            }
            if matched { matches.append((index, word, word.reading.unicodeScalars.count)) }
        }
        matches.sort {
            if $0.word.posScore != $1.word.posScore { return $0.word.posScore < $1.word.posScore }
            if $0.length != $1.length { return $0.length < $1.length }
            switch ($0.word.id, $1.word.id) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.index < $1.index
            }
        }
        return matches.prefix(settings.candidateLimit).map(\.word)
    }
}
