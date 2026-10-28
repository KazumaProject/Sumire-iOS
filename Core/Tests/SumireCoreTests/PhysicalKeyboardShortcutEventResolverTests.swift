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

  func testCycleInputModeFallsBackAcrossConversionContexts() {
    let compositionBinding = item(context: .composition, action: .cycleInputMode)

    XCTAssertEqual(
      resolve(shortcuts: [compositionBinding], context: .conversion, usage: 0x04),
      compositionBinding
    )
    XCTAssertEqual(
      resolve(shortcuts: [compositionBinding], context: .bunsetsuConversion, usage: 0x04),
      compositionBinding
    )
  }

  func testContextAwareMatchPrecedesCycleInputModeFallback() {
    let fallback = item(context: .composition, action: .cycleInputMode)
    let exact = item(context: .conversion, action: .commit)

    XCTAssertEqual(
      resolve(shortcuts: [fallback, exact], context: .conversion, usage: 0x04),
      exact
    )
  }

  func testCycleInputModeFallbackPreservesShortcutListOrder() {
    let first = PhysicalKeyboardShortcutItem(
      id: 8,
      contextID: PhysicalKeyboardShortcutContext.composition.id,
      keyCode: 29,
      actionID: PhysicalKeyboardShortcutAction.cycleInputMode.id
    )
    let second = PhysicalKeyboardShortcutItem(
      id: 9,
      contextID: PhysicalKeyboardShortcutContext.composition.id,
      keyCode: 29,
      actionID: PhysicalKeyboardShortcutAction.cycleInputMode.id
    )

    XCTAssertEqual(resolve(shortcuts: [first, second], context: .conversion, usage: 0x04), first)
  }

  func testCycleInputModeFallbackRequiresMatchingKeyModifiersScanCodeAndEnabledState() {
    let matching = PhysicalKeyboardShortcutItem(
      id: 7,
      contextID: PhysicalKeyboardShortcutContext.composition.id,
      keyCode: 29,
      scanCode: 17,
      ctrl: true,
      shift: true,
      alt: true,
      meta: true,
      actionID: PhysicalKeyboardShortcutAction.cycleInputMode.id
    )
    XCTAssertEqual(resolveCycleFallback(shortcuts: [matching]), matching)
    XCTAssertNil(resolveCycleFallback(shortcuts: [matching], scanCode: nil))
    XCTAssertNil(resolveCycleFallback(shortcuts: [matching], scanCode: 18))

    var wrongKey = matching
    wrongKey.keyCode = 30
    var wrongCtrl = matching
    wrongCtrl.ctrl = false
    var wrongShift = matching
    wrongShift.shift = false
    var wrongAlt = matching
    wrongAlt.alt = false
    var wrongMeta = matching
    wrongMeta.meta = false
    var disabled = matching
    disabled.enabled = false

    for nonmatching in [wrongKey, wrongCtrl, wrongShift, wrongAlt, wrongMeta, disabled] {
      XCTAssertNil(resolveCycleFallback(shortcuts: [nonmatching]))
    }
  }

  func testOnlyCycleInputModeUsesTheContextAgnosticFallback() {
    let compositionShortcut = item(context: .composition, action: .switchToEnglish)

    XCTAssertNil(resolve(shortcuts: [compositionShortcut], context: .conversion, usage: 0x04))
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

  private func resolveCycleFallback(
    shortcuts: [PhysicalKeyboardShortcutItem],
    scanCode: Int? = 17
  ) -> PhysicalKeyboardShortcutItem? {
    resolve(
      shortcuts: shortcuts,
      context: .conversion,
      usage: 0x04,
      scanCode: scanCode,
      ctrl: true,
      shift: true,
      alt: true,
      meta: true
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
