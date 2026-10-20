import XCTest
@testable import SumireCore

final class CustomCharacterModifierTests: XCTestCase {
    func testEveryAsciiLetterTogglesBidirectionally() {
        for scalar in UInt32(65)...90 {
            let upper = Character(String(UnicodeScalar(scalar)!)), lower = Character(String(UnicodeScalar(scalar + 32)!))
            XCTAssertEqual(CustomCharacterModifier.modified(upper), lower)
            XCTAssertEqual(CustomCharacterModifier.modified(lower), upper)
        }
    }
    func testHiraganaCyclesMatchPinnedGetDakutenSmallChar() {
        for group in ["あぁ", "いぃ", "うぅゔ", "えぇ", "おぉ", "かが", "きぎ", "くぐ", "けげ", "こご",
                      "さざ", "しじ", "すず", "せぜ", "そぞ", "ただ", "ちぢ", "つっづ", "てで", "とど",
                      "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ", "やゃ", "ゆゅ", "よょ", "わゎ"] {
            let characters = Array(group)
            for index in characters.indices {
                XCTAssertEqual(CustomCharacterModifier.modified(characters[index]), characters[(index + 1) % characters.count])
            }
        }
    }
    func testUnsupportedAndDecomposedCharactersAreNotNormalized() {
        for character: Character in ["ア", "Ａ", "é", "a\u{301}", "か\u{3099}", "👩‍💻", "🇯🇵", ".", "な"] {
            XCTAssertNil(CustomCharacterModifier.modified(character), String(character))
        }
    }
    func testTapAndFlickDecodeAsCommandsWithoutSubstitutingText() {
        let targets = CustomLayoutTargets(layouts: [])
        XCTAssertEqual(CustomKeyAction.tap("a/A", targets: targets), .command(.toggleCase))
        XCTAssertEqual(CustomKeyAction.flick(type: "TOGGLE_CASE", value: nil, targets: targets), .command(.toggleCase))
        XCTAssertEqual(CustomKeyAction.tap("小゛゜", targets: targets), .command(.modifier))
        guard case .unsupported = CustomKeyAction.tap("unrecognized-case-command", targets: targets) else { return XCTFail("Unknown action must remain unsupported") }
    }
}
