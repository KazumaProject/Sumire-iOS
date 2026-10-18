import XCTest
@testable import SumireCore

final class SymbolKeyboardTests: XCTestCase {
    func testBundledCatalogMatchesPinnedSurfaceCountsAndCategories() throws {
        let categories = try SymbolKeyboardCatalog.load()
        for (mode, count, categoryCount) in [(SymbolKeyboardMode.emoji, 1902, 10), (.emoticon, 435, 6), (.symbol, 2103, 18)] {
            let selected = categories.filter { $0.mode == mode }
            XCTAssertEqual(selected.count, categoryCount)
            let values = selected.flatMap(\.symbols)
            XCTAssertEqual(values.count, count)
            XCTAssertEqual(Set(values).count, values.count)
            XCTAssertFalse(values.contains(""))
        }
        XCTAssertEqual(categories.first?.id, "SMILEYS_EMOTION")
        XCTAssertTrue(categories.contains { $0.mode == .emoji && $0.symbols.contains("😀") })
        XCTAssertTrue(categories.contains { $0.id == "ARROWS" && $0.symbols.contains("→") })
        XCTAssertNotNil(SymbolKeyboardCatalog.noticeURL)
        XCTAssertNotNil(SymbolKeyboardCatalog.dataLicenseURL)
    }
    func testInitialModeAndHistoryRemainSeparateFromLastKeyboard() throws {
        let name = "SymbolKeyboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("builtin:sumire", forKey: "keyboard.lastUsed")
        XCTAssertEqual(SymbolKeyboardMode.initialMode(defaults: defaults), .emoji)
        SymbolKeyboardMode.clipboard.saveAsInitialMode(defaults: defaults)
        XCTAssertEqual(SymbolKeyboardMode.initialMode(defaults: defaults), .clipboard)
        var history = SymbolKeyboardHistory(defaults: defaults)
        history.record("😀", mode: .emoji, defaults: defaults)
        history.record("😊", mode: .emoji, defaults: defaults)
        history.record("😀", mode: .emoji, defaults: defaults)
        history.record("private clipboard", mode: .clipboard, defaults: defaults)
        XCTAssertEqual(SymbolKeyboardHistory(defaults: defaults).symbols(for: .emoji), ["😀", "😊"])
        XCTAssertEqual(history.symbols(for: .clipboard), [])
        history.remove("😀", mode: .emoji, defaults: defaults)
        XCTAssertEqual(SymbolKeyboardHistory(defaults: defaults).symbols(for: .emoji), ["😊"])
        XCTAssertEqual(defaults.string(forKey: "keyboard.lastUsed"), "builtin:sumire")
        defaults.set("invalid", forKey: SymbolKeyboardMode.initialModeKey)
        XCTAssertEqual(SymbolKeyboardMode.initialMode(defaults: defaults), .emoji)
    }
    func testHistoryLimitsSizeAndRejectsOversizedValues() throws {
        let name = "SymbolKeyboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var history = SymbolKeyboardHistory(defaults: defaults)
        for index in 0..<150 { history.record("\(index)", mode: .symbol, defaults: defaults) }
        history.record(String(repeating: "a", count: 4097), mode: .symbol, defaults: defaults)
        XCTAssertEqual(history.symbols(for: .symbol).count, 100)
        XCTAssertEqual(history.symbols(for: .symbol).first, "149")
        XCTAssertEqual(SymbolKeyboardHistory(defaults: defaults).symbols(for: .symbol), history.symbols(for: .symbol))
    }
}
