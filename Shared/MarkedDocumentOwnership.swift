import Foundation

/// Ownership of the last marked-text write. A proxy does not expose its marked
/// range, so text-context equality cannot prove field ownership after its opaque
/// document identifier changes.
struct MarkedDocumentOwnership {
    struct Context: Equatable {
        let document: String?
        let before: String?
        let after: String?
        let selected: String?

        init(document: String?, before: String?, after: String?, selected: String?) {
            self.document = document
            self.before = before
            self.after = after
            self.selected = selected.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Compare the proxy-visible caret neighborhood without treating it as
        /// document identity. Callers must still verify the owning document.
        func hasSameTextContext(as other: Context) -> Bool {
            before == other.before && after == other.after && selected == other.selected
        }

        /// A host may represent the empty side of a caret as either nil or an
        /// empty string between proxy callbacks. For deletion undo, accept that
        /// representation change only when the document, selection, and other
        /// nonempty side still identify the same caret neighborhood.
        func matchesDeletionUndoSnapshot(_ snapshot: Self,
                                         allowUnavailableTrailingContext: Bool = false) -> Bool {
            guard let document, document == snapshot.document,
                  selected == snapshot.selected else { return false }
            if self == snapshot { return true }

            func sameSide(_ lhs: String?, _ rhs: String?) -> Bool {
                if lhs == rhs { return true }
                return (lhs == nil || lhs?.isEmpty == true) &&
                    (rhs == nil || rhs?.isEmpty == true)
            }

            let beforeAnchors = before?.isEmpty == false && before == snapshot.before
            let afterAnchors = after?.isEmpty == false && after == snapshot.after
            if sameSide(before, snapshot.before) && sameSide(after, snapshot.after) &&
                (beforeAnchors || afterAnchors) {
                return true
            }

            // A deletion can exhaust the proxy's short context window exactly
            // at the caret. Keep that entry provisional, and allow a later
            // nonempty trailing context only while the caret and document start
            // still match. Callers must explicitly opt in for provisional entries.
            let snapshotAtDocumentStart = snapshot.before == nil || snapshot.before?.isEmpty == true
            let currentAtDocumentStart = before == nil || before?.isEmpty == true
            let snapshotHasNoTrailingContext = snapshot.after == nil || snapshot.after?.isEmpty == true
            return allowUnavailableTrailingContext && snapshotAtDocumentStart &&
                currentAtDocumentStart && snapshotHasNoTrailingContext
        }

        /// Immediately after an extension edit, UIKit can temporarily omit one
        /// side of the caret context. This is not a match; callers may only defer
        /// a decision and must require a later anchored match before using history.
        func hasMissingSideComparedTo(_ snapshot: Self) -> Bool {
            guard document != nil, document == snapshot.document,
                  selected == snapshot.selected else { return false }
            return (before == nil && snapshot.before?.isEmpty == false) ||
                (after == nil && snapshot.after?.isEmpty == false)
        }
    }

    enum Resolution: Equatable {
        case none
        case preserveOwnedText
        case restoreOwnedText
        case waitForDocument
        case discardOwnership
    }

    enum DiscardReason: String {
        case invalidMarkContext = "invalid-mark-context"
        case markOwnerChanged = "mark-owner-changed"
        case suspendedFocusChanged = "suspended-focus-changed"
        case appearanceDocumentMismatch = "appearance-document-mismatch"
        case appearanceTextContextMismatch = "appearance-text-context-mismatch"
        case suspendedContextMismatch = "suspended-context-mismatch"
        case hideContextMismatch = "hide-context-mismatch"
    }

    private var markedContext: Context?
    private var preCompositionContext: Context?
    private var ownerDocument: String?
    private var isSuspended = false
#if DEBUG
    private(set) var debugLastDiscardReason: DiscardReason?
#endif

    /// A new mark can extend the current composition only in the exact context
    /// that received its previous mark. Text equality is not field identity;
    /// the immutable document identity prevents rebinding within one lease.
    func canUpdateMark(in current: Context) -> Bool {
        guard current.document != nil else { return false }
        guard let ownerDocument else { return markedContext == nil }
        return !isSuspended && current.document == ownerDocument && markedContext == current
    }

    /// A host mark may be finalized only while the proxy still names the exact
    /// document and context that received it. Matching text in another field
    /// cannot authorize an unmark write.
    func canFinalizeMark(in current: Context) -> Bool {
        guard let ownerDocument, let markedContext, !isSuspended else { return false }
        return current.document == ownerDocument && markedContext == current
    }

    @discardableResult
    mutating func recordMark(before: Context, after: Context, isEmpty: Bool) -> Bool {
#if DEBUG
        debugLastDiscardReason = nil
#endif
        guard !isEmpty, let document = before.document, after.document == document else {
            discard(reason: .invalidMarkContext)
            return false
        }
        if let ownerDocument, ownerDocument != document {
            discard(reason: .markOwnerChanged)
            return false
        }
        if markedContext == nil { preCompositionContext = before }
        ownerDocument = document
        markedContext = after
        isSuspended = false
        return true
    }

    mutating func discard() {
        markedContext = nil
        preCompositionContext = nil
        ownerDocument = nil
        isSuspended = false
    }

    private mutating func discard(reason: DiscardReason) {
#if DEBUG
        debugLastDiscardReason = reason
#endif
        discard()
    }

    /// Revalidate the suspended mark after the host reattaches the keyboard.
    /// Matching proxy-visible text is insufficient to transfer a mark to a new
    /// document: a different field can expose the same surrounding text.
    mutating func resolveOnAppearance(_ current: Context,
                                      discardSuspended: Bool = false) -> Resolution {
#if DEBUG
        debugLastDiscardReason = nil
#endif
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        if isSuspended && discardSuspended {
            discard(reason: .suspendedFocusChanged)
            return .discardOwnership
        }

        // Keep the lease bound to the document that received the marked-text
        // write. UIKit may recreate the proxy for the same field, but there is
        // no public evidence here that a changed identifier names that field.
        // Fail closed rather than risk restoring composition into another field.
        guard ownerDocument == current.document else {
            discard(reason: .appearanceDocumentMismatch)
            return .discardOwnership
        }

        if isSuspended, let baseline = preCompositionContext,
           baseline.hasSameTextContext(as: current) {
            // Some proxy implementations omit marked text from both context
            // readings. In that case a retained mark and a host rollback are
            // indistinguishable. Reapply the same mark only at the exact
            // original insertion context, after the suspended-focus veto.
            ownerDocument = current.document
            markedContext = current
            isSuspended = false
            return .restoreOwnedText
        }

        if owned.hasSameTextContext(as: current) {
            markedContext = current
            isSuspended = false
            return .preserveOwnedText
        }

        discard(reason: .appearanceTextContextMismatch)
        return .discardOwnership
    }

    /// Resolve a temporary proxy disconnection without applying cleanup to an
    /// unknown context. Resume only when document identity and text context both
    /// match the editor that received our marked-text write.
    mutating func resolveCurrentContext(_ current: Context) -> Resolution {
#if DEBUG
        debugLastDiscardReason = nil
#endif
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }
        guard isSuspended else { return .none }

        guard owned == current else {
            discard(reason: .suspendedContextMismatch)
            return .discardOwnership
        }

        isSuspended = false
        return .preserveOwnedText
    }

    /// If the controller could not safely finalize before hide (for example,
    /// because the proxy was disconnected), suspend the ownership token until
    /// return rather than writing through an unidentified document.
    mutating func resolveOnHide(_ current: Context) -> Resolution {
#if DEBUG
        debugLastDiscardReason = nil
#endif
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        guard owned == current else {
            discard(reason: .hideContextMismatch)
            return .discardOwnership
        }

        isSuspended = true
        return .preserveOwnedText
    }

}

#if DEBUG
extension MarkedDocumentOwnership {
    /// Reports only equality booleans for the ownership regression trace.
    /// It deliberately never exposes document identifiers or text context.
    func debugContextComparison(_ current: Context) -> String {
        guard let markedContext else {
            return "lease=none;suspended=\(isSuspended);ownerDocumentPresent=\(ownerDocument != nil);ownerDocumentCurrent=false;ownerDocumentMatchesMark=false;markedContextCurrent=false;canFinalize=false"
        }
        let baselineMatches = preCompositionContext?.hasSameTextContext(as: current) ?? false
        let ownerDocumentMatchesCurrent = ownerDocument == current.document
        let ownerDocumentMatchesMark = ownerDocument == markedContext.document
        let markedContextMatchesCurrent = markedContext == current
        let canFinalize = canFinalizeMark(in: current)
        return "lease=present;suspended=\(isSuspended);document=\(markedContext.document == current.document);before=\(markedContext.before == current.before);after=\(markedContext.after == current.after);selected=\(markedContext.selected == current.selected);baseline=\(baselineMatches);ownerDocumentPresent=\(ownerDocument != nil);ownerDocumentCurrent=\(ownerDocumentMatchesCurrent);ownerDocumentMatchesMark=\(ownerDocumentMatchesMark);markedContextCurrent=\(markedContextMatchesCurrent);canFinalize=\(canFinalize)"
    }
}
#endif
