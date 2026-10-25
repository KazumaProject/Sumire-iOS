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

  func testDefaultCatalogMatchesAndroidAssignmentsAndSortOrder() {
    let items = PhysicalKeyboardShortcutDefaults.items

    XCTAssertEqual(items.count, 32)
    XCTAssertEqual(items.map(\.sortOrder), Array(0..<32))
    XCTAssertTrue(items.allSatisfy(\.enabled))
    XCTAssertTrue(items.allSatisfy { $0.scanCode == nil })
    XCTAssertEqual(Set(items.map(bindingKey)).count, items.count)
    XCTAssertEqual(
      items.map(catalogEntry),
      [
        "any|31|1000|copy",
        "any|50|1000|paste",
        "any|52|1000|cut",
        "any|29|1000|select_all",
        "any|62|1000|cycle_input_mode",
        "any|75|0010|cycle_input_mode",
        "any|214|0000|switch_to_japanese",
        "composition|62|0000|convert",
        "composition|136|0000|convert_to_hiragana",
        "composition|137|0000|convert_to_full_katakana",
        "composition|138|0000|convert_to_half_width",
        "composition|139|0000|convert_to_full_alphanumeric",
        "composition|140|0000|convert_to_half_alphanumeric",
        "composition|213|0000|switch_to_english",
        "conversion|62|0000|convert_next",
        "conversion|62|0100|convert_prev",
        "conversion|19|0000|convert_prev",
        "conversion|20|0000|convert_next",
        "conversion|66|0000|commit",
        "conversion|67|0000|cancel",
        "conversion|112|0000|cancel",
        "bunsetsu_conversion|21|0000|segment_focus_left",
        "bunsetsu_conversion|22|0000|segment_focus_right",
        "bunsetsu_conversion|21|0100|segment_width_shrink",
        "bunsetsu_conversion|22|0100|segment_width_expand",
        "bunsetsu_conversion|19|0000|convert_prev",
        "bunsetsu_conversion|20|0000|convert_next",
        "bunsetsu_conversion|62|0000|convert_next",
        "bunsetsu_conversion|62|0100|convert_prev",
        "bunsetsu_conversion|66|0000|commit",
        "bunsetsu_conversion|67|0000|cancel",
        "bunsetsu_conversion|112|0000|cancel",
      ]
    )
  }

  func testMissingDefaultsPreservesExistingCustomizedBindingAndIsIdempotent() {
    let customized = item(
      contextID: "any", keyCode: 75, alt: true,
      actionID: "switch_to_japanese", enabled: false
    )
    let existing = [customized]
    let missing = PhysicalKeyboardShortcutDefaults.missingDefaults(from: existing)

    XCTAssertEqual(missing.count, 31)
    XCTAssertFalse(missing.contains { bindingKey($0) == bindingKey(customized) })
    XCTAssertTrue(
      PhysicalKeyboardShortcutDefaults.missingDefaults(from: existing + missing).isEmpty)
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

  private func bindingKey(_ item: PhysicalKeyboardShortcutItem) -> String {
    [
      item.contextID,
      String(item.keyCode),
      item.scanCode.map(String.init) ?? "null",
      String(item.ctrl),
      String(item.shift),
      String(item.alt),
      String(item.meta),
    ].joined(separator: ":")
  }

  private func catalogEntry(_ item: PhysicalKeyboardShortcutItem) -> String {
    let modifiers = [item.ctrl, item.shift, item.alt, item.meta]
      .map { $0 ? "1" : "0" }
      .joined()
    return "\(item.contextID)|\(item.keyCode)|\(modifiers)|\(item.actionID)"
  }
}
