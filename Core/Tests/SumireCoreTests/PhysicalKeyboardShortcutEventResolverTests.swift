import XCTest

@testable import SumireCore

final class PhysicalKeyboardShortcutEventResolverTests: XCTestCase {
  func testResolvesHIDUsageAndModifiersThroughAndroidDefaults() {
    let match = resolve(
      shortcuts: PhysicalKeyboardShortcutDefaults.items,
      context: .any,
      usage: 0x06,  // C
      ctrl: true
    )

    XCTAssertEqual(match?.actionID, PhysicalKeyboardShortcutAction.copy.id)
    XCTAssertEqual(match?.keyCode, 31)
  }

  func testPrefersMatchingEditorContextOverGlobalShortcut() {
    let global = item(context: .any, action: .cycleInputMode)
    let composition = item(context: .composition, action: .switchToEnglish)

    let match = resolve(
      shortcuts: [global, composition],
      context: .composition,
      usage: 0x04
    )

    XCTAssertEqual(match, composition)
  }

  func testUnsupportedHIDUsageDoesNotFallBackToCharactersOrAnyBinding() {
    let global = item(context: .any, action: .cycleInputMode)

    XCTAssertNil(resolve(shortcuts: [global], context: .any, usage: 0xFFFF))
  }

  func testUnknownScanCodeOnlyMatchesWildcardBindings() {
    let wildcard = item(context: .any, action: .cycleInputMode)
    let scanSpecific = PhysicalKeyboardShortcutItem(
      id: 2,
      contextID: PhysicalKeyboardShortcutContext.any.id,
      keyCode: 29,
      scanCode: 17,
      actionID: PhysicalKeyboardShortcutAction.switchToEnglish.id,
      sortOrder: 1
    )

    XCTAssertEqual(resolve(shortcuts: [wildcard], context: .any, usage: 0x04), wildcard)
    XCTAssertNil(resolve(shortcuts: [scanSpecific], context: .any, usage: 0x04))
    XCTAssertEqual(
      resolve(shortcuts: [scanSpecific], context: .any, usage: 0x04, scanCode: 17),
      scanSpecific
    )
  }

  private func resolve(
    shortcuts: [PhysicalKeyboardShortcutItem],
    context: PhysicalKeyboardShortcutContext,
    usage: Int,
    scanCode: Int? = nil,
    ctrl: Bool = false,
    shift: Bool = false,
    alt: Bool = false,
    meta: Bool = false
  ) -> PhysicalKeyboardShortcutItem? {
    PhysicalKeyboardShortcutEventResolver.match(
      shortcuts: shortcuts,
      currentContext: context,
      hidUsage: usage,
      scanCode: scanCode,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      meta: meta
    )
  }

  private func item(
    context: PhysicalKeyboardShortcutContext,
    action: PhysicalKeyboardShortcutAction
  ) -> PhysicalKeyboardShortcutItem {
    PhysicalKeyboardShortcutItem(
      id: context == .any ? 1 : 2,
      contextID: context.id,
      keyCode: 29,
      actionID: action.id,
      sortOrder: context == .any ? 0 : 1
    )
  }
}
