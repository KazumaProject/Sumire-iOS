import Foundation

public struct CustomDoubleTapBinding: Equatable {
    public enum Policy: String { case exclusive = "EXCLUSIVE", promote = "PROMOTE" }
    public let action: CustomKeyAction
    public let policy: Policy
    public init(action: CustomKeyAction, policy: Policy = .exclusive) {
        self.action = action
        self.policy = policy
    }

    /// Matches pinned Android import defaults and effectiveDoubleTapBinding. Persisted policy
    /// never grants immediate execution to a non-Shift shortcut. Missing special flag is false.
    public static func effective(definition: LayoutJSON?, normalAction: CustomKeyAction,
                                 targets: CustomLayoutTargets) -> Self? {
        guard definition?["isSpecialKey"] == .bool(true),
              definition?["doubleTapEnabled"] != .bool(false) else { return nil }
        let raw = definition?["doubleTapAction"]?.string
        let action: CustomKeyAction
        if let raw { action = .tap(raw, targets: targets) }
        else if definition?["doubleTapEnabled"] == nil, definition?["action"]?.string == "ShiftKeyPressed" {
            action = .tap("CapLockKey", targets: targets)
        } else { return nil }
        return Self(action: action, policy: normalAction == .tap("ShiftKeyPressed", targets: targets) && (raw ?? "CapLockKey") == "CapLockKey"
                    ? .promote : .exclusive)
    }
}

/// Receives committed taps only (never touch-down, cancelled gestures or long presses).
/// All timestamps and deadline values use the same monotonic millisecond clock. The UI owns
/// scheduling: call flush(at:) at deadline, interrupt before another gesture, cancel on detach.
public struct CustomDoubleTapDispatcher {
    private struct Pending {
        let identity: String
        let normal: CustomKeyAction
        let binding: CustomDoubleTapBinding
        let started: Double
    }
    private var pending: Pending?
    public let timeoutMilliseconds: Double
    public let minimumIntervalMilliseconds: Double
    public var deadline: Double? { pending.map { $0.started + timeoutMilliseconds } }
    public init(timeoutMilliseconds: Double = 300, minimumIntervalMilliseconds: Double = 40) {
        precondition(timeoutMilliseconds.isFinite && minimumIntervalMilliseconds.isFinite &&
                     minimumIntervalMilliseconds >= 0 && timeoutMilliseconds >= minimumIntervalMilliseconds)
        self.timeoutMilliseconds = timeoutMilliseconds
        self.minimumIntervalMilliseconds = minimumIntervalMilliseconds
    }
    public mutating func committedTap(keyIdentity: String, normalAction: CustomKeyAction,
                                      binding: CustomDoubleTapBinding?, at now: Double) -> [CustomKeyAction] {
        if let previous = pending {
            let interval = now - previous.started
            if previous.identity == keyIdentity && interval >= 0 && interval < minimumIntervalMilliseconds {
                return []
            }
            if previous.identity == keyIdentity && previous.binding == binding &&
                interval >= minimumIntervalMilliseconds && interval <= timeoutMilliseconds {
                pending = nil
                return [previous.binding.action]
            }
        }
        var actions = interrupt()
        guard let binding else { actions.append(normalAction); return actions }
        if binding.policy == .promote { actions.append(normalAction) }
        pending = Pending(identity: keyIdentity, normal: normalAction, binding: binding, started: now)
        return actions
    }
    public mutating func flush(at now: Double) -> [CustomKeyAction] {
        guard let deadline, now >= deadline else { return [] }
        return interrupt()
    }
    public mutating func interrupt() -> [CustomKeyAction] {
        guard let active = pending else { return [] }
        pending = nil
        return active.binding.policy == .exclusive ? [active.normal] : []
    }
    public mutating func cancel() { pending = nil }
}
