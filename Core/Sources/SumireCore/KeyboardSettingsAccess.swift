import Foundation
import CryptoKit

/// Shared configuration is readable without open access. Runtime changes are
/// written to the extension's private store until shared writes are permitted.
/// Call `didWrite` after changing a runtime setting through `writeDefaults`.
public final class KeyboardSettingsAccess {
    public let readDefaults: UserDefaults
    public let writeDefaults: UserDefaults
    public let readsSharedSettings: Bool
    public let writesSharedSettings: Bool
    private let snapshot = ReadOnlySettingsDefaults()
    private let shared: UserDefaults?
    private let local: UserDefaults
    private let lock = NSRecursiveLock()
    private static let overlayKey = "internal.extensionSettingsOverlay.v1"
    private static let runtimeKeys: Set<String> = [
        "keyboard.lastUsed", KeyboardSizingStore.key(.portrait), KeyboardSizingStore.key(.landscape),
        SymbolKeyboardHistory.storageKey, EmojiSkinTone.settingsKey, ClipboardHistorySettings.enabledKey
    ]

    public init(shared: UserDefaults?, local: UserDefaults, allowSharedWrites: Bool) {
        self.shared = shared; self.local = local
        readsSharedSettings = shared != nil
        writesSharedSettings = allowSharedWrites && shared != nil
        writeDefaults = writesSharedSettings ? shared! : local
        readDefaults = snapshot
        reload()
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        var values = (shared ?? local).dictionaryRepresentation()
        guard let shared else { snapshot.replace(with: values); return }
        let stored = local.dictionary(forKey: Self.overlayKey) ?? [:]
        var bases: [String: Data] = [:]
        for key in Self.runtimeKeys {
            let value = local.object(forKey: key)
            let base = stored[key] as? Data
            let source = shared.object(forKey: key)
            // Legacy private runtime state is adopted only when the containing
            // app has no value. Other local preferences never mask app settings.
            let adopted = stored[key] == nil && source == nil && value != nil
            guard (adopted || base == Self.fingerprint(source)), Self.valid(value, key: key) else {
                if stored[key] != nil { local.removeObject(forKey: key) }
                continue
            }
            if writesSharedSettings {
                if let value { shared.set(value, forKey: key) }
                else { shared.removeObject(forKey: key) }
                local.removeObject(forKey: key)
            } else {
                bases[key] = base ?? Self.fingerprint(source)
            }
            if let value { values[key] = value }
            else { values.removeValue(forKey: key) }
        }
        // Store only bounded fingerprints in the private container. A changed
        // app value invalidates its local override on the next appearance.
        if bases.isEmpty { local.removeObject(forKey: Self.overlayKey) }
        else { local.set(bases, forKey: Self.overlayKey) }
        snapshot.replace(with: values)
    }

    public func didWrite(_ keys: [String]) {
        lock.lock(); defer { lock.unlock() }
        if let shared, !writesSharedSettings {
            var bases = (local.dictionary(forKey: Self.overlayKey) ?? [:]).compactMapValues { $0 as? Data }
            for key in keys where Self.runtimeKeys.contains(key) {
                bases[key] = Self.fingerprint(shared.object(forKey: key))
            }
            bases = bases.filter { Self.runtimeKeys.contains($0.key) }
            local.set(bases, forKey: Self.overlayKey)
        }
        reload()
    }

    private static func fingerprint(_ value: Any?) -> Data {
        let bytes: Data
        if let value, let encoded = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) {
            bytes = Data([1]) + encoded
        } else { bytes = Data([0]) }
        return Data(SHA256.hash(data: bytes))
    }

    private static func valid(_ value: Any?, key: String) -> Bool {
        guard let value else { return true } // An explicit private reset.
        switch key {
        case "keyboard.lastUsed": return (value as? String).map { $0.utf8.count <= 256 } ?? false
        case KeyboardSizingStore.key(.portrait), KeyboardSizingStore.key(.landscape):
            guard let data = value as? Data, data.count <= 1024,
                  let size = try? JSONDecoder().decode(KeyboardSize.self, from: data) else { return false }
            return size.height.isFinite && size.width.isFinite && size.alignment.isFinite
        case SymbolKeyboardHistory.storageKey:
            guard let data = value as? Data, data.count <= 1_000_000 else { return false }
            return (try? JSONDecoder().decode([String: [String]].self, from: data)) != nil
        case EmojiSkinTone.settingsKey: return (value as? String).flatMap(EmojiSkinTone.init(rawValue:)) != nil
        case ClipboardHistorySettings.enabledKey: return value is NSNumber
        default: return false
        }
    }
}
