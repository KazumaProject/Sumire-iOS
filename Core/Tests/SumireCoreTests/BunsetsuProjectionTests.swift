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
    func testUTF16AndUnicodeScalarBoundaries() throws {
        let emoji = BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "😀")
        let a = BunsetsuToken(readingRange: NSRange(location: 2, length: 1), text: "亜")
        let result = try BunsetsuProjection.project(reading: "😀あ", candidate: "😀亜", tokens: [emoji, a], boundaries: [2])
        XCTAssertEqual(result.map(\.reading), ["😀", "あ"])
        XCTAssertEqual(BunsetsuProjection.firstReadingPrefix(in: result, reading: "😀あ"), "😀")
        let decomposed = [BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: "A"), BunsetsuToken(readingRange: NSRange(location: 1, length: 1), text: "B")]
        let splitCombiningSequence = try BunsetsuProjection.project(
            reading: "か\u{3099}", candidate: "AB", tokens: decomposed, boundaries: [1]
        )
        XCTAssertEqual(splitCombiningSequence.map(\.reading), ["か", "\u{3099}"])
        XCTAssertEqual(BunsetsuProjection.firstReadingPrefix(in: splitCombiningSequence, reading: "か\u{3099}"), "か")
        XCTAssertThrowsError(try BunsetsuProjection.projectReadingOnly(reading: "😀あ", boundaries: [1]))
    }

    func testProjectionIdentityChecksUseExactUTF16CodeUnits() throws {
        let composed = "\u{00C5}"
        let canonicallyEquivalent = "\u{212B}"
        XCTAssertEqual(composed, canonicallyEquivalent)
        XCTAssertNotEqual(Array(composed.utf16), Array(canonicallyEquivalent.utf16))

        let tokenRange = NSRange(location: 0, length: 1)
        XCTAssertThrowsError(try BunsetsuProjection.project(
            reading: "あ",
            candidate: composed,
            tokens: [BunsetsuToken(readingRange: tokenRange, text: canonicallyEquivalent)],
            boundaries: []
        ))
        XCTAssertThrowsError(try BunsetsuProjection.projectWithReadingFallback(
            reading: "あ",
            candidate: composed,
            tokens: [BunsetsuToken(readingRange: tokenRange, text: canonicallyEquivalent)],
            boundaries: []
        ))

        let canonicallyEquivalentReading = BunsetsuCandidatePath(
            reading: canonicallyEquivalent,
            candidate: "A",
            tokens: [BunsetsuToken(readingRange: tokenRange, text: "A")]
        )
        XCTAssertNil(try BunsetsuProjection.selectCoherentCandidatePath(
            reading: composed,
            boundaries: [],
            candidates: [canonicallyEquivalentReading]
        ))

        let canonicallyEquivalentSurface = BunsetsuCandidatePath(
            reading: "あ",
            candidate: composed,
            tokens: [BunsetsuToken(readingRange: tokenRange, text: canonicallyEquivalent)]
        )
        XCTAssertNil(try BunsetsuProjection.selectCoherentCandidatePath(
            reading: "あ",
            boundaries: [],
            candidates: [canonicallyEquivalentSurface]
        ))
    }

    func testReadingOnlyProjectionKeepsIntervalsSelectableWithoutAWholePath() throws {
        let result = try BunsetsuProjection.projectReadingOnly(
            reading: "😀あいう",
            boundaries: [2, 3]
        )

        XCTAssertEqual(result.map(\.reading), ["😀", "あ", "いう"])
        XCTAssertEqual(result.map(\.text), ["😀", "あ", "いう"])
        XCTAssertEqual(result.map(\.readingRange), [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 1),
            NSRange(location: 3, length: 2)
        ])
        XCTAssertTrue(result.allSatisfy { !$0.hasConvertedDisplay })
        XCTAssertEqual(try BunsetsuProjection.projectReadingOnly(reading: "", boundaries: []), [])
        let decomposedReading = "か\u{3099}き"
        let scalarSplit = try BunsetsuProjection.projectReadingOnly(reading: decomposedReading, boundaries: [1, 2])
        XCTAssertEqual(scalarSplit.map(\.reading), ["か", "\u{3099}", "き"])
        XCTAssertEqual(scalarSplit.map(\.readingRange), [
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 1),
            NSRange(location: 2, length: 1)
        ])
        XCTAssertEqual(scalarSplit.map(\.reading).joined(), decomposedReading)
    }

    func testPathSelectionPrefersFirstCoherentPathThatCoversEveryBoundary() throws {
        let reading = "あいうえ"
        let firstButUnaligned = BunsetsuCandidatePath(
            reading: reading,
            candidate: "明後日",
            tokens: [BunsetsuToken(readingRange: NSRange(location: 0, length: 4), text: "明後日")]
        )
        let invalidGap = BunsetsuCandidatePath(
            reading: reading,
            candidate: "不正",
            tokens: [
                BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: "不"),
                BunsetsuToken(readingRange: NSRange(location: 2, length: 2), text: "正")
            ]
        )
        let boundaryAligned = BunsetsuCandidatePath(
            reading: reading,
            candidate: "明日",
            tokens: [
                BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "明"),
                BunsetsuToken(readingRange: NSRange(location: 2, length: 2), text: "日")
            ]
        )

        XCTAssertEqual(
            try BunsetsuProjection.selectCoherentCandidatePath(
                reading: reading,
                boundaries: [2],
                candidates: [firstButUnaligned, invalidGap, boundaryAligned]
            ),
            boundaryAligned
        )
        XCTAssertEqual(
            try BunsetsuProjection.selectCoherentCandidatePath(
                reading: reading,
                boundaries: [1],
                candidates: [firstButUnaligned, invalidGap]
            ),
            firstButUnaligned
        )
        XCTAssertNil(try BunsetsuProjection.selectCoherentCandidatePath(
            reading: reading,
            boundaries: [2],
            candidates: [invalidGap]
        ))

        let staleSameLength = BunsetsuCandidatePath(
            reading: "おいうえ",
            candidate: "明日",
            tokens: boundaryAligned.tokens
        )
        XCTAssertNil(try BunsetsuProjection.selectCoherentCandidatePath(
            reading: reading,
            boundaries: [2],
            candidates: [staleSameLength]
        ))
    }

    func testFirstReadingPrefixRequiresARealLeadingSplit() throws {
        let whole = try BunsetsuProjection.project(reading: "きょう", candidate: "今日", tokens: [
            BunsetsuToken(readingRange: NSRange(location: 0, length: 3), text: "今日")], boundaries: [])
        XCTAssertNil(BunsetsuProjection.firstReadingPrefix(in: whole, reading: "きょう"))
        XCTAssertNil(BunsetsuProjection.firstReadingPrefix(in: [], reading: "きょう"))
    }
}
