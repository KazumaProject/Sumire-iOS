#if DEBUG
import XCTest
import UIKit
@testable import Sumire

@MainActor
final class MarkedDocumentOwnershipTests: XCTestCase {
    private typealias Context = Sumire.MarkedDocumentOwnership.Context

    func testNilAndEmptySelectionHaveTheSameContextIdentity() {
        XCTAssertEqual(
            Context(document: "A", before: "left", after: "right", selected: nil),
            Context(document: "A", before: "left", after: "right", selected: "")
        )
    }

    func testDeletionUndoAcceptsNilOrEmptyAtDocumentStartOnlyWithSameTrailingAnchor() {
        let recorded = Context(document: "A", before: nil, after: "tail", selected: nil)
        XCTAssertTrue(Context(document: "A", before: "", after: "tail", selected: "")
            .matchesDeletionUndoSnapshot(recorded))
        XCTAssertFalse(Context(document: "A", before: "", after: "other", selected: nil)
            .matchesDeletionUndoSnapshot(recorded))
        XCTAssertFalse(Context(document: "B", before: "", after: "tail", selected: nil)
            .matchesDeletionUndoSnapshot(recorded))
        XCTAssertFalse(Context(document: "A", before: "", after: "", selected: nil)
            .matchesDeletionUndoSnapshot(
                Context(document: "A", before: nil, after: nil, selected: nil)
            ))
    }

    func testDeletionUndoAcceptsNilOrEmptyAtDocumentEndOnlyWithSameLeadingAnchor() {
        let recorded = Context(document: "A", before: "head", after: nil, selected: nil)
        XCTAssertTrue(Context(document: "A", before: "head", after: "", selected: nil)
            .matchesDeletionUndoSnapshot(recorded))
        XCTAssertFalse(Context(document: "A", before: "other", after: "", selected: nil)
            .matchesDeletionUndoSnapshot(recorded))
    }

    func testProvisionalDeletionAtDocumentStartAcceptsTrailingContextOnlyWhenOptedIn() {
        let provisional = Context(document: "A", before: nil, after: "", selected: nil)
        let refreshed = Context(document: "A", before: "", after: "tail", selected: nil)

        XCTAssertFalse(refreshed.matchesDeletionUndoSnapshot(provisional))
        XCTAssertTrue(refreshed.matchesDeletionUndoSnapshot(
            provisional, allowUnavailableTrailingContext: true
        ))
        XCTAssertFalse(Context(document: "A", before: "head", after: "tail", selected: nil)
            .matchesDeletionUndoSnapshot(provisional, allowUnavailableTrailingContext: true))
        XCTAssertFalse(Context(document: "B", before: "", after: "tail", selected: nil)
            .matchesDeletionUndoSnapshot(provisional, allowUnavailableTrailingContext: true))
        XCTAssertFalse(Context(document: "A", before: "", after: "tail", selected: "x")
            .matchesDeletionUndoSnapshot(provisional, allowUnavailableTrailingContext: true))
    }

    func testMissingUndoContextSideIsDeferredButNeverConsideredAMatch() {
        let expected = Context(document: "A", before: "left", after: "right", selected: nil)
        let missingLeading = Context(document: "A", before: nil, after: "leftRight", selected: nil)
        let missingTrailing = Context(document: "A", before: "leftright", after: nil, selected: nil)
        XCTAssertFalse(missingLeading.matchesDeletionUndoSnapshot(expected))
        XCTAssertTrue(missingLeading.hasMissingSideComparedTo(expected))
        XCTAssertFalse(missingTrailing.matchesDeletionUndoSnapshot(expected))
        XCTAssertTrue(missingTrailing.hasMissingSideComparedTo(expected))
        XCTAssertFalse(Context(document: "B", before: nil, after: "leftRight", selected: nil)
            .hasMissingSideComparedTo(expected))
        XCTAssertFalse(Context(document: "A", before: "other", after: "text", selected: nil)
            .hasMissingSideComparedTo(expected))
    }

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
        XCTAssertTrue(owner.recordMark(before: before, after: try context(input, document: document),
                                      isEmpty: text.isEmpty),
                      "A valid nonempty mark must be accepted into the ownership lease")
    }
    func testSameDocumentHideFinalizesMarkAndKeepsTextForReentry() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            let text = "か\u{3099}👩‍💻"
            try mark(text, in: input, document: "A", owner: &owner)
            let current = try context(input, document: "A")
            XCTAssertTrue(owner.canUpdateMark(in: current))
            XCTAssertFalse(owner.canUpdateMark(in: Context(document: "B", before: current.before,
                                                            after: current.after, selected: current.selected)))
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertTrue(owner.canFinalizeMark(in: current))

            // Match Android's onFinishInputView boundary: keep the characters,
            // but end their marked state before the ownership lease is retired.
            input.unmarkText()
            owner.discard()
            let committed = try context(input, document: "A")
            XCTAssertEqual(try contents(input), text)
            XCTAssertNil(input.markedTextRange)
            XCTAssertEqual(owner.resolveOnHide(committed), .none)
            XCTAssertEqual(owner.resolveOnAppearance(committed), .none)
            XCTAssertTrue(owner.canUpdateMark(in: committed), "A later key may begin a new composition in this editor")
        }
    }

    func testFinalizingMarkRequiresExactCurrentOwnership() {
        let baseline = Context(document: "A", before: "left", after: "right", selected: nil)
        let marked = Context(document: "A", before: "leftあ", after: "right", selected: nil)
        var owner = Sumire.MarkedDocumentOwnership()
        XCTAssertFalse(owner.canFinalizeMark(in: baseline),
                       "A local composition without a host mark cannot authorize an unmark")

        owner.recordMark(before: baseline, after: marked, isEmpty: false)
        XCTAssertTrue(owner.canFinalizeMark(in: marked))
        XCTAssertFalse(owner.canFinalizeMark(in: Context(document: "B", before: marked.before,
                                                         after: marked.after, selected: marked.selected)),
                       "Matching text in a different document cannot authorize finalization")
        XCTAssertFalse(owner.canFinalizeMark(in: Context(document: "A", before: "other", after: "right",
                                                         selected: nil)),
                       "A changed caret context cannot authorize finalization")

        XCTAssertEqual(owner.resolveOnHide(marked), .preserveOwnedText)
        XCTAssertFalse(owner.canFinalizeMark(in: marked),
                       "A suspended mark cannot be finalized until its owner is revalidated")
    }

    func testRejectedMarkReportsFailureAndDiscardsPreviousLease() {
        let before = Context(document: "A", before: "left", after: "right", selected: nil)
        let marked = Context(document: "A", before: "leftあ", after: "right", selected: nil)
        let mismatchedAfter = Context(document: "B", before: "leftあ", after: "right", selected: nil)
        var owner = Sumire.MarkedDocumentOwnership()

        XCTAssertTrue(owner.recordMark(before: before, after: marked, isEmpty: false))
        XCTAssertTrue(owner.canFinalizeMark(in: marked))
        XCTAssertFalse(owner.recordMark(before: marked, after: mismatchedAfter, isEmpty: false),
                       "A mark that changes document identity must be rejected")
        XCTAssertFalse(owner.canFinalizeMark(in: marked),
                       "A rejected mark must discard the former ownership lease")
        XCTAssertTrue(owner.canUpdateMark(in: mismatchedAfter),
                      "A later mark may establish a new lease after the rejected owner was cleared")
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
        XCTAssertEqual(owner.resolveCurrentContext(current), .preserveOwnedText)
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(try contents(input), "あ")
        try mark("あ", in: input, document: "A", owner: &owner)
        owner.discard()
        input.insertText("亜")
        input.setMarkedText("別", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .none)
        try mark("", in: input, document: "A", owner: &owner)
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "A")), .none)
    }

    func testDisconnectedMarkIsPreservedOnlyWhenDocumentAndTextContextMatch() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あ", in: input, document: "A", owner: &owner)
            let saved = try context(input, document: "A")
            let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                       selected: saved.selected)

            XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
            XCTAssertEqual(owner.resolveCurrentContext(disconnected), .waitForDocument)
            XCTAssertNotNil(input.markedTextRange)

            XCTAssertEqual(owner.resolveCurrentContext(saved), .preserveOwnedText)
            XCTAssertNotNil(input.markedTextRange)
            XCTAssertEqual(try contents(input), "あ")

            input.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertEqual(try contents(input), "あい")
            XCTAssertNotNil(input.markedTextRange)
        }
    }

    func testSuspendedMarkRejectsNewProxyIdentifierDespiteMatchingTextContext() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        let saved = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(saved), .preserveOwnedText)

        let recreatedProxy = Context(document: "proxy-after", before: saved.before,
                                     after: saved.after, selected: saved.selected)
        XCTAssertEqual(owner.resolveCurrentContext(recreatedProxy), .discardOwnership)
        XCTAssertEqual(owner.resolveOnAppearance(recreatedProxy), .none)
        XCTAssertEqual(try contents(input), "あ")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testObservedFocusChangeRejectsMatchingContextFromAnotherDocument() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        let saved = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(saved), .preserveOwnedText)

        let otherDocument = Context(document: "proxy-after", before: saved.before,
                                    after: saved.after, selected: saved.selected)
        XCTAssertEqual(owner.resolveOnAppearance(otherDocument, discardSuspended: true), .discardOwnership,
                       "A selectionWillChange observed during suspension prevents text-context rebinding")
        XCTAssertEqual(try contents(input), "あ")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testAppearanceRejectsDifferentDocumentEvenWhenMarkedContextMatches() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        let saved = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(saved), .preserveOwnedText)

        let otherDocument = Context(document: "proxy-after", before: saved.before,
                                    after: saved.after, selected: saved.selected)
        XCTAssertEqual(owner.resolveOnAppearance(otherDocument), .discardOwnership)
        XCTAssertEqual(owner.resolveOnAppearance(otherDocument), .none,
                       "The old lease is consumed; the caller must discard its local composition")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testAppearanceRequestsGuardedRestoreWhenHostDropsMarkToBaseline() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        let baseline = try context(input, document: "proxy-before")
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        try mark("あい", in: input, document: "proxy-before", owner: &owner)
        let marked = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(marked), .preserveOwnedText)

        // Model a host rolling its marked range back while the app is away.
        input.text = ""
        let reconnectedProxy = try context(input, document: "proxy-before")
        XCTAssertTrue(baseline.hasSameTextContext(as: reconnectedProxy))
        XCTAssertEqual(owner.resolveOnAppearance(reconnectedProxy), .restoreOwnedText)
        XCTAssertTrue(owner.canUpdateMark(in: reconnectedProxy),
                      "The controller may reapply only after this exact baseline is revalidated")

        input.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
        owner.recordMark(before: reconnectedProxy,
                         after: try context(input, document: "proxy-before"), isEmpty: false)
        XCTAssertEqual(try contents(input), "あい")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testObservedSuspendedSelectionChangeRejectsMatchingMarkedAndBaselineContexts() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        let saved = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(saved), .preserveOwnedText)

        XCTAssertEqual(owner.resolveOnAppearance(saved, discardSuspended: true), .discardOwnership)
        XCTAssertEqual(owner.resolveOnAppearance(saved), .none)
        XCTAssertNotNil(input.markedTextRange,
                        "Dropping extension ownership must not unmark text through an uncertain proxy")

        let secondInput = UITextField()
        var secondOwner = Sumire.MarkedDocumentOwnership()
        let secondBaseline = try context(secondInput, document: "proxy-before")
        try mark("あ", in: secondInput, document: "proxy-before", owner: &secondOwner)
        XCTAssertEqual(secondOwner.resolveOnHide(try context(secondInput, document: "proxy-before")),
                       .preserveOwnedText)
        let recreatedProxyAtBaseline = Context(document: "proxy-before", before: secondBaseline.before,
                                               after: secondBaseline.after, selected: secondBaseline.selected)
        XCTAssertEqual(secondOwner.resolveOnAppearance(recreatedProxyAtBaseline, discardSuspended: true),
                       .discardOwnership,
                       "An observed selection change must veto even the otherwise matching baseline fallback")
    }

    func testNilProxyAtAppearanceCanRevalidateOriginalDocumentWhenMarkedContextMatches() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        let baseline = try context(input, document: "proxy-before")
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        let saved = try context(input, document: "proxy-before")
        XCTAssertEqual(owner.resolveOnHide(saved), .preserveOwnedText)

        let disconnected = Context(document: nil, before: saved.before,
                                   after: saved.after, selected: saved.selected)
        XCTAssertEqual(owner.resolveOnAppearance(disconnected), .waitForDocument)

        let recreatedProxy = Context(document: "proxy-before", before: saved.before,
                                     after: saved.after, selected: saved.selected)
        let expectedResolution: Sumire.MarkedDocumentOwnership.Resolution =
            baseline.hasSameTextContext(as: saved) ? .restoreOwnedText : .preserveOwnedText
        XCTAssertEqual(owner.resolveOnAppearance(recreatedProxy), expectedResolution)
        XCTAssertTrue(owner.canUpdateMark(in: recreatedProxy))
        XCTAssertNotNil(input.markedTextRange)
    }

    func testAmbiguousProxyContextReattachesOnlyAfterSuspendedAppearance() {
        var owner = Sumire.MarkedDocumentOwnership()
        let baseline = Sumire.MarkedDocumentOwnership.Context(
            document: "proxy-before", before: nil, after: nil, selected: nil)
        owner.recordMark(before: baseline, after: baseline, isEmpty: false)
        XCTAssertEqual(owner.resolveOnHide(baseline), .preserveOwnedText)

        let renewed = Sumire.MarkedDocumentOwnership.Context(
            document: "proxy-after", before: nil, after: nil, selected: nil)
        XCTAssertEqual(owner.resolveOnAppearance(renewed), .discardOwnership,
                       "Nil surrounding text cannot authorize transferring a mark to a different document")
        XCTAssertEqual(owner.resolveOnAppearance(renewed), .none)
    }

    func testNilProxyAtAppearanceCanRestoreOnlyExactBaselineAfterHostRollback() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        let baseline = try context(input, document: "proxy-before")
        try mark("あ", in: input, document: "proxy-before", owner: &owner)
        try mark("あい", in: input, document: "proxy-before", owner: &owner)
        XCTAssertEqual(owner.resolveOnHide(try context(input, document: "proxy-before")), .preserveOwnedText)

        // Simulate the host dropping the mark while the first appearance sees
        // a disconnected proxy; its later callback exposes the same identity.
        input.text = ""
        let disconnected = Context(document: nil, before: nil, after: nil, selected: nil)
        XCTAssertEqual(owner.resolveOnAppearance(disconnected), .waitForDocument)
        let reconnected = try context(input, document: "proxy-before")
        XCTAssertTrue(baseline.hasSameTextContext(as: reconnected))
        XCTAssertEqual(owner.resolveOnAppearance(reconnected), .restoreOwnedText)
        XCTAssertTrue(owner.canUpdateMark(in: reconnected))

        input.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
        owner.recordMark(before: reconnected, after: try context(input, document: "proxy-before"), isEmpty: false)
        XCTAssertEqual(try contents(input), "あい")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testBaselineRestoreRequiresExactBeforeAfterAndSelectedContext() {
        let baseline = Context(document: "proxy-before", before: "left", after: "right", selected: "selection")
        let marked = Context(document: "proxy-before", before: "left", after: "right", selected: nil)
        let mismatches = [
            Context(document: "proxy-before", before: "different", after: "right", selected: "selection"),
            Context(document: "proxy-before", before: "left", after: "different", selected: "selection"),
            Context(document: "proxy-before", before: "left", after: "right", selected: "different")
        ]

        for mismatch in mismatches {
            var owner = Sumire.MarkedDocumentOwnership()
            owner.recordMark(before: baseline, after: marked, isEmpty: false)
            XCTAssertEqual(owner.resolveOnHide(marked), .preserveOwnedText)
            XCTAssertEqual(owner.resolveOnAppearance(mismatch), .discardOwnership,
                           "A baseline mismatch in any proxy-visible component must reject restoration")
        }
    }

    func testDisconnectedMarkIsDiscardedWhenTextContextChanges() throws {
        for input in [UITextField(), UITextView()] as [UIView & UITextInput] {
            var owner = Sumire.MarkedDocumentOwnership()
            try mark("あ", in: input, document: "A", owner: &owner)
            let saved = try context(input, document: "A")
            let disconnected = Context(document: nil, before: saved.before, after: saved.after,
                                       selected: saved.selected)
            XCTAssertEqual(owner.resolveOnHide(disconnected), .waitForDocument)
            XCTAssertEqual(owner.resolveCurrentContext(Context(document: "B", before: "other document",
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

    func testActiveOwnedCompositionIsKeptDuringInputAndAppearance() throws {
        let input = UITextField()
        var owner = Sumire.MarkedDocumentOwnership()
        try mark("あ", in: input, document: "A", owner: &owner)
        let current = try context(input, document: "A")
        XCTAssertEqual(owner.resolveCurrentContext(current), .none)
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(owner.resolveOnAppearance(current), .preserveOwnedText)
        XCTAssertNotNil(input.markedTextRange)
        input.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(try contents(input), "あい")
        XCTAssertNotNil(input.markedTextRange)
    }

    func testCompositionSessionSharesInMemoryReadingAcrossSurfaceRecreation() {
        let session = Sumire.KeyboardCompositionSession()
        session.composition.append("あ")

        let first = Sumire.KeyboardSurface(frame: .zero, session: session)
        XCTAssertTrue(first.hasComposition)
        let recreated = Sumire.KeyboardSurface(frame: .zero, session: session)
        XCTAssertTrue(recreated.hasComposition)
        XCTAssertTrue(session.needsCompositionRefresh == false)
    }

    func testRestoringRecreatedSurfaceDoesNotRewriteHostMarkedText() {
        let session = Sumire.KeyboardCompositionSession()
        session.composition.append("あ")
        let surface = Sumire.KeyboardSurface(frame: .zero, session: session)
        var markedTextWrites = 0
        surface.updateMarkedSelection = { _, _, _ in markedTextWrites += 1 }

        surface.restoreCompositionAfterControllerRecreation()

        XCTAssertEqual(markedTextWrites, 0,
                       "Restoring candidates must not send a stale composition through the current host proxy")
        XCTAssertTrue(surface.hasComposition)
    }

}
#endif
