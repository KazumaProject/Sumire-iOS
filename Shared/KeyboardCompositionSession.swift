import Foundation
import SumireCore

/// In-memory state shared by keyboard view controllers during one extension
/// process lifetime. It never writes composing text to disk or an app group.
@MainActor
final class KeyboardCompositionSession {
    static let extensionProcess = KeyboardCompositionSession()

#if DEBUG
    var debugCompositionDidChange: (() -> Void)?
    private(set) var debugProcessControllerSequence: UInt64 = 0
    private(set) var debugCompositionTraceSequence: UInt64 = 0
    private(set) var debugCompositionTraceEvents: [String] = []
    let debugProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    func registerDebugController() -> UInt64 {
        debugProcessControllerSequence &+= 1
        return debugProcessControllerSequence
    }

    func recordDebugCompositionTrace(controller: UInt64, payload: String) -> (entry: String, trace: String) {
        debugCompositionTraceSequence &+= 1
        let entry = "seq=\(debugCompositionTraceSequence);pid=\(debugProcessIdentifier);controller=\(controller);\(payload)"
        debugCompositionTraceEvents.append(entry)
        if debugCompositionTraceEvents.count > 96 {
            debugCompositionTraceEvents.removeFirst(debugCompositionTraceEvents.count - 96)
        }
        return (entry, debugCompositionTraceEvents.joined(separator: "|"))
    }
#endif
    var composition = CompositionState() {
        didSet {
#if DEBUG
            debugCompositionDidChange?()
#endif
        }
    }
    var containsRomaji = false
    var markedOwnership = MarkedDocumentOwnership()
    var expectedContext: MarkedDocumentOwnership.Context?
    var needsCompositionRefresh = false
    var hostFocusChangedWhileSuspended = false
    var needsHostMarkRestore = false
}
