import Foundation

/// Semantic decoding only. UIKit executors must explicitly handle each case;
/// unsupported values must be displayed to the user, never inserted as text.
public enum CustomKeyAction: Codable, Equatable {
    case text(String)
    case inputText(String)
    case command(Command)
    case switchLayout(String)
    case unsupported(raw: String, reason: String)

    public enum Command: String, Codable {
        case doNothing = "DoNothing", delete = "Delete", backspace = "Backspace"
        case space = "Space", enter = "Enter", newLine = "NewLine", confirm = "Confirm", convert = "Convert"
        case paste = "Paste", cursorLeft = "MoveCursorLeft", nextKeyboard = "SwitchToNextIme"
        case modifier = "小゛゜", changeMode = "ChangeInputMode", moveCustomKeyboardTab = "MoveCustomKeyboardTab"
        case forceNewLine = "ForceNewLine", halfSpace = "ForceHalfWidthSpace", fullSpace = "ForceFullWidthSpace"
        case commitAndSpace = "CommitAndInsertSpace"
    }
    public static func tap(_ raw: String, targets: CustomLayoutTargets) -> Self {
        if raw.hasPrefix("Text:") { return .text(String(raw.dropFirst(5))) }
        if raw.hasPrefix("InputText:") { return .inputText(String(raw.dropFirst(10))) }
        if raw.hasPrefix("MoveToCustomKeyboard:") { return targets.resolve(String(raw.dropFirst(21)), raw: raw) }
        if let command = Command(rawValue: raw) { return .command(command) }
        return .unsupported(raw: raw, reason: "この操作はiOS側で未対応です")
    }
    public static func flick(type: String, value: String?, targets: CustomLayoutTargets) -> Self {
        if type == "INPUT_TEXT" { return .text(value ?? "") }
        if type == "MoveToCustomKeyboard" { return targets.resolve(value ?? "", raw: type + ":" + (value ?? "")) }
        let aliases = ["DELETE": "Delete", "BACKSPACE": "Backspace", "SPACE": "Space",
                       "NEW_LINE": "NewLine", "ENTER": "Enter", "CONFIRM": "Confirm", "CONVERT": "Convert",
                       "PASTE": "Paste", "MOVE_CURSOR_LEFT": "MoveCursorLeft", "SWITCH_TO_NEXT_IME": "SwitchToNextIme",
                       "TOGGLE_DAKUTEN": "小゛゜", "CHANGE_INPUT_MODE": "ChangeInputMode"]
        if let command = Command(rawValue: aliases[type] ?? type) { return .command(command) }
        return .unsupported(raw: type + ":" + (value ?? ""), reason: "このフリック操作はiOS側で未対応です")
    }
}

public struct CustomLayoutTargets {
    private let stableIDs: Set<String>
    private let oldIDs: [Int64: [String]]
    public init(layouts: [ImportedCustomLayout]) {
        stableIDs = Set(layouts.map(\.id))
        oldIDs = Dictionary(grouping: layouts.filter { ($0.originalLayoutID ?? 0) > 0 }, by: { $0.originalLayoutID! })
            .mapValues { $0.map(\.id) }
    }
    fileprivate func resolve(_ target: String, raw: String) -> CustomKeyAction {
        // Android legacy numeric references refer to database IDs, not stable IDs.
        if let oldID = Int64(target) {
            if let matches = oldIDs[oldID], matches.count == 1 { return .switchLayout(matches[0]) }
        } else if !target.isEmpty, stableIDs.contains(target) { return .switchLayout(target) }
        return .unsupported(raw: raw, reason: "切替先の配列が見つからないか、識別子が重複しています")
    }
}

public struct CustomLayoutActionReview {
    public struct Item: Equatable {
        public let layoutID: String
        public let keyID: String
        public let location: String
        public let action: CustomKeyAction
    }
    public let items: [Item]
    public var unsupported: [Item] {
        items.filter { if case .unsupported = $0.action { return true }; return false }
    }
    public init(layouts: [ImportedCustomLayout]) {
        let targets = CustomLayoutTargets(layouts: layouts)
        var items: [Item] = []
        for layout in layouts {
            for key in layout.placements where !key.isSpacer {
                let definition = key.source["key"]
                for field in ["action", "doubleTapAction"] {
                    if let raw = definition?[field]?.string {
                        let action: CustomKeyAction
                        if field == "doubleTapAction" {
                            // Disabled/ordinary-key bindings are inert, as in Android imports.
                            guard let binding = CustomDoubleTapBinding.effective(
                                definition: definition, normalAction: .tap(definition?["action"]?.string ?? "", targets: targets),
                                targets: targets) else { continue }
                            action = binding.action
                        } else {
                            action = .tap(raw, targets: targets)
                        }
                        items.append(Item(layoutID: layout.id, keyID: key.id, location: field,
                                          action: action))
                    }
                }
                for field in ["flicks", "circularFlicks"] {
                    for (index, mapping) in (key.source[field]?.array ?? []).enumerated() {
                        items.append(Item(layoutID: layout.id, keyID: key.id, location: "\(field)[\(index)]",
                                          action: .flick(type: mapping["actionType"]?.string ?? "INPUT_TEXT",
                                                         value: mapping["actionValue"]?.string, targets: targets)))
                    }
                }
                for field in ["longPressFlicks", "twoStepFlicks", "twoStepLongPressFlicks"] {
                    for (index, mapping) in (key.source[field]?.array ?? []).enumerated() {
                        let action: CustomKeyAction
                        if let output = mapping["output"]?.string {
                            action = .text(output)
                        } else {
                            action = .unsupported(raw: "\(field)[\(index)]", reason: "出力文字がありません")
                        }
                        items.append(Item(layoutID: layout.id, keyID: key.id, location: "\(field)[\(index)]",
                                          action: action))
                    }
                }
                if let type = definition?["keyType"]?.string,
                   !["NORMAL", "STANDARD_FLICK", "PETAL_FLICK", "CENTER_GUIDE_FLICK", "CROSS_FLICK",
                     "CIRCULAR_FLICK", "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK", "FLICK_LONG_PRESS"].contains(type) {
                    items.append(Item(layoutID: layout.id, keyID: key.id, location: "key.keyType",
                                      action: .unsupported(raw: type, reason: "このカスタム入力方式はiOS側で未対応です")))
                }
            }
        }
        self.items = items
    }
}
