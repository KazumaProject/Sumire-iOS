import UIKit

/// Forward deletion uses only the currently supplied public document proxy.
/// Missing after-context is unknown, never an assumed one-character offset.
enum DocumentForwardDelete {
    static func apply(to proxy: UITextDocumentProxy) {
        if proxy.selectedText?.isEmpty == false {
            proxy.deleteBackward()
            return
        }
        guard let next = proxy.documentContextAfterInput?.first else { return }
        let offset = String(next).utf16.count
        proxy.adjustTextPosition(byCharacterOffset: offset)
        proxy.deleteBackward()
    }
}
