import Foundation

/// Actions that the iOS keyboard currently exposes in its candidate toolbar.
public enum KeyboardToolbarAction: String, CaseIterable, Identifiable, Hashable {
    case resize
    case emoji
    case paste
    case template
    case textMacros = "text_macro"
    case clipboard
    case selectDate = "select_date"
    case keyboardPicker = "keyboard_picker"
    case liveConversionToggle = "live_conversion_toggle"
    case learningPause = "learning_pause"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .emoji: return "絵文字・記号"
        case .paste: return "貼り付け"
        case .template: return "定型文"
        case .textMacros: return "定型マクロ"
        case .clipboard: return "クリップボード履歴"
        case .resize: return "キーボードサイズ変更"
        case .selectDate: return "日付"
        case .keyboardPicker: return "キーボード切替"
        case .liveConversionToggle: return "ライブ変換"
        case .learningPause: return "学習一時停止"
        }
    }

    public var symbolName: String {
        switch self {
        case .emoji: return "face.smiling"
        case .paste: return "clipboard"
        case .template: return "text.quote"
        case .textMacros: return "text.badge.plus"
        case .clipboard: return "doc.on.clipboard"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .selectDate: return "calendar"
        case .keyboardPicker: return "globe"
        case .liveConversionToggle: return "textformat"
        case .learningPause: return "pause.fill"
        }
    }
}

/// Exact Android toolbar IDs whose behavior has a direct iOS keyboard action.
/// IDs without an equivalent remain visible to the importer as unsupported;
/// they are never silently redirected to a different control.
public struct AndroidToolbarShortcutImport: Equatable {
    public let actions: [KeyboardToolbarAction]
    public let unsupportedIDs: [String]

    public init(shortcutIDs: [String]) {
        let mappings: [String: KeyboardToolbarAction] = [
            "emoji": .emoji,
            "paste": .paste,
            "template": .template,
            "text_macro": .textMacros,
            "clip_board": .clipboard,
            "select_date": .selectDate,
            "keyboard_picker": .keyboardPicker,
            "live_conversion_toggle": .liveConversionToggle,
            "learning_pause": .learningPause
        ]
        var seenIDs = Set<String>()
        var seenActions = Set<KeyboardToolbarAction>()
        var actions: [KeyboardToolbarAction] = []
        var unsupportedIDs: [String] = []
        for id in shortcutIDs where seenIDs.insert(id).inserted {
            guard let action = mappings[id] else {
                unsupportedIDs.append(id)
                continue
            }
            if seenActions.insert(action).inserted { actions.append(action) }
        }
        self.actions = actions
        self.unsupportedIDs = unsupportedIDs
    }
}

/// Ordered, user-selected iOS toolbar actions stored in app-group defaults.
public enum KeyboardToolbarPreferences {
    public static let storageKey = "keyboard.toolbar.actions"

    /// Preserve the existing iOS toolbar order for users who have not changed it.
    public static let defaultActions: [KeyboardToolbarAction] = [.resize, .emoji, .paste]

    public static func normalize(_ rawValues: [String]) -> [KeyboardToolbarAction] {
        var seen = Set<KeyboardToolbarAction>()
        let actions = rawValues.compactMap { value -> KeyboardToolbarAction? in
            // `symbols` was the iOS-only name used before the Android shortcut
            // IDs were audited. Canonicalize it to Android's `emoji` action.
            KeyboardToolbarAction(rawValue: value == "symbols" ? "emoji" : value)
        }.filter { seen.insert($0).inserted }
        return actions.isEmpty ? defaultActions : actions
    }

    public static func load(defaults: UserDefaults) -> [KeyboardToolbarAction] {
        guard let values = defaults.array(forKey: storageKey) as? [String] else { return defaultActions }
        return normalize(values)
    }

    @discardableResult
    public static func save(_ actions: [KeyboardToolbarAction], defaults: UserDefaults) -> [KeyboardToolbarAction] {
        let normalized = normalize(actions.map(\.rawValue))
        defaults.set(normalized.map(\.rawValue), forKey: storageKey)
        return normalized
    }
}
