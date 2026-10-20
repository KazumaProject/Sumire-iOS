import XCTest
@testable import SumireCore

final class CompositionRawSpaceTests: XCTestCase {
    func testRawSplitAtStartMiddleAndEndClearsWholeComposition() {
        for (cursor, left, tail) in [(0, "", "あいう"), (1, "あ", "いう"), (3, "あいう", "")] {
            var state = CompositionState(); state.append("あいう")
            XCTAssertTrue(state.moveCursor(by: cursor - 3))
            state.select()
            let generation = state.generation
            let result = state.commitRawAtCursorAndSpace()
            XCTAssertEqual(result.left, left); XCTAssertEqual(result.tail, tail)
            XCTAssertEqual(state.reading, ""); XCTAssertEqual(state.cursor, 0)
            XCTAssertEqual(state.phase, .committed)
            XCTAssertEqual(state.generation, generation + 1)
            XCTAssertFalse(state.accepts(generation))
            XCTAssertFalse(state.accepts(state.generation))
        }
    }
    func testSplitUsesWholeGraphemesIncludingSupplementaryAndCombiningText() {
        let graphemes = ["👩‍💻", "か\u{3099}", "🇯🇵", "い"]
        for cursor in 0...graphemes.count {
            var state = CompositionState(); state.append(graphemes.joined())
            XCTAssertTrue(state.moveCursor(by: cursor - graphemes.count))
            let result = state.commitRawAtCursorAndSpace()
            XCTAssertEqual(result.left, graphemes.prefix(cursor).joined())
            XCTAssertEqual(result.tail, graphemes.dropFirst(cursor).joined())
            XCTAssertEqual(result.left + result.tail, graphemes.joined())
        }
    }
    func testPendingRomanInputRemainsRawAndSelectionDoesNotProvideSurface() {
        var state = CompositionState(); state.append("nあ")
        XCTAssertTrue(state.moveCursor(by: -1)); state.select()
        let result = state.commitRawAtCursorAndSpace()
        XCTAssertEqual(result.left, "n"); XCTAssertEqual(result.tail, "あ")
        XCTAssertEqual(state.reading, "")
    }
    func testRepeatedEmptyActionsInvalidateGenerationAndAllowFreshInput() {
        var state = CompositionState()
        for expected in UInt64(1)...3 {
            let result = state.commitRawAtCursorAndSpace()
            XCTAssertEqual(result.left, ""); XCTAssertEqual(result.tail, "")
            XCTAssertEqual(state.generation, expected)
            XCTAssertEqual(state.phase, .committed)
        }
        state.append("次")
        XCTAssertEqual(state.reading, "次"); XCTAssertEqual(state.cursor, 1)
        XCTAssertEqual(state.phase, .editing)
    }
}
