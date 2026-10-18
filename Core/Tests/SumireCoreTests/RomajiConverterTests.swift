import XCTest
@testable import SumireCore

final class RomajiConverterTests: XCTestCase {
    func type(_ text: String, _ c: RomajiConverter) -> String {
        text.reduce("") { c.convert($0 + String($1)) }
    }
    func testAll312AndroidMappings() throws {
        let rules = try RomajiConverter.standard().rules
        XCTAssertEqual(rules.count, 312)
        let c = RomajiConverter(rules: rules, autoSokuon: false, autoN: false)
        for (key, rule) in rules { XCTAssertEqual(c.convert(key), rule.first, key) }
    }
    func testIncrementalDeletionFlushAndUnicode() throws {
        let c = try RomajiConverter.standard()
        XCTAssertEqual(type("yappari", c), "やっぱり")
        XCTAssertEqual(type("gakkou", c), "がっこう")
        XCTAssertEqual(type("kanta", c), "かんた")
        XCTAssertEqual(type("nya", c), "にゃ")
        XCTAssertEqual(type("xtsu", c), "っ")
        XCTAssertEqual(c.flush(type("kan", c)), "かん")
        XCTAssertEqual(c.convert("😀が👨‍👩‍👧‍👦"), "😀が👨‍👩‍👧‍👦")
        XCTAssertEqual(c.convert("pｐ"), "っｐ")
        XCTAssertEqual(c.convert("ｎk"), "んk")
        XCTAssertEqual(c.flush("N"), "N")
    }
    func testLegacyConsumptionAlwaysMakesProgress() {
        for n in [Int.min, -1, 0, 1, Int.max] {
            XCTAssertEqual(RomajiConverter(rules: ["a": .init("あ", n)]).convert("!a"), "!あ")
        }
    }
    func testAndroidImportDefaultsAndSettings() throws {
        let json = #"[{"name":"custom","mapData":{"pp":{"first":"★","second":2}},"autoSokuon":false,"autoN":false}]"#
        let map = try JSONDecoder().decode([RomajiMap].self, from: Data(json.utf8))[0]
        XCTAssertFalse(map.autoN)
        XCTAssertFalse(map.autoSokuon)
        XCTAssertTrue(map.isDeletable)
        XCTAssertEqual(RomajiConverter(rules: map.mapData, autoSokuon: map.autoSokuon, autoN: map.autoN).convert("pp"), "★")
    }
}
