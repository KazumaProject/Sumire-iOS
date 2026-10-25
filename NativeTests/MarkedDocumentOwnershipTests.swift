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

    func testExactHideFinalizesOwnedMarkBeforeFollowingInput() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let current = try context(input, document: "A")

        XCTAssertEqual(owner.resolveOnHide(current), .unmarkOwnedText)
        XCTAssertEqual(owner.resolveOnHide(current), .none)
        input.unmarkText()
        XCTAssertNil(input.markedTextRange)
        input.setMarkedText("い", selectedRange: NSRange(location: 1, length: 0))

        XCTAssertEqual(try contents(input), "あい")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testDisconnectedHideFinalizesOnlyAfterExactDocumentContextReturns() throws {
        let input = UITextView()
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
        input.setMarkedText("い", selectedRange: NSRange(location: 1, length: 0))

        XCTAssertEqual(try contents(input), "あい")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testAppearanceFinalizesOwnedMarkWhenHideCallbackCouldNot() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("か\u{3099}👩‍💻", in: input, document: "A", owner: &owner)
        let saved = try context(input, document: "A")
        let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                   selected: saved.selected)

        XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
        XCTAssertEqual(owner.resolveOnAppearance(saved), .unmarkOwnedText)
        input.unmarkText()

        XCTAssertNil(input.markedTextRange)
        XCTAssertEqual(try contents(input), "か\u{3099}👩‍💻")
    }

    func testDifferentDocumentOrContextNeverUnmarksAnotherMark() throws {
        let input = UITextView()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let saved = try context(input, document: "A")
        let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                   selected: saved.selected)

        XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
        XCTAssertEqual(owner.resolveOnAppearance(Context(document: "B", before: saved.before,
                                                          after: saved.after, selected: saved.selected)),
                       .discardOwnership)
        XCTAssertNotNil(input.markedTextRange)

        try mark("あ", in: input, document: "A", owner: &owner)
        let nextSaved = try context(input, document: "A")
        XCTAssertEqual(owner.resolveOnHide(Context(document: nil, before: nextSaved.before,
                                                   after: nextSaved.after, selected: nextSaved.selected)),
                       .waitForDocument)
        XCTAssertEqual(owner.resolveCurrentContext(Context(document: "A", before: "external change",
                                                             after: nextSaved.after, selected: nextSaved.selected)),
                       .discardOwnership)
        XCTAssertNotNil(input.markedTextRange)
    }

    func testEmptyMarkDoesNotCreateOwnershipAndActiveInputIsNotFinalized() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let active = try context(input, document: "A")

        XCTAssertEqual(owner.resolveCurrentContext(active), .none)
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(owner.resolveOnAppearance(active), .unmarkOwnedText)
        input.unmarkText()
        XCTAssertNil(input.markedTextRange)

        try mark("い", in: input, document: "A", owner: &owner)
        try mark("", in: input, document: "A", owner: &owner)
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .none)
    }
}
#endif
