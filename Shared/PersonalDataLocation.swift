import Foundation
import SumireCore

enum PersonalDataLocation {
    /// Loading immutable personal dictionary generations performs no writes,
    /// including when falling back to the previous valid generation.
    static func readableStore() -> PersonalLexiconStore { store(allowShared: true) }
    static func clipboardURL(allowShared: Bool) -> URL {
        store(allowShared: allowShared).directory.deletingLastPathComponent().appendingPathComponent("clipboard.sqlite")
    }
    static func learningURL(allowShared: Bool) -> URL {
        store(allowShared: allowShared).directory.deletingLastPathComponent().appendingPathComponent("learning.sqlite")
    }
    static func store(allowShared: Bool) -> PersonalLexiconStore {
        let shared = allowShared ? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.groupIdentifier) : nil
        let root = shared ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PersonalLexiconStore(directory: root.appendingPathComponent("Sumire/Personal", isDirectory: true))
    }
}
