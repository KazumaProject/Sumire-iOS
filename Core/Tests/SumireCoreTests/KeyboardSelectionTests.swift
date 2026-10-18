import XCTest
@testable import SumireCore

final class KeyboardSelectionTests: XCTestCase {
    func testLastItemCannotBeRemovedOrSavedAsEmpty() throws {
        var value = try KeyboardSelection(ids: ["builtin:tenKey", "builtin:gojuon"])
        value.remove(["builtin:tenKey"])
        XCTAssertEqual(value.ids, ["builtin:gojuon"])
        value.remove(["builtin:gojuon"])
        XCTAssertEqual(value.ids, ["builtin:gojuon"])
        XCTAssertThrowsError(try KeyboardSelection(ids: []))
        XCTAssertThrowsError(try KeyboardSelection(ids: ["a", "a"]))
    }
    func testOrderRoundTripAndDeletedCustomFallback() throws {
        let name = "selection-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try KeyboardSelection(ids: ["custom:a", "builtin:gojuon"]).save(defaults: defaults)
        XCTAssertEqual(KeyboardSelection.load(defaults: defaults, available: ["builtin:gojuon", "custom:a"]).ids,
                       ["custom:a", "builtin:gojuon"])
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        defaults.removeObject(forKey: KeyboardSelection.storageKey)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(KeyboardSelection.load(defaults: defaults, available: ["builtin:tenKey"]).ids, ["builtin:tenKey"])
        XCTAssertEqual(KeyboardSelection.load(defaults: defaults, available: ["builtin:gojuon", "custom:a"]).ids,
                       ["custom:a", "builtin:gojuon"])
    }
}
