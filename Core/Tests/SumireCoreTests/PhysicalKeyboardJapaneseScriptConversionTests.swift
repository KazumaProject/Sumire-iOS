import XCTest
@testable import SumireCore

final class PhysicalKeyboardJapaneseScriptConversionTests: XCTestCase {
    func testASCIIEnglishLettersConvertThroughRomajiMapBeforeF6ToF8() throws {
        let converter = try RomajiConverter.standard()

        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("kana", using: converter), "かな")
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("KANA", using: converter), "かな")
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("KANTA", using: converter), "かnた")
    }

    func testEditableMapUsesAndroidNRuleEvenWhenTypingOptionIsDisabled() throws {
        let standard = try RomajiConverter.standard()
        let profile = RomajiProfile(
            name: "カスタム",
            rules: standard.rules,
            ruleOrder: standard.ruleOrder,
            autoN: false
        )

        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("KANTA", using: profile.converter), "かんた")
    }

    func testProtectedProfileUsesAndroidDefaultMapConversionBranch() throws {
        let standard = try RomajiConverter.standard()
        let profile = RomajiProfile(
            name: "保護された既定表",
            rules: standard.rules,
            ruleOrder: standard.ruleOrder,
            isDeletable: false
        )

        XCTAssertTrue(profile.converter.isDefaultMap)
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("KANTA", using: profile.converter), "かnた")
    }

    func testMixedTextAndNonASCIIInputAreNotTransliteratedAsRomaji() throws {
        let converter = try RomajiConverter.standard()

        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("kana!", using: converter), "kana!")
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("かなABC", using: converter), "かなABC")
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("", using: converter), "")
    }

    func testASCIIInputWithoutConverterIsPreserved() {
        XCTAssertEqual(
            PhysicalKeyboardJapaneseScriptConversion.source("kana", using: nil), "kana")
    }
}
