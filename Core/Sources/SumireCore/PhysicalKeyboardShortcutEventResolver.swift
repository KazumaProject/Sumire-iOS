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

    if let contextAwareMatch = PhysicalShortcutMatcher.match(
      shortcuts: shortcuts,
      currentContext: currentContext,
      keyCode: keyCode,
      scanCode: scanCode,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      meta: meta
    ) {
      return contextAwareMatch
    }

    // Android retries cycle_input_mode after normal matching fails, without
    // checking the binding context. Keep this fallback narrower than ordinary
    // matching and preserve the catalog's input order, as Android does.
    return shortcuts.first { item in
      item.enabled && item.actionID == PhysicalKeyboardShortcutAction.cycleInputMode.id
        && item.keyCode == keyCode && item.ctrl == ctrl && item.shift == shift
        && item.alt == alt && item.meta == meta
        && (item.scanCode == nil || item.scanCode == scanCode)
    }
  }
}
