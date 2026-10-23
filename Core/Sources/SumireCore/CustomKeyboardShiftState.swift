/// Custom-layout Shift/CapsLock behavior pinned to Android df1f383.
/// Case conversion changes only ASCII a...z, independently of the locale.
public enum CustomKeyboardShiftState: Equatable {
    case off, oneShot, locked

    public var isActive: Bool { self != .off }
    public mutating func tapShift() { self = self == .off ? .oneShot : .off }
    public mutating func tapCapsLock() { self = self == .locked ? .off : .locked }
    /// Call only for text-producing actions. Commands do not consume Shift.
    public mutating func consumeText(_ text: String) {
        if self == .oneShot && !text.isEmpty { self = .off }
    }
    public func applying(to text: String) -> String {
        guard isActive else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            result.append((97...122).contains(scalar.value) ? UnicodeScalar(scalar.value - 32)! : scalar)
        }
        return String(result)
    }
}
