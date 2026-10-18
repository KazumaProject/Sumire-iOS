import XCTest
import UIKit
import SumireCore

/// UIKit host behavior used by the extension's insertText-based commit.
/// These checks do not replace cross-process UITextDocumentProxy UI tests.
@MainActor
final class MarkedTextCommitTests: XCTestCase {
    func testComposingCursorRetainsMarkedRangeInBothHosts() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var state = CompositionState()
            state.append("あ👩‍💻い")
            func render() {
                input.setMarkedText(state.reading, selectedRange: NSRange(location: state.cursorUTF16, length: 0))
            }
            render()
            state.moveCursor(by: -1); render()
            XCTAssertNotNil(input.markedTextRange)
            let selection = try XCTUnwrap(input.selectedTextRange)
            XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start), "あ👩‍💻".utf16.count)
            state.append("か"); render()
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertEqual(contents(input), "あ👩‍💻かい")
            state.deleteBackward(); render()
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertEqual(contents(input), "あ👩‍💻い")
        }
    }

    func testTextFieldMarkedCommitAndCursorInsertion() throws {
        try verifyCommit(UITextField())
    }

    func testTextViewMarkedCommitAndCursorInsertion() throws {
        try verifyCommit(UITextView())
    }

    private func verifyCommit(_ input: UIView & UITextInput) throws {
        input.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(contents(input), "あ")
        XCTAssertNotNil(input.markedTextRange)
        input.insertText("亜")
        XCTAssertEqual(contents(input), "亜")
        XCTAssertNil(input.markedTextRange)
        for candidate in ["愛", "か\u{3099}", "👨‍👩‍👧‍👦"] {
            let full = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!
            input.replace(full, withText: "前後")
            let middle = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 1))
            input.selectedTextRange = input.textRange(from: middle, to: middle)
            input.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(input.markedTextRange)
            input.insertText(candidate)
            XCTAssertNil(input.markedTextRange)
            XCTAssertEqual(contents(input), "前" + candidate + "後")
            let selection = try XCTUnwrap(input.selectedTextRange)
            XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start),
                           1 + candidate.utf16.count)
            // Move across the whole preceding grapheme, as the extension does.
            let before = try XCTUnwrap(input.position(from: selection.start, offset: -candidate.utf16.count))
            input.selectedTextRange = input.textRange(from: before, to: before)
            input.insertText("挿")
            XCTAssertEqual(contents(input), "前挿" + candidate + "後")
        }
    }

    private func contents(_ input: UITextInput) -> String? {
        guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else { return nil }
        return input.text(in: range)
    }
}
