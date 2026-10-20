import Foundation
import SumireCore

/// A single dispatcher per custom grid preserves ordering across different keys.
/// It sees committed gestures only; the view owns touch cancellation and holds.
final class CustomDoubleTapController {
    var onAction: ((CustomKeyAction) -> Void)?
    private var dispatcher = CustomDoubleTapDispatcher()
    private var timer: Timer?
    private var active = true
    private var generation = 0
    private(set) var isDispatchingAction = false
    private var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    func committedTap(keyIdentity: String, action: CustomKeyAction, binding: CustomDoubleTapBinding?) {
        guard active else { return }
        let actions = dispatcher.committedTap(keyIdentity: keyIdentity, normalAction: action,
                                              binding: binding, at: now)
        scheduleDeadline()
        deliver(actions)
    }

    func committedGesture(_ action: CustomKeyAction) {
        guard active else { return }
        let generation = self.generation
        interrupt()
        if active, generation == self.generation { deliver([action]) }
    }

    func interrupt() {
        // Actions delivered by this controller may call the surface's ordinary
        // command handlers. They must not flush the next key already pending.
        guard active, !isDispatchingAction else { return }
        let actions = dispatcher.interrupt()
        scheduleDeadline()
        deliver(actions)
    }

    func cancel() {
        generation += 1
        timer?.invalidate(); timer = nil
        dispatcher.cancel()
    }

    func deactivate() {
        active = false
        cancel()
    }

    private func deliver(_ actions: [CustomKeyAction]) {
        let generation = self.generation
        let wasDispatching = isDispatchingAction
        isDispatchingAction = true
        defer { isDispatchingAction = wasDispatching }
        for action in actions {
            // A dispatched layout change may replace this entire grid.
            guard active, generation == self.generation else { return }
            onAction?(action)
        }
    }

    private func scheduleDeadline() {
        timer?.invalidate(); timer = nil
        guard active, let deadline = dispatcher.deadline else { return }
        let timer = Timer(timeInterval: max(0.001, (deadline - now) / 1000), repeats: false) { [weak self] _ in
            guard let self, self.active else { return }
            let actions = self.dispatcher.flush(at: self.now)
            self.scheduleDeadline()
            self.deliver(actions)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { timer?.invalidate() }
}
