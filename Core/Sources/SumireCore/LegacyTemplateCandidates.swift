import Foundation

public enum LegacyTemplateSettings {
    public static let enabledKey = "legacyTemplateCandidatesEnabled"
    public static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
}

public enum LegacyTemplateCandidatePolicy {
    public static let maximumCandidates = 8

    /// df1 UserTemplateDao: exact BINARY reading, id DESC LIMIT 8;
    /// mapper then applies stable score ordering to that selected set.
    /// Portable nil IDs follow known IDs and preserve source order on a tie.
    public static func candidates(in templates: [PersonalWord], reading: String, enabled: Bool = true) throws -> [PersonalWord] {
        guard reading.utf16.count <= 8192, reading.utf8.count <= 32768,
              !reading.contains("\0"), templates.count <= 100000 else {
            throw PersonalDataError("定型文の候補検索条件が不正です")
        }
        guard enabled, !reading.isEmpty else { return [] }
        var matching: [(offset: Int, word: PersonalWord)] = []
        for (offset, word) in templates.enumerated() {
            try word.validate()
            if word.reading.utf8.elementsEqual(reading.utf8) { matching.append((offset, word)) }
        }
        matching.sort {
            switch ($0.word.id, $1.word.id) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.offset < $1.offset
            }
        }
        return matching.prefix(maximumCandidates).enumerated().sorted {
            $0.element.word.posScore == $1.element.word.posScore
                ? $0.offset < $1.offset : $0.element.word.posScore < $1.element.word.posScore
        }.map { $0.element.word }
    }
}
