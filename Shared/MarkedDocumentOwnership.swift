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

    /// A reappearing keyboard is a new editing session even if UIKit did not
    /// deliver the disappearance callback. Resolve any prior mark before the
    /// next key can replace it.
    mutating func resolveOnAppearance(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        discard()
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }

    /// Resolve a temporary proxy disconnection without ever applying cleanup to
    /// an unknown or changed document. A disconnected proxy suspends the token;
    /// the first reconnected context must match every observable field.
    mutating func resolveCurrentContext(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }
        guard isSuspended else { return .none }

        discard() // Consume before invoking UIKit, whose callbacks may reenter.
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }

    /// On hide, finalize a mark only while the exact owning document/context is
    /// available. If the host has disconnected, retain a guarded one-shot token
    /// to resolve on reattachment instead of losing the ownership evidence.
    mutating func resolveOnHide(_ current: Context) -> Resolution {
        guard let owned = markedContext else { return .none }
        guard current.document != nil else {
            isSuspended = true
            return .waitForDocument
        }

        discard() // Consume before invoking UIKit, whose callbacks may reenter.
        return owned == current ? .unmarkOwnedText : .discardOwnership
    }
}
