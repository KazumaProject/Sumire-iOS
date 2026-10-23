#if DEBUG
import XCTest
import UIKit
@testable import Sumire

@MainActor
final class MarkedDocumentOwnershipTests: XCTestCase {
    private typealias Context = Sumire.MarkedDocumentOwnership.Context
    private func context(_ input: UITextInput, document: String?) throws -> Context {
        let selection = try XCTUnwrap(input.selectedTextRange)
        let before = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: selection.start))
        let after = try XCTUnwrap(input.textRange(from: selection.end, to: input.endOfDocument))
        return Context(document: document, before: input.text(in: before), after: input.text(in: after),
                       selected: selection.isEmpty ? nil : input.text(in: selection))
    }
    private func mark(_ text: String, in input: UITextInput, document: String,
                      owner: inout Sumire.MarkedDocumentOwnership) throws {
        let before = try context(input, document: document)
        input.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        owner.recordMark(before: before, after: try context(input, document: document), isEmpty: text.isEmpty)
    }
    func testSameDocumentHidePreservesTextAndConsumesBeforeReentry() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("か\u{3099}👩‍💻", in: input, document: "A", owner: &owner)
            let current = try context(input, document: "A")
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertTrue(owner.consumeIfMatching(current))
            XCTAssertFalse(owner.consumeIfMatching(current)) // Reentrant/repeated hide must not act twice.
            input.unmarkText()
            XCTAssertNil(input.markedTextRange)
            let all = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
            XCTAssertEqual(input.text(in: all), "か\u{3099}👩‍💻")
        }
    }
    func testSwitchingDocumentNeverUnmarksOtherEditorsComposition() throws {
        let first = UITextField(), second = UITextView()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: first, document: "A", owner: &owner)
        second.setMarkedText("別の未確定", selectedRange: NSRange(location: 2, length: 0))
        if owner.consumeIfMatching(try context(second, document: "B")) { second.unmarkText() }
        XCTAssertNotNil(second.markedTextRange)
        XCTAssertFalse(owner.consumeIfMatching(try context(first, document: "A")))
    }
    func testExternalSelectionOrTextChangesRejectOwnership() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あいう", in: input, document: "A", owner: &owner)
            let start = input.beginningOfDocument
            input.selectedTextRange = input.textRange(from: start, to: start)
            XCTAssertFalse(owner.consumeIfMatching(try context(input, document: "A")))
            try mark("あ", in: input, document: "A", owner: &owner)
            input.setMarkedText("外部", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertFalse(owner.consumeIfMatching(try context(input, document: "A")))
            XCTAssertNotNil(input.markedTextRange)
        }
    }
    func testDisconnectedCommittedAndEmptyMarksCannotFinalizeForeignText() throws {
        let input = UITextView()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        XCTAssertFalse(owner.consumeIfMatching(try context(input, document: nil)))
        try mark("あ", in: input, document: "A", owner: &owner)
        owner.discard()
        input.insertText("亜")
        input.setMarkedText("別", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertFalse(owner.consumeIfMatching(try context(input, document: "A")))
        try mark("", in: input, document: "A", owner: &owner)
        XCTAssertFalse(owner.consumeIfMatching(try context(input, document: "A")))
    }
}
#endif
