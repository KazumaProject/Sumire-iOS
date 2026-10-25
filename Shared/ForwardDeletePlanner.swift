import Foundation

enum ForwardDeletePlan: Equatable {
    case deleteSelection
    case deleteAfterCursor(characterOffset: Int)
    case noOp
}

enum ForwardDeletePlanner {
    /// Plan a forward delete from the host's optional selection and trailing context.
    /// A Swift Character is one extended grapheme cluster. This implementation passes
    /// its UTF-16 length to the proxy. UITextInput.offset(from:to:) documents UTF-16
    /// units, while UITextDocumentProxy.adjustTextPosition(byCharacterOffset:) only
    /// says "characters"; compound-cluster behavior therefore needs external-host
    /// acceptance coverage instead of assuming the proxy uses the same unit.
    static func plan(selectedText: String?, contextAfterInput: String?) -> ForwardDeletePlan {
        if let selectedText, !selectedText.isEmpty {
            return .deleteSelection
        }
        guard let nextCharacter = contextAfterInput?.first else { return .noOp }
        return .deleteAfterCursor(characterOffset: String(nextCharacter).utf16.count)
    }
}
