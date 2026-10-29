import Foundation

/// Persistent, platform-neutral shortcut records. Pass the containing app-group
/// defaults from the host app or the extension's read-only settings snapshot.
/// This store never accesses input text, UIKit events, or the network.
public struct PhysicalKeyboardShortcutStore: Equatable, Sendable {
  public static let storageKey = "physicalKeyboardShortcuts.items.v1"
  public static let maximumBytes = 1_048_576

  public private(set) var items: [PhysicalKeyboardShortcutItem]

  public init() {
    items = []
  }

  public init(items: [PhysicalKeyboardShortcutItem]) throws {
    self.items = items
    try validate()
  }

  /// Records ordered like Android's `ORDER BY sortOrder, id` query.
  public var orderedItems: [PhysicalKeyboardShortcutItem] {
    items.sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
  }

  public var enabledItems: [PhysicalKeyboardShortcutItem] {
    orderedItems.filter(\.enabled)
  }

  public func item(id: Int64) -> PhysicalKeyboardShortcutItem? {
    items.first { $0.id == id }
  }

  /// Seeds the Android catalog when empty, or adds only bindings that are not
  /// already present. Existing customized and disabled bindings are preserved.
  public mutating func ensureDefaultShortcuts() throws {
    var next = self
    let defaults =
      next.items.isEmpty
      ? PhysicalKeyboardShortcutDefaults.items
      : PhysicalKeyboardShortcutDefaults.missingDefaults(from: next.items)
    for item in defaults {
      _ = try next.insert(item)
    }
    try next.validate()
    self = next
  }

  /// Returns false for a duplicate binding or explicit ID. An ID of zero is
  /// allocated, matching Room's auto-generated primary key behavior.
  @discardableResult
  public mutating func insert(_ item: PhysicalKeyboardShortcutItem) throws -> Bool {
    guard !containsDuplicateBinding(item), item.id >= 0 else { return false }
    var inserted = item
    if inserted.id == 0 {
      guard let nextID = nextID() else { throw Self.invalidData() }
      inserted.id = nextID
    } else if items.contains(where: { $0.id == inserted.id }) {
      return false
    }
    var next = self
    next.items.append(inserted)
    try next.validate()
    self = next
    return true
  }

  /// Returns false when the row does not exist or another row owns its binding.
  @discardableResult
  public mutating func update(_ item: PhysicalKeyboardShortcutItem) -> Bool {
    guard item.id > 0,
      let index = items.firstIndex(where: { $0.id == item.id }),
      !containsDuplicateBinding(item, excludingID: item.id)
    else { return false }
    var next = self
    next.items[index] = item
    guard (try? next.validate()) != nil else { return false }
    self = next
    return true
  }

  @discardableResult
  public mutating func delete(id: Int64) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
    items.remove(at: index)
    return true
  }

  public func save(defaults: UserDefaults) throws {
    try validate()
    let data = try JSONEncoder().encode(StoredState(version: 1, items: items))
    guard data.count <= Self.maximumBytes else { throw Self.invalidData() }
    defaults.set(data, forKey: Self.storageKey)
  }

  public static func load(defaults: UserDefaults) throws -> Self {
    guard let value = defaults.object(forKey: storageKey) else { return Self() }
    guard let data = value as? Data else { throw invalidData() }
    return try decode(data)
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw invalidData() }
    let state = try JSONDecoder().decode(StoredState.self, from: data)
    guard state.version == 1 else { throw invalidData() }
    return try Self(items: state.items)
  }

  private func validate() throws {
    guard items.allSatisfy({ $0.id > 0 }) else { throw Self.invalidData() }
    guard Set(items.map(\.id)).count == items.count else { throw Self.invalidData() }
    for index in items.indices {
      guard !items[(index + 1)...].contains(where: { Self.sameBinding(items[index], $0) }) else {
        throw Self.invalidData()
      }
    }
    guard let data = try? JSONEncoder().encode(StoredState(version: 1, items: items)),
      data.count <= Self.maximumBytes
    else { throw Self.invalidData() }
  }

  private func containsDuplicateBinding(
    _ item: PhysicalKeyboardShortcutItem,
    excludingID: Int64? = nil
  ) -> Bool {
    items.contains { existing in
      existing.id != excludingID && Self.sameBinding(existing, item)
    }
  }

  private func nextID() -> Int64? {
    guard let maximum = items.map(\.id).max() else { return 1 }
    guard maximum < Int64.max else { return nil }
    return maximum + 1
  }

  private static func sameBinding(
    _ lhs: PhysicalKeyboardShortcutItem,
    _ rhs: PhysicalKeyboardShortcutItem
  ) -> Bool {
    lhs.contextID == rhs.contextID && lhs.keyCode == rhs.keyCode && lhs.scanCode == rhs.scanCode
      && lhs.ctrl == rhs.ctrl && lhs.shift == rhs.shift && lhs.alt == rhs.alt
      && lhs.meta == rhs.meta
  }

  private static func invalidData() -> PersonalDataError {
    PersonalDataError("物理キーボードショートカットの保存データが不正です")
  }

  private struct StoredState: Codable {
    let version: Int
    let items: [PhysicalKeyboardShortcutItem]
  }
}
