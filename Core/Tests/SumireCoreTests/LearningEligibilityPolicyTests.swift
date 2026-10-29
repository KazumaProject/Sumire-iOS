import XCTest
@testable import SumireCore

final class LearningEligibilityPolicyTests: XCTestCase {
    func testKotlinBlankInputAndOutputIncludingNonBreakingSpaces() {
        for blank in ["", " \t\n", "\u{001C}\u{001F}", "\u{3000}", "\u{2028}", "\u{00A0}", "\u{2007}", "\u{202F}"] {
            XCTAssertFalse(eligible(blank, "語", allowMixed: true), "input \(Array(blank.utf16))")
            XCTAssertFalse(eligible("ご", blank, allowMixed: true), "output \(Array(blank.utf16))")
        }
    }

    func testPureNumbersAndBmpSymbolsAreExcludedForBothSettings() {
        for output in ["123", "①②Ⅻ", "。！？", "++", "$", "☀", "１２３"] {
            for allow in [false, true] {
                XCTAssertFalse(eligible("よみ", output, allowMixed: allow), output)
            }
        }
    }

    func testMixedLetterPhrasesRequireMixedSetting() {
        for output in ["令和8年", "C++入門", "あ！", "A1", "漢☀"] {
            XCTAssertFalse(eligible("よみ", output, allowMixed: false), output)
            XCTAssertTrue(eligible("よみ", output, allowMixed: true), output)
        }
    }

    func testPlainWordsAndOutputOnlyClassification() {
        for output in ["言葉", "abc", "かな", "カナ"] {
            XCTAssertTrue(eligible("よみ", output, allowMixed: false), output)
        }
        XCTAssertTrue(eligible("123!", "言葉", allowMixed: false))
        XCTAssertTrue(eligible("よみ", "\u{200B}", allowMixed: false))
    }

    func testSupplementaryCharactersUseAndroidCharClassification() {
        // Android iterates UTF-16 Char values: these surrogate pairs are not
        // classified as a symbol or a letter by the pinned implementation.
        XCTAssertTrue(eligible("えもじ", "😀", allowMixed: false))
        XCTAssertFalse(eligible("よみ", "𠮷!", allowMixed: true))
        XCTAssertTrue(eligible("よみ", "𠮷", allowMixed: false))
    }

    private func eligible(_ input: String, _ output: String, allowMixed: Bool) -> Bool {
        LearningEligibilityPolicy.isEligible(input: input, output: output,
            allowJapaneseWithSymbolsAndNumbers: allowMixed)
    }
}
