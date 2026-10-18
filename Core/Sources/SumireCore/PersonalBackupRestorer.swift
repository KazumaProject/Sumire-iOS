import Foundation

/// Single app-writer recovery journal. Readers may observe individual stores switching
/// separately; this is restart recovery, not a transaction across SQLite and defaults.
public struct PersonalBackupRestorer {
    public let lexiconStore: PersonalLexiconStore
    public let defaults: UserDefaults
    public let learningURL: URL
    public let journalURL: URL
    public init(lexiconStore: PersonalLexiconStore, defaults: UserDefaults, learningURL: URL, journalURL: URL) {
        self.lexiconStore = lexiconStore; self.defaults = defaults
        self.learningURL = learningURL; self.journalURL = journalURL
    }
    public func restore(_ contents: PersonalBackup.Contents) throws {
        let data = try PersonalBackup.encode(contents)
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw PersonalDataError("前回の復元が未完了です。再起動して復元を再開してください")
        }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: journalURL, options: .atomic)
        try apply(contents)
    }
    @discardableResult public func recover() throws -> Bool {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        let contents = try PersonalBackup.readContents(journalURL)
        try apply(contents)
        return true
    }
    private func apply(_ contents: PersonalBackup.Contents) throws {
        try contents.validate()
        // Open before changing other stores, so unreadable learning data stops restoration.
        let learning = try contents.learning.map { _ in try LearningStore(url: learningURL) }
        try lexiconStore.save(contents.lexicon)
        try contents.settings?.restore(defaults: defaults)
        if contents.settings != nil, !defaults.synchronize() {
            throw PersonalDataError("設定を保存できません。復元内容を保持して再起動時に再試行します")
        }
        if let entries = contents.learning { try learning?.restore(entries) }
        try FileManager.default.removeItem(at: journalURL)
    }
}
