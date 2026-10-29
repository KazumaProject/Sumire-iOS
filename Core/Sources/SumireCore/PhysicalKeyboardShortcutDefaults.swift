/// Android's default physical-keyboard shortcut assignments at the pinned source.
/// Key codes use the stable Android KeyEvent numeric values because imported and
/// exported shortcut records store those integers.
public enum PhysicalKeyboardShortcutDefaults {
  public static let items: [PhysicalKeyboardShortcutItem] = [
    item(.any, 31, ctrl: true, action: .copy, order: 0),
    item(.any, 50, ctrl: true, action: .paste, order: 1),
    item(.any, 52, ctrl: true, action: .cut, order: 2),
    item(.any, 29, ctrl: true, action: .selectAll, order: 3),
    item(.any, 62, ctrl: true, action: .cycleInputMode, order: 4),
    item(.any, 75, alt: true, action: .cycleInputMode, order: 5),
    item(.any, 214, action: .switchToJapanese, order: 6),
    item(.composition, 62, action: .convert, order: 7),
    item(.composition, 136, action: .convertToHiragana, order: 8),
    item(.composition, 137, action: .convertToFullKatakana, order: 9),
    item(.composition, 138, action: .convertToHalfWidth, order: 10),
    item(.composition, 139, action: .convertToFullAlphanumeric, order: 11),
    item(.composition, 140, action: .convertToHalfAlphanumeric, order: 12),
    item(.composition, 213, action: .switchToEnglish, order: 13),
    item(.conversion, 62, action: .convertNext, order: 14),
    item(.conversion, 62, shift: true, action: .convertPrevious, order: 15),
    item(.conversion, 19, action: .convertPrevious, order: 16),
    item(.conversion, 20, action: .convertNext, order: 17),
    item(.conversion, 66, action: .commit, order: 18),
    item(.conversion, 67, action: .cancel, order: 19),
    item(.conversion, 112, action: .cancel, order: 20),
    item(.bunsetsuConversion, 21, action: .segmentFocusLeft, order: 21),
    item(.bunsetsuConversion, 22, action: .segmentFocusRight, order: 22),
    item(.bunsetsuConversion, 21, shift: true, action: .segmentWidthShrink, order: 23),
    item(.bunsetsuConversion, 22, shift: true, action: .segmentWidthExpand, order: 24),
    item(.bunsetsuConversion, 19, action: .convertPrevious, order: 25),
    item(.bunsetsuConversion, 20, action: .convertNext, order: 26),
    item(.bunsetsuConversion, 62, action: .convertNext, order: 27),
    item(.bunsetsuConversion, 62, shift: true, action: .convertPrevious, order: 28),
    item(.bunsetsuConversion, 66, action: .commit, order: 29),
    item(.bunsetsuConversion, 67, action: .cancel, order: 30),
    item(.bunsetsuConversion, 112, action: .cancel, order: 31),
  ]

  /// Returns only missing bindings. A customized or disabled row with the same
  /// key binding suppresses its default, matching Android's repository behavior.
  public static func missingDefaults(from existing: [PhysicalKeyboardShortcutItem])
    -> [PhysicalKeyboardShortcutItem]
  {
    items.filter { candidate in
      !existing.contains { sameBinding($0, candidate) }
    }
  }

  private static func sameBinding(
    _ lhs: PhysicalKeyboardShortcutItem,
    _ rhs: PhysicalKeyboardShortcutItem
  ) -> Bool {
    lhs.contextID == rhs.contextID && lhs.keyCode == rhs.keyCode && lhs.scanCode == rhs.scanCode
      && lhs.ctrl == rhs.ctrl && lhs.shift == rhs.shift && lhs.alt == rhs.alt
      && lhs.meta == rhs.meta
  }

  private static func item(
    _ context: PhysicalKeyboardShortcutContext,
    _ keyCode: Int,
    ctrl: Bool = false,
    shift: Bool = false,
    alt: Bool = false,
    action: PhysicalKeyboardShortcutAction,
    order: Int
  ) -> PhysicalKeyboardShortcutItem {
    PhysicalKeyboardShortcutItem(
      contextID: context.id,
      keyCode: keyCode,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      actionID: action.id,
      sortOrder: order
    )
  }
}
