import XCTest
@testable import SumireCore

final class EmojiSkinToneTests: XCTestCase {
    func testVerifiedVariantsHandleSelectorsAndSinglePersonZWJ() {
        let thumb = EmojiSkinToneVariants.variants(for: "👍")
        XCTAssertEqual(thumb.count, 6)
        XCTAssertEqual(Array(thumb.dropFirst()), ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        XCTAssertEqual(EmojiSkinToneVariants.variants(for: "👍🏽"), thumb)
        XCTAssertEqual(EmojiSkinToneVariants.applying(.dark, to: "👍️"), "👍🏿")
        XCTAssertEqual(EmojiSkinToneVariants.applying(.light, to: "👩‍💻"), "👩🏻‍💻")
        XCTAssertTrue(EmojiSkinToneVariants.variants(for: "😀").isEmpty)
        XCTAssertTrue(EmojiSkinToneVariants.variants(for: "👨‍👩‍👦").isEmpty)
        XCTAssertTrue(EmojiSkinToneVariants.variants(for: "👍‍😀").isEmpty)
        XCTAssertEqual(EmojiSkinToneVariants.applying(.dark, to: "👨‍👩‍👦"), "👨‍👩‍👦")
    }
    func testAllCatalogVariantsHaveUniqueStandardAndFiveTones() throws {
        let symbols = try SymbolKeyboardCatalog.load().filter { $0.mode == .emoji }.flatMap(\.symbols)
        var supported = 0
        for symbol in symbols {
            let variants = EmojiSkinToneVariants.variants(for: symbol)
            if variants.isEmpty { continue }
            supported += 1
            XCTAssertEqual(variants.count, 6, symbol)
            XCTAssertEqual(Set(variants).count, 6, symbol)
            XCTAssertEqual(variants.map { EmojiSkinTone.tone(in: $0) }, EmojiSkinTone.allCases, symbol)
        }
        XCTAssertEqual(supported, 255)
        XCTAssertNotNil(EmojiSkinToneVariants.noticeURL)
    }
    func testDefaultSkinTonePersistsAndRejectsUnknownValues() throws {
        let name = "EmojiSkinToneTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(EmojiSkinTone.load(defaults: defaults), .standard)
        EmojiSkinTone.mediumDark.save(defaults: defaults)
        XCTAssertEqual(EmojiSkinTone.load(defaults: defaults), .mediumDark)
        defaults.set("unexpected", forKey: EmojiSkinTone.settingsKey)
        XCTAssertEqual(EmojiSkinTone.load(defaults: defaults), .standard)
    }
}
