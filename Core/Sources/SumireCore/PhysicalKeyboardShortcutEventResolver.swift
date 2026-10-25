/// Connects UIKit's HID usage identity to the Android-compatible shortcut
/// catalog. It intentionally does not accept characters from a key event, so
/// text input is never used to infer a shortcut key.
public enum PhysicalKeyboardShortcutEventResolver {
  public static func match(
    shortcuts: [PhysicalKeyboardShortcutItem],
    currentContext: PhysicalKeyboardShortcutContext,
    hidUsage: Int,
    scanCode: Int? = nil,
    ctrl: Bool,
    shift: Bool,
    alt: Bool,
    meta: Bool
  ) -> PhysicalKeyboardShortcutItem? {
    guard let keyCode = PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: hidUsage) else {
      return nil
    }

    return PhysicalShortcutMatcher.match(
      shortcuts: shortcuts,
      currentContext: currentContext,
      keyCode: keyCode,
      scanCode: scanCode,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      meta: meta
    )
  }
}
