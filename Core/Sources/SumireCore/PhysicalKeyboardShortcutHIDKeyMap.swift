/// Maps USB HID Keyboard/Keypad page usages to Android `KeyEvent` key codes.
///
/// `UIKey.keyCode.rawValue` uses the HID usage identity for physical keyboard
/// keys. Android shortcut rows store `KeyEvent.keyCode`, so the two integer
/// domains must not be compared directly. This table deliberately returns nil
/// for usages whose Android mapping is not represented here; callers must not
/// fall back to interpreting the event's input text as a key identity.
public enum PhysicalKeyboardShortcutHIDKeyMap {
  /// Returns the Android-compatible key code for a keyboard-page HID usage.
  /// Modifier usages are not returned as key codes; UIKit reports those through
  /// modifier flags and the runtime adapter must pass them separately.
  public static func androidKeyCode(for usage: Int) -> Int? {
    switch usage {
    case 0x04...0x1D:  // A...Z
      return 29 + usage - 0x04
    case 0x1E...0x26:  // 1...9
      return 8 + usage - 0x1E
    case 0x27:  // 0
      return 7
    case 0x28:  // Return
      return 66
    case 0x29:  // Escape
      return 111
    case 0x2A:  // Backspace
      return 67
    case 0x2B:  // Tab
      return 61
    case 0x2C:  // Space
      return 62
    case 0x2D:  // - and _
      return 69
    case 0x2E:  // = and +
      return 70
    case 0x2F:  // [ and {
      return 71
    case 0x30:  // ] and }
      return 72
    case 0x31:  // \ and |
      return 73
    case 0x33:  // ; and :
      return 74
    case 0x34:  // ' and "
      return 75
    case 0x35:  // ` and ~
      return 68
    case 0x36:  // , and <
      return 55
    case 0x37:  // . and >
      return 56
    case 0x38:  // / and ?
      return 76
    case 0x3A...0x45:  // F1...F12
      return 131 + usage - 0x3A
    case 0x4C:  // Delete Forward
      return 112
    case 0x4F:  // Right Arrow
      return 22
    case 0x50:  // Left Arrow
      return 21
    case 0x51:  // Down Arrow
      return 20
    case 0x52:  // Up Arrow
      return 19
    case 0x87:  // International1 (Ro)
      return 217
    case 0x88:  // International2 (Katakana/Hiragana)
      return 215
    case 0x89:  // International3 (Yen)
      return 216
    case 0x8A:  // International4 (Henkan)
      return 214
    case 0x8B:  // International5 (Muhenkan)
      return 213
    case 0x90:  // LANG1 (Kana switch on Japanese Apple keyboards)
      return 218
    case 0x91:  // LANG2 (Alphanumeric switch on Japanese Apple keyboards)
      return 212
    case 0x94:  // Lang5 (Zenkaku/Hankaku)
      return 211
    default:
      return nil
    }
  }
}
