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
