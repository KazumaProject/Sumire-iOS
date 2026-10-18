import Foundation

/// A containing-app deletion request applied to the extension's private copy.
/// The acknowledgement always belongs to the private preferences domain.
public struct LocalDataReset {
    public enum Store: String { case learning, clipboard }
    public let store: Store
    public let url: URL
    private let token: String
    private let defaults: UserDefaults
    private var acknowledgementKey: String { "internal.appliedReset." + store.rawValue }

    public init?(store: Store, url: URL, sharedDefaults: UserDefaults, localDefaults: UserDefaults) {
        guard let token = sharedDefaults.string(forKey: store.rawValue + ".resetToken"),
              UUID(uuidString: token) != nil,
              localDefaults.string(forKey: "internal.appliedReset." + store.rawValue) != token else { return nil }
        self.store = store; self.url = url; self.token = token; defaults = localDefaults
    }

    /// Call on the database owner's serial queue after releasing its open handle.
    /// Failed deletion is not acknowledged, so a later appearance retries it.
    public func apply() throws {
        try apply { url in
            if FileManager.default.fileExists(atPath: url.path) {
                switch store {
                case .learning: try LearningStore(url: url).clear()
                case .clipboard: try ClipboardHistoryStore(url: url).clear()
                }
            }
        }
    }
    func apply(clear: (URL) throws -> Void) throws {
        guard defaults.string(forKey: acknowledgementKey) != token else { return }
        try clear(url)
        defaults.set(token, forKey: acknowledgementKey)
    }
}
