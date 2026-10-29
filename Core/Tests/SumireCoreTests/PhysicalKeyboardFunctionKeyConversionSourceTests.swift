import XCTest
@testable import SumireCore

final class PhysicalKeyboardFunctionKeyConversionSourceTests: XCTestCase {
    func testChainedFunctionKeysReuseOriginalPrefixAcrossGenerations() {
        var source = PhysicalKeyboardFunctionKeyConversionSource()

        XCTAssertEqual(source.source(for: "かな", generation: 3), "かな")
        source.record(output: "kana", generation: 4)

        XCTAssertEqual(source.source(for: "kana", generation: 4), "かな")
        source.record(output: "ｋａｎａ", generation: 5)

        XCTAssertEqual(source.source(for: "ｋａｎａ", generation: 5), "かな")
    }

    func testAnyNonConversionCompositionChangeStartsANewSource() {
        var source = PhysicalKeyboardFunctionKeyConversionSource()

        XCTAssertEqual(source.source(for: "かな", generation: 3), "かな")
        source.record(output: "kana", generation: 4)

        XCTAssertEqual(source.source(for: "kanai", generation: 5), "kanai")
        source.record(output: "kanai", generation: 6)
        XCTAssertEqual(source.source(for: "kanai", generation: 6), "kanai")
    }

    func testExplicitResetStartsANewSourceEvenWhenOutputAndGenerationMatch() {
        var source = PhysicalKeyboardFunctionKeyConversionSource()

        XCTAssertEqual(source.source(for: "かな", generation: 3), "かな")
        source.record(output: "kana", generation: 4)
        source.reset()

        XCTAssertEqual(source.source(for: "kana", generation: 4), "kana")
    }
}
