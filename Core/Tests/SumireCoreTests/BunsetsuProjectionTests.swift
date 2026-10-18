import XCTest
@testable import SumireCore

final class BunsetsuProjectionTests: XCTestCase {
    private let tokens = [
        BunsetsuToken(readingRange: NSRange(location: 0, length: 3), text: "今日"),
        BunsetsuToken(readingRange: NSRange(location: 3, length: 1), text: "は"),
        BunsetsuToken(readingRange: NSRange(location: 4, length: 5), text: "東京"),
        BunsetsuToken(readingRange: NSRange(location: 9, length: 1), text: "に"),
        BunsetsuToken(readingRange: NSRange(location: 10, length: 4), text: "行きます")]
    func testWholePathProjectionAndSelectionPreserveOtherSegments() throws {
        let result = try BunsetsuProjection.project(reading: "きょうはとうきょうにいきます", candidate: "今日は東京に行きます", tokens: tokens, boundaries: [4, 10])
        XCTAssertEqual(result.map(\.text), ["今日は", "東京に", "行きます"])
        XCTAssertEqual(result.map(\.reading), ["きょうは", "とうきょうに", "いきます"])
        XCTAssertEqual(BunsetsuProjection.firstReadingPrefix(in: result, reading: "きょうはとうきょうにいきます"), "きょうは")
        var selection = BunsetsuSelection(segments: result)
        try selection.select(2)
        XCTAssertEqual(selection.alternatives(["生きます", "行きます", "生きます"]), ["行きます", "生きます"])
        try selection.replaceSelected(text: "生きます")
        XCTAssertEqual(selection.text, "今日は東京に生きます")
        XCTAssertEqual(selection.selectedReadingRange, NSRange(location: 10, length: 4))
        XCTAssertThrowsError(try selection.select(3))
        XCTAssertEqual(selection.selectedIndex, 2)
    }
    func testRejectInvalidOrIncompatiblePathsAndBoundaries() {
        for boundaries in [[1], [4, 4], [10, 4], [0], [14], [-1], [Int.max]] {
            XCTAssertThrowsError(try BunsetsuProjection.project(reading: "きょうはとうきょうにいきます", candidate: "今日は東京に行きます", tokens: tokens, boundaries: boundaries))
        }
        XCTAssertThrowsError(try BunsetsuProjection.project(reading: "きょうはとうきょうにいきます", candidate: "別の候補", tokens: tokens, boundaries: [4]))
        XCTAssertThrowsError(try BunsetsuProjection.project(reading: "あ", candidate: "A", tokens: [BunsetsuToken(readingRange: NSRange(location: 0, length: Int.max), text: "A")], boundaries: []))
    }
    func testUTF16AndGraphemeBoundaries() throws {
        let emoji = BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "😀")
        let a = BunsetsuToken(readingRange: NSRange(location: 2, length: 1), text: "亜")
        let result = try BunsetsuProjection.project(reading: "😀あ", candidate: "😀亜", tokens: [emoji, a], boundaries: [2])
        XCTAssertEqual(result.map(\.reading), ["😀", "あ"])
        XCTAssertEqual(BunsetsuProjection.firstReadingPrefix(in: result, reading: "😀あ"), "😀")
        let decomposed = [BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: "A"), BunsetsuToken(readingRange: NSRange(location: 1, length: 1), text: "B")]
        XCTAssertThrowsError(try BunsetsuProjection.project(reading: "か\u{3099}", candidate: "AB", tokens: decomposed, boundaries: [1]))
    }

    func testFirstReadingPrefixRequiresARealLeadingSplit() throws {
        let whole = try BunsetsuProjection.project(reading: "きょう", candidate: "今日", tokens: [
            BunsetsuToken(readingRange: NSRange(location: 0, length: 3), text: "今日")], boundaries: [])
        XCTAssertNil(BunsetsuProjection.firstReadingPrefix(in: whole, reading: "きょう"))
        XCTAssertNil(BunsetsuProjection.firstReadingPrefix(in: [], reading: "きょう"))
    }
}
