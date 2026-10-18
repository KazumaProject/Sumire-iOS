/// Separates a key's ordinary release from actions already emitted by a hold.
/// Releasing or force-finishing after a repeat must not emit a second action.
public struct KeyPressEmission {
    public private(set) var isActive = false
    private var emitted = false
    public init() {}
    public mutating func begin() { isActive = true; emitted = false }
    public mutating func markEmitted() { if isActive { emitted = true } }
    public mutating func finish(inside: Bool = true) -> Bool {
        let shouldEmit = isActive && !emitted && inside
        cancel()
        return shouldEmit
    }
    public mutating func cancel() { isActive = false; emitted = false }
}
