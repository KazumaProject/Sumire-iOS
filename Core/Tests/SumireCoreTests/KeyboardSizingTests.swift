import XCTest
@testable import SumireCore

final class KeyboardSizingTests: XCTestCase {
    func testNormalAndSpecialGroupsPersistIndependentlyForEveryKeyboard() {
        let name = "KeyGroupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for kind in KeyboardKind.allCases {
            let normal = KeyboardAppearance.load(kind, group: .normal, defaults: defaults)
            let originalSpecial = KeyboardAppearance.load(kind, group: .special, defaults: defaults)
            var special = originalSpecial
            special.keyScale = 0.75; special.keyFontSize = 30
            special.save(kind, group: .special, defaults: defaults)
            XCTAssertEqual(KeyboardAppearance.load(kind, group: .normal, defaults: defaults), normal)
            XCTAssertEqual(KeyboardAppearance.load(kind, group: .special, defaults: UserDefaults(suiteName: name)!), special)
            KeyboardAppearance.reset(kind, group: .special, defaults: defaults)
            XCTAssertEqual(KeyboardAppearance.load(kind, group: .special, defaults: defaults), originalSpecial)
        }
    }
    func testAppearanceIsIndependentForEachKeyboardAndGuidesDefaultOff() {
        let name = "SumireAppearanceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for kind in KeyboardKind.allCases { XCTAssertFalse(KeyboardAppearance.load(kind, defaults: defaults).guidesVisible) }
        var sumire = KeyboardAppearance.load(.sumire, defaults: defaults)
        sumire.guidesVisible = true; sumire.keyFontSize = 30; sumire.guideFontSize = 14; sumire.keyScale = 0.8
        sumire.save(.sumire, defaults: defaults)
        XCTAssertEqual(KeyboardAppearance.load(.sumire, defaults: defaults), sumire)
        XCTAssertFalse(KeyboardAppearance.load(.tenKey, defaults: defaults).guidesVisible)
        XCTAssertEqual(KeyboardAppearance.load(.romaji, defaults: defaults).keyFontSize, 18)
    }
    func testOrientationAndRecreatedStorePreserveIndependentValues() throws {
        let name = "SumireSizingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = KeyboardSizingStore(defaults: defaults)
        try store.save(.init(height: 350, width: 0.8, alignment: 1), for: .portrait)
        try store.save(.init(height: 190, width: 0.65, alignment: 0), for: .landscape)
        let restored = KeyboardSizingStore(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(restored.load(.portrait), .init(height: 350, width: 0.8, alignment: 1))
        XCTAssertEqual(restored.load(.landscape), .init(height: 190, width: 0.65, alignment: 0))
        restored.reset(.landscape)
        XCTAssertEqual(restored.load(.landscape), .standard(.landscape))
        XCTAssertEqual(restored.load(.portrait).height, 350)
        defaults.set(Data("broken".utf8), forKey: KeyboardSizingStore.key(.landscape))
        XCTAssertEqual(restored.load(.landscape), .standard(.landscape))
        try store.save(.init(height: .infinity, width: -1, alignment: 9), for: .landscape)
        XCTAssertEqual(store.load(.landscape), .init(height: 275, width: 0.5, alignment: 1))
    }
}
