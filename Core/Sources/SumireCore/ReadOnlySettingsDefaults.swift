import Foundation

/// A value snapshot for existing defaults-based readers. No registration domain
/// is used: Foundation's registration domain is shared by other defaults objects
/// in the process. All supported reads are explicit and all writes are rejected.
final class ReadOnlySettingsDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let valuesLock = NSLock()

    init() {
        super.init(suiteName: "Sumire.ReadOnlySettings." + UUID().uuidString)!
    }
    func replace(with values: [String: Any]) {
        valuesLock.lock(); defer { valuesLock.unlock() }
        self.values = values
    }
    override func object(forKey key: String) -> Any? {
        valuesLock.lock(); defer { valuesLock.unlock() }
        return values[key]
    }
    override func dictionaryRepresentation() -> [String: Any] {
        valuesLock.lock(); defer { valuesLock.unlock() }
        return values
    }
    override func string(forKey key: String) -> String? {
        let value = object(forKey: key)
        return (value as? String) ?? (value as? NSNumber)?.stringValue
    }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        return (value as? NSNumber)?.intValue ?? (value as? NSString)?.integerValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        let value = object(forKey: key)
        return (value as? NSNumber)?.doubleValue ?? (value as? NSString)?.doubleValue ?? 0
    }
    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }
    override func bool(forKey key: String) -> Bool {
        let value = object(forKey: key)
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func value(forKey key: String) -> Any? { object(forKey: key) }

    // This object is only a reader. Runtime changes use a separate writable
    // defaults object selected by KeyboardSettingsAccess, never this snapshot.
    override func set(_ value: Any?, forKey key: String) {}
    override func set(_ value: Int, forKey key: String) {}
    override func set(_ value: Float, forKey key: String) {}
    override func set(_ value: Double, forKey key: String) {}
    override func set(_ value: Bool, forKey key: String) {}
    override func set(_ url: URL?, forKey key: String) {}
    override func setValue(_ value: Any?, forKey key: String) {}
    override func removeObject(forKey key: String) {}
    override func register(defaults registrationDictionary: [String: Any]) {}
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {}
    override func removePersistentDomain(forName domainName: String) {}
    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {}
    override func removeVolatileDomain(forName domainName: String) {}
    override func synchronize() -> Bool { true }
}
