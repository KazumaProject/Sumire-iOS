import XCTest

@testable import SumireCore

final class PhysicalKeyboardShortcutMatcherTests: XCTestCase {
  func testMatchPrefersCurrentContextOverAnyRegardlessOfInputOrder() {
    let any = item(contextID: "any", keyCode: 49, actionID: "cycle_input_mode")
    let conversion = item(contextID: "conversion", keyCode: 49, actionID: "convert_next")

    XCTAssertEqual(
      PhysicalShortcutMatcher.match(
        shortcuts: [any, conversion], currentContext: .conversion, keyCode: 49,
        scanCode: 0, ctrl: false, shift: false, alt: false, meta: false
      ),
      conversion
    )
  }

  func testFallsBackToAnyAndDoesNotMatchOtherContexts() {
    let any = item(contextID: "any", keyCode: 8, ctrl: true, actionID: "copy")
    let composition = item(contextID: "composition", keyCode: 8, actionID: "commit")

    XCTAssertEqual(match([any], context: .composition, keyCode: 8, ctrl: true), any)
    XCTAssertNil(match([composition], context: .conversion, keyCode: 8))
  }

  func testRequiresEnabledExactKeyModifiersAndOptionalScanCode() {
    let wildcardScan = item(
      contextID: "any", keyCode: 8, scanCode: nil, ctrl: true, actionID: "copy")
    let exactScan = item(
      contextID: "any", keyCode: 8, scanCode: 17, ctrl: true, shift: true, actionID: "cut")
    let disabled = item(contextID: "any", keyCode: 8, ctrl: true, actionID: "paste", enabled: false)

    XCTAssertEqual(
      match([wildcardScan], context: .any, keyCode: 8, scanCode: 17, ctrl: true), wildcardScan)
    XCTAssertEqual(
      match([exactScan], context: .any, keyCode: 8, scanCode: 17, ctrl: true, shift: true),
      exactScan)
    XCTAssertNil(
      match([exactScan], context: .any, keyCode: 8, scanCode: 18, ctrl: true, shift: true))
    XCTAssertNil(match([wildcardScan], context: .any, keyCode: 8, ctrl: true, meta: true))
    XCTAssertNil(match([disabled], context: .any, keyCode: 8, ctrl: true))
  }

  func testUnknownStoredContextDoesNotBecomeGlobal() {
    let unknown = item(contextID: "future_context", keyCode: 8, actionID: "copy")

    XCTAssertNil(match([unknown], context: .any, keyCode: 8))
    XCTAssertEqual(PhysicalKeyboardShortcutContext.fromID(nil), .any)
    XCTAssertEqual(PhysicalKeyboardShortcutContext.fromID("unknown"), .any)
  }

  func testContextAndActionIDsMatchAndroidCatalog() {
    XCTAssertEqual(
      PhysicalKeyboardShortcutContext.allCases.map(\.id),
      [
        "any", "composition", "conversion", "bunsetsu_conversion",
      ])
    XCTAssertEqual(PhysicalKeyboardShortcutAction.fromID("cycle_input_mode"), .cycleInputMode)
    XCTAssertNil(PhysicalKeyboardShortcutAction.fromID("switch_kana_type"))
  }

  func testAvailableActionsMatchAndroidContextRestrictionsAndOrder() {
    XCTAssertEqual(
      PhysicalKeyboardShortcutAction.available(for: .composition).map(\.id),
      [
        "switch_to_english", "cycle_input_mode", "convert", "commit", "cancel",
        "convert_to_hiragana", "convert_to_full_katakana", "convert_to_half_width",
        "convert_to_full_alphanumeric", "convert_to_half_alphanumeric",
      ])
    XCTAssertEqual(
      PhysicalKeyboardShortcutAction.available(for: .conversion).map(\.id),
      [
        "commit", "cancel", "convert_next", "convert_prev",
      ])
    XCTAssertEqual(
      PhysicalKeyboardShortcutAction.available(for: .bunsetsuConversion).map(\.id),
      [
        "commit", "cancel", "convert_next", "convert_prev", "segment_focus_left",
        "segment_focus_right", "segment_width_shrink", "segment_width_expand",
      ])
    XCTAssertEqual(
      PhysicalKeyboardShortcutAction.available(for: .any).map(\.id),
      [
        "copy", "paste", "cut", "select_all", "switch_to_japanese", "switch_to_english",
        "cycle_input_mode",
      ])
  }

  private func item(
    contextID: String,
    keyCode: Int,
    scanCode: Int? = nil,
    ctrl: Bool = false,
    shift: Bool = false,
    alt: Bool = false,
    meta: Bool = false,
    actionID: String,
    enabled: Bool = true
  ) -> PhysicalKeyboardShortcutItem {
    PhysicalKeyboardShortcutItem(
      contextID: contextID, keyCode: keyCode, scanCode: scanCode,
      ctrl: ctrl, shift: shift, alt: alt, meta: meta,
      actionID: actionID, enabled: enabled
    )
  }

  private func match(
    _ shortcuts: [PhysicalKeyboardShortcutItem],
    context: PhysicalKeyboardShortcutContext,
    keyCode: Int,
    scanCode: Int = 0,
    ctrl: Bool = false,
    shift: Bool = false,
    alt: Bool = false,
    meta: Bool = false
  ) -> PhysicalKeyboardShortcutItem? {
    PhysicalShortcutMatcher.match(
      shortcuts: shortcuts, currentContext: context, keyCode: keyCode,
      scanCode: scanCode, ctrl: ctrl, shift: shift, alt: alt, meta: meta
    )
  }
}
