import Foundation

/// Replace the complete marked preview with raw left text, one ASCII space and
/// its committed tail. Select the tail's start before unmarking, so no cursor
/// adjustment depends on the UTF-16 length an editor actually accepts.
enum RawSpaceCommit {
    static func apply(left: String, tail: String,
                      setMarked: (String, NSRange) -> Void,
                      unmark: () -> Void, insert: (String) -> Void) {
        if !tail.isEmpty {
            setMarked(tail, NSRange(location: 0, length: 0))
            unmark()
        }
        insert(left + " ")
    }
}
