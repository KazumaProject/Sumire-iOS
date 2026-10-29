/// The selectable physical keys in Android's pinned shortcut editor.
///
/// `keyCode` values are Android `KeyEvent` constants. Labels and ordering match
/// `PhysicalKeyboardShortcutKey.entries`; HID event translation is handled by
/// `PhysicalKeyboardShortcutHIDKeyMap`.
public struct PhysicalKeyboardShortcutKey: CaseIterable, Equatable, Identifiable, Sendable {
  public let keyCode: Int
  public let label: String

  public var id: Int { keyCode }

  /// Shows Japanese labels used by Android's shortcut editor when the app's
  /// interface language is Japanese. Other languages retain the stable
  /// fallback labels stored in this platform-neutral catalog.
  public func displayLabel(languageCode: String?) -> String {
    let primaryLanguage = languageCode?
      .split(whereSeparator: { $0 == "-" || $0 == "_" })
      .first
      .map { String($0).lowercased() }
    guard primaryLanguage == "ja" else { return label }
    return Self.japaneseLabelsByKeyCode[keyCode] ?? label
  }

  private init(keyCode: Int, label: String) {
    self.keyCode = keyCode
    self.label = label
  }

  public static let allCases: [Self] = {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").enumerated().map {
      Self(keyCode: 29 + $0.offset, label: String($0.element))
    }
    let digits = Array("0123456789").enumerated().map {
      Self(keyCode: 7 + $0.offset, label: String($0.element))
    }
    let functionKeys = (1...12).map {
      Self(keyCode: 130 + $0, label: "F\($0)")
    }

    return letters + digits + functionKeys + [
      Self(keyCode: 62, label: "Space"),
      Self(keyCode: 66, label: "Enter"),
      Self(keyCode: 67, label: "Backspace"),
      Self(keyCode: 112, label: "Delete"),
      Self(keyCode: 111, label: "Escape"),
      Self(keyCode: 61, label: "Tab"),
      Self(keyCode: 21, label: "Left"),
      Self(keyCode: 22, label: "Right"),
      Self(keyCode: 19, label: "Up"),
      Self(keyCode: 20, label: "Down"),
      Self(keyCode: 214, label: "Henkan"),
      Self(keyCode: 213, label: "Muhenkan"),
      Self(keyCode: 211, label: "Zenkaku/Hankaku"),
      Self(keyCode: 212, label: "Eisu"),
      Self(keyCode: 215, label: "Katakana/Hiragana"),
      Self(keyCode: 218, label: "Kana"),
      Self(keyCode: 69, label: "Minus"),
      Self(keyCode: 70, label: "Equals"),
      Self(keyCode: 71, label: "Left bracket"),
      Self(keyCode: 72, label: "Right bracket"),
      Self(keyCode: 73, label: "Backslash"),
      Self(keyCode: 74, label: "Semicolon"),
      Self(keyCode: 75, label: "Apostrophe"),
      Self(keyCode: 55, label: "Comma"),
      Self(keyCode: 56, label: "Period"),
      Self(keyCode: 76, label: "Slash"),
      Self(keyCode: 68, label: "Grave"),
      Self(keyCode: 216, label: "Yen"),
      Self(keyCode: 217, label: "Ro"),
    ]
  }()

  public static func fromKeyCode(_ keyCode: Int) -> Self? {
    allCases.first { $0.keyCode == keyCode }
  }

  private static let japaneseLabelsByKeyCode: [Int: String] = [
    21: "左",
    22: "右",
    19: "上",
    20: "下",
    214: "変換",
    213: "無変換",
    211: "全角/半角",
    212: "英数",
    215: "カタカナ/ひらがな",
    218: "かな",
    69: "マイナス",
    70: "イコール",
    71: "左角括弧",
    72: "右角括弧",
    73: "バックスラッシュ",
    74: "セミコロン",
    75: "アポストロフィ",
    55: "カンマ",
    56: "ピリオド",
    76: "スラッシュ",
    68: "グレイヴ",
    216: "円記号",
    217: "ろ",
  ]
}
