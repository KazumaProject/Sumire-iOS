import XCTest
@testable import SumireCore

final class DeletionBoundaryTests: XCTestCase {
    func testBoundariesAndUnicode() {
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前。単語", symbols: DeletionBoundary.defaultSymbols), 2)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前。", symbols: DeletionBoundary.defaultSymbols), 1)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前/単語", symbols: "/"), 2)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前 👩‍💻か\u{3099}", symbols: ""), 2)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前\n", symbols: ""), 1)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "前\t", symbols: ""), 0)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: "", symbols: ""), 0)
        XCTAssertEqual(DeletionBoundary.backwardCount(context: String(repeating: "あ", count: 500), symbols: ""), 100)
    }
}
