import Foundation

/// Single-stage controllers differ in both direction resolution and hold
/// behavior. FLICK_LONG_PRESS has eight sectors and never substitutes a nearby
/// configured direction for an unconfigured sector.
public struct SingleStageFlickEvaluator {
    public enum Style { case standard, centerGuide, petal, crossAction, directionalLongPress }
    public struct Selection: Equatable {
        public let direction: MultiFlickDirection?
        public let text: String?
        public let longPress: Bool
    }
    public let style: Style
    public let map: [MultiFlickDirection: String]
    public let alternate: [MultiFlickDirection: String]
    public private(set) var selected: MultiFlickDirection? = .tap
    public private(set) var isActive = false
    public private(set) var longPress = false
    public private(set) var holdPending = false
    private var down = FlickPoint(0, 0)
    private var config = MultiFlickConfiguration()
    public init(style: Style, map: [MultiFlickDirection: String], alternate: [MultiFlickDirection: String] = [:]) {
        self.style = style; self.map = map; self.alternate = alternate
    }
    public mutating func begin(at point: FlickPoint, configuration: MultiFlickConfiguration) {
        cancel(); down = point; config = configuration; isActive = true
        selected = style == .directionalLongPress && !configured(.tap) ? nil : .tap
        scheduleHold()
    }
    private func configured(_ direction: MultiFlickDirection) -> Bool {
        map[direction]?.isEmpty == false || alternate[direction]?.isEmpty == false
    }
    private mutating func scheduleHold() {
        switch style {
        case .standard, .centerGuide: holdPending = false
        case .petal, .crossAction: holdPending = true
        case .directionalLongPress: holdPending = selected.flatMap { alternate[$0] }?.isEmpty == false
        }
    }
    public mutating func hold() {
        guard isActive, holdPending else { return }
        holdPending = false; longPress = true
    }
    private func resolve(_ delta: FlickPoint) -> MultiFlickDirection? {
        guard config.crossed(delta) else { return style == .directionalLongPress && !configured(.tap) ? nil : .tap }
        if style == .directionalLongPress {
            var angular = config; angular.guideGrid = false
            let direction = angular.direction(delta: delta, enabled: Set(MultiFlickDirection.allCases), position: .init(0.5, 0.5))
            return configured(direction) ? direction : nil
        }
        if style == .standard {
            let angle = atan2(delta.y, delta.x) * 180 / .pi
            if angle > -45 && angle <= 45 { return .right }
            if angle > 45 && angle <= 135 { return .down }
            if angle < -45 && angle >= -135 { return .up }
            return .left
        }
        if abs(delta.x) > abs(delta.y) { return delta.x < 0 ? .left : .right }
        return delta.y < 0 ? .up : .down
    }
    public mutating func move(to point: FlickPoint) {
        guard isActive else { return }
        let delta = point - down
        if style == .petal && !longPress {
            var cancelConfig = config; cancelConfig.threshold *= 0.5
            if cancelConfig.crossed(delta) { holdPending = false }
        }
        let next = resolve(delta)
        guard selected != next else { return }
        selected = next
        if style == .directionalLongPress { longPress = false; scheduleHold() }
    }
    public var selectedText: String? {
        guard let selected else { return nil }
        let text = longPress && alternate[selected]?.isEmpty == false ? alternate[selected] : map[selected]
        return text?.isEmpty == false ? text : nil
    }
    public mutating func end(at point: FlickPoint) -> String? {
        endSelection(at: point)?.text
    }
    public mutating func endSelection(at point: FlickPoint) -> Selection? {
        guard isActive else { return nil }
        if style == .standard { selected = resolve(point - down) }
        return finishSelection()
    }
    /// CROSS_FLICK action adapters use the held flag to call upAfterLongPress
    /// rather than invoking the ordinary command again on release.
    public mutating func finishSelection() -> Selection? {
        guard isActive else { return nil }
        let result = Selection(direction: selected, text: selectedText, longPress: longPress)
        cancel(); return result
    }
    public mutating func cancel() {
        selected = .tap; isActive = false; longPress = false; holdPending = false
    }
}
