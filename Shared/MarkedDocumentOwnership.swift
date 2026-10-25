import Foundation

/// Conservative ownership of the last marked-text write. A proxy does not expose
/// its marked range, so matching observable context cannot prove host ownership
/// after an unobservable external change. Never defer cleanup to a new document.
struct MarkedDocumentOwnership {
    struct Context: Equatable {
        let document: String?
        let before: String?
        let after: String?
        let selected: String?
    }

    enum Resolution: Equatable {
        case none
        case unmarkOwnedText
        case waitForDocument
        case discardOwnership
    }

    private var markedContext: Context?
    private var isSuspended = false

    mutating func recordMark(before: Context, after: Context, isEmpty: Bool) {
        guard !isEmpty, let document = before.document, after.document == document else {
            discard()
            return
        }
        markedContext = after
        isSuspended = false
    }

    mutating func discard() {
        markedContext = nil
        isSuspended = false
    }

    /// Exposes only ownership state for debug acceptance diagnostics; never returns
    /// document contents or context text.
    func diagnosticState(for current: Context) -> String {
        guard let markedContext else { return "none" }
        let lifecycle = isSuspended ? "suspended" : "active"
        let match = markedContext == current ? "match" : "mismatch"
        return "\(lifecycle)-\(match)"
    }

    /// If UIKit temporarily disconnects the proxy as the extension hides, keep
    /// the ownership token until the same document and observable context return.
    /// Never call unmarkText on a missing, different, or changed document.
    mutating func resolveOnHide(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        discard() // Consume before invoking UIKit, whose callbacks may reenter.
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }

    /// A restored keyboard view must finalize any old mark before processing a
    /// new key. This also handles hosts that skipped the expected hide callback.
    mutating func resolveOnAppearance(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        discard()
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }

    /// Retry a suspended token when the proxy reconnects between lifecycle
    /// callbacks. Active marks are left alone during ordinary editing.
    mutating func resolveCurrentContext(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }
        guard isSuspended else { return .none }

        discard()
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }
}
