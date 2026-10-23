import XCTest
import UIKit
@testable import Sumire

/// Real UIKit text inputs; these are not cross-process UITextDocumentProxy tests.
@MainActor
final class RawSpaceCommitTests: XCTestCase {
    func testRawTextReplacesConvertedMarkAndCommitsTailBeforeCaret() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            for (left, tail) in [("あい", "😀z"), ("", "abc"), ("か\u{3099}👩‍💻", "尾"), ("n", ""), ("", "")] {
                input.replace(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!, withText: "前後")
                let middle = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 1))
                input.selectedTextRange = input.textRange(from: middle, to: middle)
                input.setMarkedText("変換候補", selectedRange: NSRange(location: 2, length: 0))
                XCTAssertNotNil(input.markedTextRange)
                apply(input, left: left, tail: tail)
                XCTAssertEqual(contents(input), "前" + left + " " + tail + "後")
                XCTAssertNil(input.markedTextRange)
                let selection = try XCTUnwrap(input.selectedTextRange)
                XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start), 1 + left.utf16.count + 1)
                XCTAssertTrue(selection.isEmpty)
            }
        }
    }

    func testNoMarkSelectionReplacementAndRepeatedSpaces() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            input.insertText("前選択後")
            let start = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 1))
            let end = try XCTUnwrap(input.position(from: start, offset: 2))
            input.selectedTextRange = input.textRange(from: start, to: end)
            apply(input, left: "raw", tail: "尾")
            XCTAssertEqual(contents(input), "前raw 尾後")
            XCTAssertNil(input.markedTextRange)
            apply(input, left: "", tail: "")
            XCTAssertEqual(contents(input), "前raw  尾後")
        }
    }

    func testCaretDoesNotAssumeAcceptedTailLength() throws {
        let input = ExpandingTailTextView()
        input.setMarkedText("変換候補", selectedRange: NSRange(location: 4, length: 0))
        apply(input, left: "raw", tail: "😀")
        XCTAssertEqual(contents(input), "raw 尾尾尾")
        let selection = try XCTUnwrap(input.selectedTextRange)
        XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start), 4)
        XCTAssertNil(input.markedTextRange)
    }

    private func apply(_ input: UITextInput, left: String, tail: String) {
        Sumire.RawSpaceCommit.apply(left: left, tail: tail,
            setMarked: { input.setMarkedText($0, selectedRange: $1) },
            unmark: { input.unmarkText() }, insert: { input.insertText($0) })
    }
    private func contents(_ input: UITextInput) -> String? {
        input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!)
    }
    private final class ExpandingTailTextView: UITextView {
        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            super.setMarkedText(markedText == "😀" ? "尾尾尾" : markedText, selectedRange: selectedRange)
        }
    }
}
