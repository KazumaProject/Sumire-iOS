import XCTest
@testable import SumireCore

final class AndroidTextMacroEditorDocumentTests: XCTestCase {
    func testMoveEditDeleteAndLiteralBraceRoundTrip() throws {
        let parsed = try AndroidTextMacroEditorDocument.parse("A{{B}}{date:yyyy}{newline}C")
        XCTAssertEqual(parsed.blocks.count, 4)

        let changed = try parsed
            .moved(from: 2, to: 1)
            .replacing(at: 2, with: .token(name: "time", argument: "HH:mm"))
            .removing(at: 3)
            .adding(.token(name: "cursor"))

        XCTAssertEqual(changed.toSource(), "A{{B}}{newline}{time:HH:mm}{cursor}")
        XCTAssertNoThrow(try AndroidTextMacroCompiler.compile(changed.toSource()))
    }

    func testInvalidReplacementAndRemovalAreExplicitErrors() throws {
        let document = AndroidTextMacroEditorDocument(blocks: [.text("text")])
        XCTAssertThrowsError(try document.replacing(at: 1, with: .text("ignored")))
        XCTAssertThrowsError(try document.removing(at: -1))
    }

    func testAddClampsInsertionIndexLikeAndroidEditorDocument() {
        let document = AndroidTextMacroEditorDocument(blocks: [.text("a")])
        XCTAssertEqual(document.adding(.text("b"), at: -3).toSource(), "ba")
        XCTAssertEqual(document.adding(.text("c"), at: 9).toSource(), "ac")
    }
}
