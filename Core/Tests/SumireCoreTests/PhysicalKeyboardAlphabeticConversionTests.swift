import XCTest
@testable import SumireCore

final class PhysicalKeyboardAlphabeticConversionTests: XCTestCase {
    private func converter() throws -> RomajiConverter {
        try RomajiConverter.standard()
    }

    func testASCIIOnlyInputIsLowercasedBeforeWidthConversion() throws {
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ROMAJI", to: .full, using: try converter()),
            "ｒｏｍａｊｉ"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ROMAJI", to: .half, using: nil),
            "romaji"
        )
    }

    func testKanaWithoutConverterFallsBackToOriginalSource() {
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("かな", to: .full, using: nil),
            "かな"
        )
    }

    func testKatakanaAndHalfWidthVoicedKanaReverseThroughActiveMap() throws {
        let converter = try converter()
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ガッコウ", to: .full, using: converter),
            "ｇａｋｋｏｕ"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ｶﾞｯｺｳ", to: .half, using: converter),
            "gakkou"
        )
    }

    func testLongestKanaMatchAndShortestAliasAreUsed() throws {
        let converter = RomajiConverter(rules: [
            "kya": .init("きゃ", 3),
            "ki": .init("き", 2),
            "xya": .init("ゃ", 3),
            "aa": .init("あ", 2),
            "a": .init("あ", 1)
        ])
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("きゃあ", to: .half, using: converter),
            "kyaa"
        )
    }

    func testSmallTsuAndLongVowelFollowPinnedAndroidRules() throws {
        let converter = try converter()
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("がっこう", to: .half, using: converter),
            "gakkou"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ラーメン", to: .half, using: converter),
            "raamenn"
        )
    }

    func testOnlyASCIIEnglishLettersUseLowercaseFastPath() throws {
        let converter = try converter()
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ROMAJI TEST", to: .full, using: converter),
            "ＲＯＭＡＪＩ　ＴＥＳＴ"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("かなABC", to: .half, using: converter),
            "canaABC"
        )
    }

    func testWidthChangePreservesNonAlphabeticCharactersAndUnknownKana() throws {
        let converter = try converter()
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("かな 1!漢字🙂", to: .full, using: converter),
            "ｃａｎａ　1!漢字🙂"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("漢字🙂", to: .half, using: converter),
            "漢字🙂"
        )
    }

    func testAndroidDefaultAliasOrderAndSmallTsuFallback() throws {
        let converter = try converter()
        // Android's Room map preserves insertion order; ca precedes ka in the
        // pinned default map and hu precedes fu for ふ.
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("かな", to: .half, using: converter),
            "cana"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: converter),
            "hu"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: converter),
            "ｈｕ"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("っあ", to: .half, using: converter),
            "aa"
        )
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("っ", to: .half, using: converter),
            "っ"
        )
    }

    func testCustomEqualLengthAliasOrderControlsF9AndF10Romaji() {
        let rules: [String: RomajiRule] = [
            "hu": .init("ふ", 2),
            "fu": .init("ふ", 2)
        ]
        let huFirst = RomajiConverter(rules: rules, ruleOrder: ["hu", "fu"])
        let fuFirst = RomajiConverter(rules: rules, ruleOrder: ["fu", "hu"])

        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: huFirst), "hu")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: huFirst), "ｈｕ")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: fuFirst), "fu")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: fuFirst), "ｆｕ")
    }

    func testImportedAndroidAliasOrderFlowsIntoF9AndF10Conversions() throws {
        let huFirstJSON = Data(
            #"[{"name":"hu-first","mapData":{"hu":{"first":"ふ","second":2},"fu":{"first":"ふ","second":2}}}]"#.utf8
        )
        let fuFirstJSON = Data(
            #"[{"name":"fu-first","mapData":{"fu":{"first":"ふ","second":2},"hu":{"first":"ふ","second":2}}}]"#.utf8
        )
        let huFirst = try XCTUnwrap(RomajiLibrary.importAndroid(huFirstJSON).first).converter
        let fuFirst = try XCTUnwrap(RomajiLibrary.importAndroid(fuFirstJSON).first).converter

        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: huFirst), "hu")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: huFirst), "ｈｕ")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: fuFirst), "fu")
        XCTAssertEqual(PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: fuFirst), "ｆｕ")
    }

    func testEmptyInputRemainsEmpty() throws {
        XCTAssertEqual(
            PhysicalKeyboardAlphabeticConversion.convert("", to: .full, using: try converter()),
            ""
        )
    }
}
