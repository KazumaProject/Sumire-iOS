import XCTest
@testable import SumireCore

final class CustomInputModeStoreTests: XCTestCase {
    private func layout(direct: Bool = false, romaji: Bool = false) throws -> ImportedCustomLayout {
        var editor = CustomLayoutEditor(name: "Mode fixture", rows: 1, columns: 1)
        editor.putKey(id: "a", label: "a", action: "Text:a", special: false, row: 0, column: 0, height: 2, width: 2)
        editor.setInputMode(romaji: romaji, direct: direct)
        return try editor.validated()
    }
    private func defaults() -> UserDefaults {
        let domain = "CustomInputModeStoreTests." + UUID().uuidString
        let value = UserDefaults(suiteName: domain)!
        addTeardownBlock { value.removePersistentDomain(forName: domain) }
        return value
    }
    func testRememberOptInUsesStableLayoutIdentityAndOtherwiseLayoutFlags() throws {
        let original = try layout(direct: true), other = try layout(romaji: true)
        var store = CustomInputModeStore()
        XCTAssertEqual(store.state(for: original, remember: true), CustomInputMode(direct: true, romaji: false))
        try store.set(state: CustomInputMode(direct: false, romaji: true), for: original.id)
        XCTAssertEqual(store.state(for: original, remember: false), CustomInputMode(direct: true, romaji: false))
        XCTAssertEqual(store.state(for: original, remember: true), CustomInputMode(direct: false, romaji: true))
        XCTAssertEqual(store.state(for: other, remember: true), CustomInputMode(direct: false, romaji: true))
        let defaults = defaults(); try store.save(defaults: defaults)
        XCTAssertEqual(try CustomInputModeStore.load(defaults: defaults), store)
    }
    func testInvalidSetIsAtomicAndStorageLimitsAreEnforced() throws {
        var store = CustomInputModeStore()
        let state = CustomInputMode(direct: true, romaji: true)
        for id in ["", "bad\0id", String(repeating: "あ", count: 86)] {
            let before = store
            XCTAssertThrowsError(try store.set(state: state, for: id))
            XCTAssertEqual(store, before)
        }
        for i in 0..<100 { try store.set(state: state, for: "layout-\(i)") }
        let full = store
        XCTAssertThrowsError(try store.set(state: state, for: "overflow"))
        XCTAssertEqual(store, full)
        try store.set(state: CustomInputMode(direct: false, romaji: false), for: "layout-0")
        for raw in [#"{"version":2,"states":{}}"#, #"{"version":1,"states":{"":{"direct":true,"romaji":false}}}"#,
                    #"{"version":1,"states":{"id":{"direct":1,"romaji":false}}}"#] {
            XCTAssertThrowsError(try CustomInputModeStore.decode(Data(raw.utf8)))
        }
        XCTAssertThrowsError(try CustomInputModeStore.decode(Data(repeating: 32, count: CustomInputModeStore.maximumBytes + 1)))
        let defaults = defaults(); defaults.set("wrong type", forKey: CustomInputModeStore.storageKey)
        XCTAssertThrowsError(try CustomInputModeStore.load(defaults: defaults))
    }
    func testRetainingCurrentLayoutsReleasesCapacityWithoutWritingDefaults() throws {
        var store = CustomInputModeStore()
        let remembered = CustomInputMode(direct: true, romaji: false)
        for index in 0..<100 { try store.set(state: remembered, for: "old-\(index)") }
        let defaults = defaults(); try store.save(defaults: defaults)
        let saved = defaults.data(forKey: CustomInputModeStore.storageKey)
        store.retain(layoutIDs: ["old-0", "new-layout"])
        try store.set(state: CustomInputMode(direct: false, romaji: true), for: "new-layout")
        let encoded = try JSONEncoder().encode(store)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let states = try XCTUnwrap(object["states"] as? [String: Any])
        XCTAssertEqual(Set(states.keys), ["old-0", "new-layout"])
        let retained = try XCTUnwrap(states["old-0"] as? [String: Bool])
        XCTAssertEqual(retained, ["direct": true, "romaji": false])
        XCTAssertEqual(defaults.data(forKey: CustomInputModeStore.storageKey), saved)
        _ = try CustomInputModeStore.load(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: CustomInputModeStore.storageKey), saved)
        try store.save(defaults: defaults)
        XCTAssertEqual(try CustomInputModeStore.load(defaults: defaults), store)
    }
    func testBackupRestoresAllThreeSettingsAndRejectsMalformedDataBeforeMutation() throws {
        let source = defaults(), destination = defaults()
        XCTAssertFalse(source.bool(forKey: CustomInputModeStore.rememberKey))
        XCTAssertFalse(source.bool(forKey: CustomInputModeStore.replaceKey))
        var store = CustomInputModeStore()
        try store.set(state: CustomInputMode(direct: true, romaji: false), for: "stable-id")
        try store.save(defaults: source)
        source.set(true, forKey: CustomInputModeStore.rememberKey)
        source.set(true, forKey: CustomInputModeStore.replaceKey)
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: source)
        try snapshot.restore(defaults: destination)
        XCTAssertTrue(destination.bool(forKey: CustomInputModeStore.rememberKey))
        XCTAssertTrue(destination.bool(forKey: CustomInputModeStore.replaceKey))
        XCTAssertEqual(try CustomInputModeStore.load(defaults: destination), store)
        var malformed = snapshot
        malformed.values[CustomInputModeStore.storageKey] = .data(Data(#"{"version":2,"states":{}}"#.utf8))
        XCTAssertThrowsError(try malformed.restore(defaults: destination))
        XCTAssertEqual(try KeyboardSettingsSnapshot.capture(defaults: destination), snapshot)
        malformed = snapshot; malformed.values[CustomInputModeStore.rememberKey] = .number(1)
        XCTAssertThrowsError(try malformed.validate())
        malformed = snapshot; malformed.values[CustomInputModeStore.replaceKey] = .text("true")
        XCTAssertThrowsError(try malformed.validate())
    }
}
