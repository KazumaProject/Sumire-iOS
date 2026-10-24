import XCTest
@testable import SumireCore

final class LearningEligibilityPolicyTests: XCTestCase {
    func testRejectsBlankInputAndOutputUsingAndroidWhitespaceRules() {
        for whitespace in ["", " \t\n", "\u{3000}", "\u{2028}"] {
            XCTAssertFalse(LearningEligibilityPolicy.isEligible(
                input: whitespace,
                output: "語",
                allowJapaneseWithSymbolsAndNumbers: true
            ))
            XCTAssertFalse(LearningEligibilityPolicy.isEligible(
                input: "ご",
                output: whitespace,
                allowJapaneseWithSymbolsAndNumbers: true
            ))
        }
        XCTAssertTrue(LearningEligibilityPolicy.isEligible(
            input: "ご",
            output: "\u{00A0}",
            allowJapaneseWithSymbolsAndNumbers: true
        ), "Java Character.isWhitespace does not classify NO-BREAK SPACE as whitespace")
    }

    func testMixedNumberAndSymbolPolicyRequiresAUnicodeLetterWhenEnabled() {
        XCTAssertTrue(LearningEligibilityPolicy.isEligible(
            input: "れいわ",
            output: "令和8年",
            allowJapaneseWithSymbolsAndNumbers: true
        ))
        XCTAssertFalse(LearningEligibilityPolicy.isEligible(
            input: "れいわ",
            output: "令和8年",
            allowJapaneseWithSymbolsAndNumbers: false
        ))
        XCTAssertTrue(LearningEligibilityPolicy.isEligible(
            input: "ぷらす",
            output: "C++入門",
            allowJapaneseWithSymbolsAndNumbers: true
        ))
        XCTAssertFalse(LearningEligibilityPolicy.isEligible(
            input: "ばんごう",
            output: "①②Ⅻ",
            allowJapaneseWithSymbolsAndNumbers: true
        ))
    }

    func testOnlyOutputClassificationControlsTheMixedContentRule() {
        XCTAssertTrue(LearningEligibilityPolicy.isEligible(
            input: "a+b",
            output: "語",
            allowJapaneseWithSymbolsAndNumbers: false
        ))
    }

    func testSupplementaryEmojiFollowsAndroidUtf16CharClassification() {
        XCTAssertTrue(LearningEligibilityPolicy.isEligible(
            input: "ねこ",
            output: "🐈",
            allowJapaneseWithSymbolsAndNumbers: false
        ), "Pinned Android helper iterates UTF-16 Char values, whose emoji surrogate halves are not symbols")
    }
}
