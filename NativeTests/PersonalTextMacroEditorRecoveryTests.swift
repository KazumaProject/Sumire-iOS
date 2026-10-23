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
}
