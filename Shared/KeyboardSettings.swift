import Foundation
import SumireCore

/// Both targets use the same suite only when the signed group container exists.
/// The extension reads settings; basic input never requires a shared write.
enum KeyboardSettings {
    static let groupIdentifier = "group.com.kazumaproject.sumire.ios"
    static var sharedDefaults: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) != nil else {
            return nil
        }
        return UserDefaults(suiteName: groupIdentifier)
    }
    static let appDefaults: UserDefaults = {
        guard let shared = sharedDefaults else { return .standard }
        migrateSettings(from: .standard, to: shared)
        return shared
    }()

    /// Unlike appDefaults, this never runs the containing-app migration. Reading
    /// the shared container is allowed when the user keeps open access disabled.
    static func extensionAccess(hasFullAccess: Bool) -> KeyboardSettingsAccess {
        KeyboardSettingsAccess(shared: sharedDefaults, local: .standard, allowSharedWrites: hasFullAccess)
    }

    static func migrateSettings(from source: UserDefaults, to shared: UserDefaults) {
        // Run once: a later restore may deliberately remove an override in the shared suite.
        let migrationKey = "internal.appGroupSettingsMigrated.v1"
        guard !shared.bool(forKey: migrationKey) else { return }
        // Preserve the existing diagnostic app's setting on first group-enabled launch.
        let keys = ["clipboardAutomaticPreview", "candidateRowCount", "liveConversion", "omissionSearch", "bunsetsuSeparation", "categoryMask", DictionaryCategoryCatalog.selectionKey, "englishReadingEnabled", "customRomaji.library", "customKeyboard.library", "learningEnabled", "learnFirstCandidate", "learnMixedSymbolsAndNumbers", "sumire.keyArrangement", SumireModePreferences.englishQWERTYKey, "sumire.specialKeyActions", "keyboard.selection", "keyboard.lastUsed", KeyboardToolbarPreferences.storageKey, PhysicalKeyboardShortcutStore.storageKey, "editing.deleteBoundarySymbols", "input.touchFeedback"] +
            source.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("appearance.") || $0.hasPrefix("keyboardSize.") || $0.hasPrefix("theme.") || $0.hasPrefix("qwerty.") || $0.hasPrefix("symbol.") || $0.hasPrefix("clipboard.")
            }
        for key in keys {
            if shared.object(forKey: key) == nil, let value = source.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
        shared.set(true, forKey: migrationKey)
    }

    static func candidateRowCount(from defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: "candidateRowCount") != nil else { return 1 }
        return min(3, max(1, defaults.integer(forKey: "candidateRowCount")))
    }
}
