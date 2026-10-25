import Foundation

/// The reference ToggleKatakana action cycles full-width katakana, half-width
/// katakana, then hiragana. Keep non-kana characters (including full-width
/// Latin text and emoji) intact when changing kana width.
public struct SumireKatakanaCycle {
    private var stage = 0
    public init() {}
    public mutating func reset() { stage = 0 }
    public mutating func next(_ reading: String) -> String {
        defer { stage = (stage + 1) % 3 }
        switch stage {
        case 0:
            return reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        case 1:
            return reading.map { character in
                let text = String(character)
                guard text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) else { return text }
                let katakana = text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text
                return katakana.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? katakana
            }.joined()
        default:
            let fullWidth = reading.map { character in
                let text = String(character)
                guard text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) else { return text }
                return text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
            }.joined()
            return fullWidth.applyingTransform(.hiraganaToKatakana, reverse: true) ?? fullWidth
        }
    }
}

/// The Android special-key editor exposes these five logical directions.
/// Its UP_RIGHT[_FAR] and UP_LEFT[_FAR] slots resolve to right and left.
/// Long press is an additional iOS binding; holding a flick may still repeat
/// that flick's resolved action without selecting the long-press binding.
public enum SumireSpecialKeyGesture: String, Codable, CaseIterable {
    case tap, up, right, down, left, longPress
    public var title: String {
        switch self {
        case .tap: return "タップ"
        case .up: return "上フリック"
        case .right: return "右フリック"
        case .down: return "下フリック"
        case .left: return "左フリック"
        case .longPress: return "長押し"
        }
    }
}

public enum SumireSpecialKeyID: String, Codable, CaseIterable {
    case paste = "paste_key", cursorLeft = "cursor_left_key", cursorRight = "cursor_right_key"
    case changeInputMode = "change_input_mode_key", keyboardSwitch = "switch_next_ime"
    case delete = "delete_key", spaceConvert = "space_convert_key", enter = "enter_key"
    case numberMode = "switch_to_number_key", englishMode = "switch_to_english_key", kanaMode = "switch_to_kana_key"
    case katakanaToggle = "katakana_toggle_key", colon = "colon_key", hyphen = "hyphen_key"

    /// Resolve the existing iOS layout IDs without changing their placements.
    public static func resolve(_ id: String, arrangement: SumireKeyArrangement, mode: TenKeyMode) -> Self? {
        if id == "number_mode", arrangement == .cursor, mode == .japanese { return .katakanaToggle }
        switch id {
        case "number_mode": return .numberMode
        case "english_mode": return .englishMode
        case "kana_mode": return .kanaMode
        default: return Self(rawValue: id)
        }
    }
    public var title: String {
        switch self {
        case .paste: return "貼り付け"
        case .cursorLeft: return "左カーソル"
        case .cursorRight: return "右カーソル"
        case .changeInputMode: return "入力モード切り替え"
        case .keyboardSwitch: return "キーボード切り替え"
        case .delete: return "削除"
        case .spaceConvert: return "空白・変換"
        case .enter: return "改行・確定"
        case .numberMode: return "数字モード"
        case .englishMode: return "英語モード"
        case .kanaMode: return "かなモード"
        case .katakanaToggle: return "数字・カタカナ切り替え"
        case .colon: return ":"
        case .hyphen: return "-"
        }
    }
}

/// Semantic actions only. The UIKit host implements document operations; this
/// model never substitutes another operation for an unavailable host action.
public enum SumireSpecialKeyAction: String, Codable, CaseIterable {
    case doNothing = "none"
    case deleteBackward, deleteUntilBoundary, deleteAfterCursorUntilBoundary, undoDelete
    case cursorLeft, cursorRight, cursorUp, cursorDown
    case paste, copy, cut, selectAll, space, convert, enter, confirm
    case nextKeyboard, keyboardMenu, changeInputMode, switchKana, switchEnglish, switchNumber
    case toggleKatakana, toggleDakuten, openSymbols, insertColon, insertHyphen
    public var title: String {
        switch self {
        case .doNothing: return "何もしない"
        case .deleteBackward: return "1文字削除"
        case .deleteUntilBoundary: return "未確定文字を全削除／区切りまで前方削除"
        case .deleteAfterCursorUntilBoundary: return "カーソル後を区切りまで削除"
        case .undoDelete: return "直前の削除を戻す"
        case .cursorLeft: return "カーソルを左へ"
        case .cursorRight: return "カーソルを右へ"
        case .cursorUp: return "カーソルを上へ"
        case .cursorDown: return "カーソルを下へ"
        case .paste: return "貼り付け"
        case .copy: return "コピー"
        case .cut: return "切り取り"
        case .selectAll: return "すべて選択"
        case .space: return "空白"
        case .convert: return "変換・次の候補"
        case .enter: return "改行・入力先の実行"
        case .confirm: return "未確定文字を確定"
        case .nextKeyboard: return "次のキーボード"
        case .keyboardMenu: return "キーボード選択メニュー"
        case .changeInputMode: return "入力モードを順送り"
        case .switchKana: return "かなモードに切り替え"
        case .switchEnglish: return "英語モードに切り替え"
        case .switchNumber: return "数字モードに切り替え"
        case .toggleKatakana: return "未確定文字をカタカナ切り替え"
        case .toggleDakuten: return "小文字・濁点・半濁点を切り替え"
        case .openSymbols: return "絵文字・顔文字・記号を開く"
        case .insertColon: return ": を入力"
        case .insertHyphen: return "- を入力"
        }
    }
    public var isRepeatable: Bool {
        switch self {
        case .deleteBackward, .cursorLeft, .cursorRight, .cursorUp, .cursorDown: return true
        default: return false
        }
    }

    /// Shared by settings and execution. Keep unavailable persisted actions
    /// representable; do not silently substitute another operation.
    public func unavailabilityReason(for key: SumireSpecialKeyID, gesture: SumireSpecialKeyGesture) -> String? {
        if key == .keyboardSwitch {
            if gesture == .longPress {
                return self == .keyboardMenu ? nil : "キーボード切替キーの長押しは配列選択メニューを使用します。別の長押し操作は現在未対応です"
            }
            if gesture != .tap && self != .doNothing { return "キーボード切替キーの方向別操作は現在未対応です" }
        }
        switch self {
        case .selectAll: return "iOS のキーボード拡張には、入力先の全文を選択する公開 API がありません"
        case .cursorUp, .cursorDown: return "iOS のキーボード拡張には、入力先の表示行を上下に移動する公開 API がありません。現在未対応です"
        case .copy, .cut: return "入力先の選択文字をコピー・切り取りする操作は現在未対応です"
        case .keyboardMenu: return key == .keyboardSwitch && gesture == .longPress ? nil : "配列選択メニューはキーボード切替キーの長押しから開きます"
        default: return nil
        }
    }
}

/// Sparse overrides, partitioned like the reference editor by layout, input
/// mode, key ID and direction. An absent override follows the dynamic default;
/// `.doNothing` explicitly disables that gesture.
public struct SumireSpecialKeySettings: Codable, Equatable {
    public static let storageKey = "sumire.specialKeyActions"
    public static let maximumBytes = 128 * 1024
    public struct Override: Codable, Equatable {
        public let arrangement: String
        public let inputMode: Int
        public let key: SumireSpecialKeyID
        public let gesture: SumireSpecialKeyGesture
        public let action: SumireSpecialKeyAction
    }
    public private(set) var version = 1
    public private(set) var overrides: [Override] = []
    public init() {}

    public static func keys(arrangement: SumireKeyArrangement, mode: TenKeyMode) -> [SumireSpecialKeyID] {
        let left: [SumireSpecialKeyID]
        switch arrangement {
        case .toggle: left = [.paste, .cursorLeft, .changeInputMode, .keyboardSwitch]
        case .flick: left = [.numberMode, .englishMode, .kanaMode, .keyboardSwitch]
        case .cursor:
            if mode == .number { left = [.keyboardSwitch, .colon, .kanaMode, .englishMode] }
            else if mode == .english { left = [.keyboardSwitch, .cursorLeft, .numberMode, .kanaMode] }
            else { left = [.keyboardSwitch, .cursorLeft, .katakanaToggle, .englishMode] }
        }
        return left + [.delete, .spaceConvert] + (arrangement == .toggle ? [] : [mode == .number && arrangement == .cursor ? .hyphen : .cursorRight]) + [.enter]
    }

    /// Defaults from JapaneseKeyboard dev 9506a0b KeyboardDefaultLayouts,
    /// SumireSpecialKeyDefaultActionResolver and DeleteKeyFlickSettings.
    /// hasComposition selects the existing dynamic space/enter/katakana state.
    public static func defaultAction(for key: SumireSpecialKeyID, gesture: SumireSpecialKeyGesture,
                                     arrangement: SumireKeyArrangement, mode: TenKeyMode,
                                     hasComposition: Bool = false) -> SumireSpecialKeyAction {
        if gesture == .longPress {
            if key == .keyboardSwitch { return .keyboardMenu }
            let tap = defaultAction(for: key, gesture: .tap, arrangement: arrangement, mode: mode, hasComposition: hasComposition)
            return tap.isRepeatable ? tap : .doNothing
        }
        switch key {
        case .delete:
            // The reference enables only left-delete-until-symbol by default.
            if gesture == .tap { return .deleteBackward }
            return gesture == .left ? .deleteUntilBoundary : .doNothing
        case .cursorLeft, .cursorRight:
            if gesture == .tap { return key == .cursorLeft ? .cursorLeft : .cursorRight }
            if gesture == .right, key == .cursorLeft { return .cursorRight }
            if gesture == .left, key == .cursorRight { return .cursorLeft }
            // Japanese toggle exposes only tap-left / right-flick-right.
            // English toggle and effective layouts expose the four directions.
            if arrangement == .cursor || (arrangement == .toggle && mode != .japanese) {
                switch gesture {
                case .left: return .cursorLeft
                case .right: return .cursorRight
                case .up: return .cursorUp
                case .down: return .cursorDown
                default: break
                }
            }
            return .doNothing
        case .paste:
            if gesture == .tap { return .paste }
            if gesture == .up { return .selectAll }
            return gesture == .right ? .copy : .doNothing
        case .spaceConvert:
            if gesture == .tap { return hasComposition ? .convert : .space }
            // The conversion state has only a tap mapping in the reference.
            return gesture == .left && !hasComposition ? .space : .doNothing
        default:
            guard gesture == .tap else { return .doNothing }
            switch key {
            case .enter: return hasComposition ? .confirm : .enter
            case .keyboardSwitch: return .nextKeyboard
            case .changeInputMode: return .changeInputMode
            case .numberMode: return .switchNumber
            case .englishMode: return .switchEnglish
            case .kanaMode: return .switchKana
            case .katakanaToggle: return hasComposition ? .toggleKatakana : .switchNumber
            case .colon: return .insertColon
            case .hyphen: return .insertHyphen
            default: return .doNothing
            }
        }
    }

    public func assignedAction(for key: SumireSpecialKeyID, gesture: SumireSpecialKeyGesture,
                         arrangement: SumireKeyArrangement, mode: TenKeyMode) -> SumireSpecialKeyAction? {
        overrides.first { $0.arrangement == arrangement.rawValue && $0.inputMode == mode.rawValue && $0.key == key && $0.gesture == gesture }?.action
    }
    public func action(for key: SumireSpecialKeyID, gesture: SumireSpecialKeyGesture,
                       arrangement: SumireKeyArrangement, mode: TenKeyMode,
                       hasComposition: Bool = false) -> SumireSpecialKeyAction {
        if let assigned = assignedAction(for: key, gesture: gesture, arrangement: arrangement, mode: mode) { return assigned }
        if gesture == .longPress, key != .keyboardSwitch {
            let tap = action(for: key, gesture: .tap, arrangement: arrangement, mode: mode, hasComposition: hasComposition)
            return tap.isRepeatable ? tap : .doNothing
        }
        return Self.defaultAction(for: key, gesture: gesture, arrangement: arrangement, mode: mode, hasComposition: hasComposition)
    }
    public mutating func set(_ action: SumireSpecialKeyAction?, for key: SumireSpecialKeyID,
                             gesture: SumireSpecialKeyGesture, arrangement: SumireKeyArrangement, mode: TenKeyMode) throws {
        var next = self
        next.overrides.removeAll { $0.arrangement == arrangement.rawValue && $0.inputMode == mode.rawValue && $0.key == key && $0.gesture == gesture }
        if let action { next.overrides.append(Override(arrangement: arrangement.rawValue, inputMode: mode.rawValue, key: key, gesture: gesture, action: action)) }
        try next.validate()
        self = next
    }
    public mutating func reset(key: SumireSpecialKeyID, arrangement: SumireKeyArrangement, mode: TenKeyMode) {
        overrides.removeAll { $0.arrangement == arrangement.rawValue && $0.inputMode == mode.rawValue && $0.key == key }
    }
    public func validate() throws {
        guard version == 1, overrides.count <= SumireKeyArrangement.allCases.count * TenKeyMode.allCases.count * SumireSpecialKeyID.allCases.count * SumireSpecialKeyGesture.allCases.count else {
            throw PersonalDataError("未対応または大きすぎる特殊キー設定です")
        }
        var seen = Set<String>()
        for entry in overrides {
            guard let arrangement = SumireKeyArrangement(rawValue: entry.arrangement), let mode = TenKeyMode(rawValue: entry.inputMode),
                  Self.keys(arrangement: arrangement, mode: mode).contains(entry.key),
                  seen.insert("\(entry.arrangement)/\(entry.inputMode)/\(entry.key.rawValue)/\(entry.gesture.rawValue)").inserted else {
                throw PersonalDataError("特殊キー設定に不正または重複した項目があります")
            }
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw PersonalDataError("特殊キー設定が大きすぎます") }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PersonalDataError("特殊キー設定が大きすぎます") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    public static func load(defaults: UserDefaults) throws -> Self {
        guard let raw = defaults.object(forKey: storageKey) else { return Self() }
        guard let data = raw as? Data else { throw PersonalDataError("特殊キー設定の保存形式が不正です") }
        return try decode(data)
    }
    public func save(defaults: UserDefaults) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
