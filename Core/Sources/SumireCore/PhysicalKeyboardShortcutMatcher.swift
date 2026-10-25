import Foundation

/// The editor state in which an Android-compatible physical keyboard shortcut is active.
/// `any` is also the fallback used when decoding an unknown or missing context ID.
public enum PhysicalKeyboardShortcutContext: String, CaseIterable, Codable, Sendable {
  case any
  case composition
  case conversion
  case bunsetsuConversion = "bunsetsu_conversion"

  public var id: String { rawValue }

  public static func fromID(_ id: String?) -> Self {
    guard let id, let context = Self(rawValue: id) else { return .any }
    return context
  }
}

/// Action IDs and context restrictions mirror the pinned Android shortcut catalog.
/// UI labels and execution remain the responsibility of the platform layer.
public enum PhysicalKeyboardShortcutAction: String, CaseIterable, Codable, Sendable {
  case copy
  case paste
  case cut
  case selectAll = "select_all"
  case switchToJapanese = "switch_to_japanese"
  case switchToEnglish = "switch_to_english"
  case cycleInputMode = "cycle_input_mode"
  case convert
  case commit
  case cancel
  case convertToHiragana = "convert_to_hiragana"
  case convertToFullKatakana = "convert_to_full_katakana"
  case convertToHalfWidth = "convert_to_half_width"
  case convertToFullAlphanumeric = "convert_to_full_alphanumeric"
  case convertToHalfAlphanumeric = "convert_to_half_alphanumeric"
  case convertNext = "convert_next"
  case convertPrevious = "convert_prev"
  case segmentFocusLeft = "segment_focus_left"
  case segmentFocusRight = "segment_focus_right"
  case segmentWidthShrink = "segment_width_shrink"
  case segmentWidthExpand = "segment_width_expand"

  public var id: String { rawValue }

  public var allowedContexts: Set<PhysicalKeyboardShortcutContext> {
    switch self {
    case .copy, .paste, .cut, .selectAll, .switchToJapanese:
      return [.any]
    case .switchToEnglish, .cycleInputMode:
      return [.any, .composition]
    case .convert, .convertToHiragana, .convertToFullKatakana,
      .convertToHalfWidth, .convertToFullAlphanumeric, .convertToHalfAlphanumeric:
      return [.composition]
    case .commit, .cancel:
      return [.composition, .conversion, .bunsetsuConversion]
    case .convertNext, .convertPrevious:
      return [.conversion, .bunsetsuConversion]
    case .segmentFocusLeft, .segmentFocusRight, .segmentWidthShrink, .segmentWidthExpand:
      return [.bunsetsuConversion]
    }
  }

  public func isAllowed(in context: PhysicalKeyboardShortcutContext) -> Bool {
    allowedContexts.contains(context)
  }

  public static func fromID(_ id: String?) -> Self? {
    guard let id else { return nil }
    return Self(rawValue: id)
  }

  /// `allCases` preserves the catalog order used by Android's `entries.filter`.
  public static func available(for context: PhysicalKeyboardShortcutContext) -> [Self] {
    allCases.filter { $0.isAllowed(in: context) }
  }
}

/// Platform-neutral shortcut data needed by Android's matcher. Unknown `contextID`s
/// are preserved so they cannot accidentally become global (`any`) shortcuts.
public struct PhysicalKeyboardShortcutItem: Codable, Equatable, Sendable {
  public var id: Int64
  public var contextID: String
  public var keyCode: Int
  public var scanCode: Int?
  public var ctrl: Bool
  public var shift: Bool
  public var alt: Bool
  public var meta: Bool
  public var actionID: String
  public var enabled: Bool
  public var sortOrder: Int

  public init(
    id: Int64 = 0,
    contextID: String = PhysicalKeyboardShortcutContext.any.id,
    keyCode: Int,
    scanCode: Int? = nil,
    ctrl: Bool = false,
    shift: Bool = false,
    alt: Bool = false,
    meta: Bool = false,
    actionID: String,
    enabled: Bool = true,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.contextID = contextID
    self.keyCode = keyCode
    self.scanCode = scanCode
    self.ctrl = ctrl
    self.shift = shift
    self.alt = alt
    self.meta = meta
    self.actionID = actionID
    self.enabled = enabled
    self.sortOrder = sortOrder
  }
}

/// Applies the pinned Android matching and precedence rules without handling
/// UIKit key-event delivery or action execution.
public enum PhysicalShortcutMatcher {
  public static func match(
    shortcuts: [PhysicalKeyboardShortcutItem],
    currentContext: PhysicalKeyboardShortcutContext,
    keyCode: Int,
    scanCode: Int,
    ctrl: Bool,
    shift: Bool,
    alt: Bool,
    meta: Bool
  ) -> PhysicalKeyboardShortcutItem? {
    let candidates = shortcuts.filter { item in
      item.enabled && item.keyCode == keyCode && item.ctrl == ctrl && item.shift == shift
        && item.alt == alt && item.meta == meta
        && (item.scanCode == nil || item.scanCode == scanCode)
    }

    return candidates.first { $0.contextID == currentContext.id }
      ?? candidates.first { $0.contextID == PhysicalKeyboardShortcutContext.any.id }
  }
}
