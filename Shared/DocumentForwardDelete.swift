import UIKit

/// Forward deletion uses only the currently supplied public document proxy.
/// Missing after-context is unknown, never an assumed one-character offset.
enum DocumentForwardDelete {
    static func apply(to proxy: UITextDocumentProxy) {
        if proxy.selectedText?.isEmpty == false {
            proxy.deleteBackward()
            return
        }
        guard let before = proxy.documentContextBeforeInput,
              let after = proxy.documentContextAfterInput,
              let next = after.first else { return }
        // Splitting a surrogate can surface as U+FFFD in a String context.
        // Literal replacement text is indistinguishable here, so keep it too.
        guard before.last?.unicodeScalars.contains(where: { $0.value == 0xfffd }) != true,
              !next.unicodeScalars.contains(where: { $0.value == 0xfffd }) else { return }
        let context = before + after
        let boundaryUTF16 = context.utf16.index(context.utf16.startIndex, offsetBy: before.utf16.count)
        guard let boundary = String.Index(boundaryUTF16, within: context),
              context.indices.contains(boundary) else { return }
        let offset = String(next).utf16.count
        proxy.adjustTextPosition(byCharacterOffset: offset)
        proxy.deleteBackward()
    }
}
