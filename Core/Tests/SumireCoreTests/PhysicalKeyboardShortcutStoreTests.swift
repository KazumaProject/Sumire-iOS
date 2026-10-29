import XCTest

@testable import SumireCore

final class PhysicalKeyboardShortcutStoreTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let domain = "PhysicalKeyboardShortcutStoreTests." + UUID().uuidString
    let value = UserDefaults(suiteName: domain)!
    addTeardownBlock { value.removePersistentDomain(forName: domain) }
    return value
  }

  private func shortcut(
    id: Int64 = 0,
    context: PhysicalKeyboardShortcutContext = .any,
    keyCode: Int = 42,
    scanCode: Int? = nil,
    ctrl: Bool = false,
    enabled: Bool = true,
    order: Int = 0,
    action: PhysicalKeyboardShortcutAction = .copy
  ) -> PhysicalKeyboardShortcutItem {
    PhysicalKeyboardShortcutItem(
      id: id,
      contextID: context.id,
      keyCode: keyCode,
      scanCode: scanCode,
      ctrl: ctrl,
      actionID: action.id,
      enabled: enabled,
      sortOrder: order
    )
  }

  func testEnsureDefaultsSeedsOnceAndAssignsStableIDs() throws {
    var store = PhysicalKeyboardShortcutStore()
    try store.ensureDefaultShortcuts()

    XCTAssertEqual(store.orderedItems.count, 32)
    XCTAssertEqual(store.orderedItems.map(\.sortOrder), Array(0..<32))
    XCTAssertEqual(Set(store.items.map(\.id)).count, 32)
    XCTAssertTrue(store.items.allSatisfy { $0.id > 0 })

    let seeded = store.items
    try store.ensureDefaultShortcuts()
    XCTAssertEqual(store.items, seeded)
  }

  func testEnsureDefaultsAddsMissingBindingsButPreservesCustomizedAndDisabledRows() throws {
    let customized = shortcut(id: 40, keyCode: 31, ctrl: true, action: .cut)
    let disabled = shortcut(id: 41, keyCode: 50, ctrl: true, enabled: false, action: .paste)
    var store = try PhysicalKeyboardShortcutStore(items: [customized, disabled])

    try store.ensureDefaultShortcuts()

    XCTAssertEqual(store.item(id: 40), customized)
    XCTAssertEqual(store.item(id: 41), disabled)
    XCTAssertEqual(store.items.count, 32)
    XCTAssertEqual(
      store.items.filter { $0.contextID == "any" && $0.keyCode == 31 && $0.ctrl }.count,
      1
    )
    let seededAgain = store.items
    try store.ensureDefaultShortcuts()
    XCTAssertEqual(store.items, seededAgain)
  }

  func testInsertRejectsDuplicateIncludingNilScanCodeAndAllowsDistinctBindings() throws {
    var store = PhysicalKeyboardShortcutStore()
    XCTAssertTrue(try store.insert(shortcut(id: 1)))
    XCTAssertFalse(try store.insert(shortcut(id: 2, action: .paste)))
    XCTAssertTrue(try store.insert(shortcut(id: 2, scanCode: 7)))
    XCTAssertTrue(try store.insert(shortcut(id: 3, context: .composition)))
    XCTAssertTrue(try store.insert(shortcut(id: 4, ctrl: true)))
    XCTAssertEqual(store.items.count, 4)
  }

  func testUpdateRejectsConflictsAndLeavesRowsUnchanged() throws {
    let first = shortcut(id: 1, keyCode: 41)
    let second = shortcut(id: 2, keyCode: 42)
    var store = try PhysicalKeyboardShortcutStore(items: [first, second])

    XCTAssertFalse(store.update(shortcut(id: 2, keyCode: 41)))
    XCTAssertEqual(store.item(id: 2), second)
    XCTAssertTrue(store.update(shortcut(id: 2, keyCode: 43, action: .paste)))
    XCTAssertEqual(store.item(id: 2)?.keyCode, 43)
    XCTAssertFalse(store.update(shortcut(id: 3, keyCode: 44)))
  }

  func testOrderedEnabledLookupAndDeleteMatchRepositoryViews() throws {
    let later = shortcut(id: 2, keyCode: 41, order: 2)
    let disabled = shortcut(id: 3, keyCode: 43, enabled: false, order: 1)
    let earlier = shortcut(id: 1, keyCode: 42, order: 1)
    var store = try PhysicalKeyboardShortcutStore(items: [later, disabled, earlier])

    XCTAssertEqual(store.orderedItems.map(\.id), [1, 3, 2])
    XCTAssertEqual(store.enabledItems.map(\.id), [1, 2])
    XCTAssertEqual(store.item(id: 3), disabled)
    XCTAssertTrue(store.delete(id: 3))
    XCTAssertFalse(store.delete(id: 3))
    XCTAssertNil(store.item(id: 3))
  }

  func testPersistenceRoundTripsAndMissingStorageLoadsEmpty() throws {
    let source = defaults()
    XCTAssertTrue(try PhysicalKeyboardShortcutStore.load(defaults: source).items.isEmpty)

    var store = PhysicalKeyboardShortcutStore()
    try store.ensureDefaultShortcuts()
    XCTAssertTrue(store.delete(id: 2))
    XCTAssertTrue(try store.insert(shortcut(keyCode: 200, order: 50, action: .cancel)))
    try store.save(defaults: source)

    let restored = try PhysicalKeyboardShortcutStore.load(defaults: source)
    XCTAssertEqual(restored, store)
    XCTAssertEqual(restored.orderedItems, store.orderedItems)
  }

  func testClosedAccessSnapshotReadsAppGroupStoreWithoutWritingSharedDefaults() throws {
    let sharedName = "ShortcutShared." + UUID().uuidString
    let localName = "ShortcutLocal." + UUID().uuidString
    let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
    let local = try XCTUnwrap(UserDefaults(suiteName: localName))
    defer {
      shared.removePersistentDomain(forName: sharedName)
      local.removePersistentDomain(forName: localName)
    }

    var configured = PhysicalKeyboardShortcutStore()
    try configured.ensureDefaultShortcuts()
    try configured.save(defaults: shared)
    let sharedBefore = shared.dictionaryRepresentation() as NSDictionary
    let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)

    XCTAssertTrue(access.readsSharedSettings)
    XCTAssertFalse(access.writesSharedSettings)
    XCTAssertEqual(
      try PhysicalKeyboardShortcutStore.load(defaults: access.readDefaults), configured)

    XCTAssertTrue(configured.delete(id: 1))
    try configured.save(defaults: access.readDefaults)
    access.reload()
    XCTAssertEqual(
      try PhysicalKeyboardShortcutStore.load(defaults: access.readDefaults).items.count, 32)
    XCTAssertEqual(sharedBefore, shared.dictionaryRepresentation() as NSDictionary)
  }

  func testLoadAndDecodeRejectMalformedOrUnsupportedData() throws {
    let defaults = defaults()
    defaults.set("not data", forKey: PhysicalKeyboardShortcutStore.storageKey)
    XCTAssertThrowsError(try PhysicalKeyboardShortcutStore.load(defaults: defaults))

    for raw in [
      #"{"version":2,"items":[]}"#,
      #"{"version":1,"items":[{"id":0,"contextID":"any","keyCode":1,"ctrl":false,"shift":false,"alt":false,"meta":false,"actionID":"copy","enabled":true,"sortOrder":0}]}"#,
    ] {
      XCTAssertThrowsError(try PhysicalKeyboardShortcutStore.decode(Data(raw.utf8)))
    }
    XCTAssertThrowsError(
      try PhysicalKeyboardShortcutStore.decode(
        Data(repeating: 0, count: PhysicalKeyboardShortcutStore.maximumBytes + 1)
      )
    )
  }

  func testInvalidInitialRowsAndDuplicateUpdatesAreRejected() throws {
    XCTAssertThrowsError(try PhysicalKeyboardShortcutStore(items: [shortcut(id: 0)]))
    XCTAssertThrowsError(
      try PhysicalKeyboardShortcutStore(items: [shortcut(id: 1), shortcut(id: 1, keyCode: 43)])
    )
    XCTAssertThrowsError(
      try PhysicalKeyboardShortcutStore(items: [shortcut(id: 1), shortcut(id: 2)])
    )
  }

  func testOversizedInsertFailsWithoutChangingTheStore() throws {
    var store = PhysicalKeyboardShortcutStore()
    XCTAssertTrue(try store.insert(shortcut(id: 1)))
    let before = store
    var oversized = shortcut(id: 2, keyCode: 43)
    oversized.actionID = String(repeating: "x", count: PhysicalKeyboardShortcutStore.maximumBytes)

    XCTAssertThrowsError(try store.insert(oversized))
    XCTAssertEqual(store, before)
  }
}
