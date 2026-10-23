import XCTest
import SumireCore
@testable import Sumire

final class PersonalTextMacroEditorRecoveryTests: XCTestCase {
    func testMalformedExistingBodyStartsInSourceMode() throws {
        let malformedBody = "{date:"
        let parsed = try? AndroidTextMacroEditorDocument.parse(malformedBody)

        XCTAssertNil(parsed)
        XCTAssertEqual(TextMacroEditorMode.initial(for: parsed), .source)
    }

    func testValidExistingBodyStartsInBlocksMode() throws {
        let parsed = try AndroidTextMacroEditorDocument.parse("hello {date:yyyy}")

        XCTAssertEqual(TextMacroEditorMode.initial(for: parsed), .blocks)
    }

    func testFailedBlocksSwitchPreservesMalformedSourceInsteadOfEmptyPlaceholder() {
        let originalBody = "{date:"
        let recoveryPlaceholder: [AndroidTextMacroEditorBlock] = [.text("")]

        XCTAssertEqual(
            TextMacroEditorMode.sourceAfterLeavingBlocks(
                currentBody: originalBody,
                blocks: recoveryPlaceholder
            ),
            originalBody
        )
    }

    func testLeavingBlocksUsesTheLatestValidBlockContent() {
        let changedBlocks: [AndroidTextMacroEditorBlock] = [.text("repaired"), .token(name: "cursor")]

        XCTAssertEqual(
            TextMacroEditorMode.sourceAfterLeavingBlocks(currentBody: "valid", blocks: changedBlocks),
            "repaired{cursor}"
        )
    }
}
