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
    private func contents(_ input: UITextInput) throws -> String? {
        let range = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        return input.text(in: range)
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
            XCTAssertEqual(owner.resolveOnHide(current), .unmarkOwnedText)
            XCTAssertEqual(owner.resolveOnHide(current), .none) // Reentrant/repeated hide must not act twice.
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
        XCTAssertEqual(owner.resolveOnAppearance(try context(second, document: "B")), .discardOwnership)
        XCTAssertNotNil(second.markedTextRange)
        XCTAssertEqual(owner.resolveOnHide(try context(first, document: "A")), .none)
    }
    func testExternalSelectionOrTextChangesRejectOwnership() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あいう", in: input, document: "A", owner: &owner)
            let start = input.beginningOfDocument
            input.selectedTextRange = input.textRange(from: start, to: start)
            XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .discardOwnership)
            try mark("あ", in: input, document: "A", owner: &owner)
            input.setMarkedText("外部", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .discardOwnership)
            XCTAssertNotNil(input.markedTextRange)
        }
    }
    func testDisconnectedCommittedAndEmptyMarksCannotFinalizeForeignText() throws {
        let input = UITextView()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let current = try context(input, document: "A")
        XCTAssertEqual(owner.resolveOnHide(Context(document: nil, before: current.before, after: current.after,
                                                   selected: current.selected)), .waitForDocument)
        XCTAssertEqual(owner.resolveCurrentContext(current), .unmarkOwnedText)
        input.unmarkText()
        XCTAssertNil(input.markedTextRange)
        XCTAssertEqual(try contents(input), "あ")
        try mark("あ", in: input, document: "A", owner: &owner)
        owner.discard()
        input.insertText("亜")
        input.setMarkedText("別", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .none)
        try mark("", in: input, document: "A", owner: &owner)
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .none)
    }

    func testDisconnectedMarkIsFinalizedBeforeResumedCompositionOnlyOnExactContext() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あ", in: input, document: "A", owner: &owner)
            let saved = try context(input, document: "A")
            let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                       selected: saved.selected)

            XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
            XCTAssertEqual(owner.resolveCurrentContext(disconnected), .waitForDocument)
            XCTAssertNotNil(input.markedTextRange)

            XCTAssertEqual(owner.resolveCurrentContext(saved), .unmarkOwnedText)
            input.unmarkText()
            XCTAssertNil(input.markedTextRange)
            XCTAssertEqual(try contents(input), "あ")

            input.setMarkedText("い", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertEqual(try contents(input), "あい")
            XCTAssertNotNil(input.markedTextRange)
        }
    }

    func testDisconnectedMarkIsDiscardedOnDifferentDocumentOrChangedContext() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あ", in: input, document: "A", owner: &owner)
            let saved = try context(input, document: "A")
            let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                       selected: saved.selected)
            XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
            XCTAssertEqual(owner.resolveCurrentContext(Context(document: "B", before: saved.before,
                                                                after: saved.after, selected: saved.selected)),
                           .discardOwnership)
            XCTAssertNotNil(input.markedTextRange)

            try mark("あ", in: input, document: "A", owner: &owner)
            let changed = Context(document: "A", before: "external change", after: saved.after,
                                 selected: saved.selected)
            XCTAssertEqual(owner.resolveOnHide(Context(document: nil, before: saved.before, after: saved.after,
                                                        selected: saved.selected)), .waitForDocument)
            XCTAssertEqual(owner.resolveCurrentContext(changed), .discardOwnership)
            XCTAssertNotNil(input.markedTextRange)
        }
    }

    func testActiveOwnedCompositionIsKeptDuringInputThenFinalizedOnAppearance() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let current = try context(input, document: "A")
        XCTAssertEqual(owner.resolveCurrentContext(current), .none)
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(owner.resolveOnAppearance(current), .unmarkOwnedText)
        input.unmarkText()
        XCTAssertNil(input.markedTextRange)
        input.setMarkedText("い", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try contents(input), "あい")
    }
}
#endif
