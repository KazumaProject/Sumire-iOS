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
    private var markedContext: Context?

    mutating func recordMark(before: Context, after: Context, isEmpty: Bool) {
        guard !isEmpty, let document = before.document, after.document == document else {
            discard()
            return
        }
        markedContext = after
    }
    mutating func discard() { markedContext = nil }
    mutating func consumeIfMatching(_ current: Context) -> Bool {
        let owned = markedContext
        discard() // Consume before invoking UIKit, whose callbacks may reenter.
        return current.document != nil && owned == current
    }
}
