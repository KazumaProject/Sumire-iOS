/// One router per keyboard, shared by all participating keys. UIKit delivers
/// events on the main thread; owners must also mutate this router there.
public protocol KeyTouchParticipant: AnyObject {
    func finishActiveInput()
    func cancelActiveInput()
}

public final class KeyTouchRouter {
    private struct Entry {
        weak var key: (any KeyTouchParticipant)?
        let blocksFollowingTouches: Bool
    }
    public var independentMultiTouch = false
    private var gestureIndependent = false
    private var entries: [Entry] = []
    private var cancellationGeneration = 0
    public init() {}
    public var activeCount: Int { entries.filter { $0.key != nil }.count }

    /// Register before starting timers or showing a popup. A rejected second
    /// touch must not alter the existing key's state.
    public func begin(_ key: any KeyTouchParticipant, exclusive: Bool = false, blocksSequentialTouches: Bool = false) -> Bool {
        entries.removeAll { $0.key == nil }
        guard !entries.contains(where: { $0.key === key || $0.blocksFollowingTouches }) else { return false }
        if entries.isEmpty { gestureIndependent = independentMultiTouch }
        let generation = cancellationGeneration
        if exclusive || !gestureIndependent {
            let previous = entries.compactMap(\.key)
            entries.removeAll()
            for participant in previous {
                if exclusive && gestureIndependent { participant.cancelActiveInput() }
                else { participant.finishActiveInput() }
            }
        }
        // A commit may rebuild the keyboard and cancel the entire gesture.
        guard generation == cancellationGeneration else { return false }
        entries.append(Entry(key: key, blocksFollowingTouches: gestureIndependent ? exclusive : blocksSequentialTouches))
        return true
    }
    public func end(_ key: any KeyTouchParticipant) {
        entries.removeAll { $0.key == nil || $0.key === key }
    }
    public func cancelAll() {
        cancellationGeneration += 1
        let previous = entries.compactMap(\.key)
        entries.removeAll()
        previous.forEach { $0.cancelActiveInput() }
    }
}
