import Foundation

/// Direction order and angular centers match Android TfbiInputController at
/// 9506a0b. Diagonal centers intentionally are not 45-degree sectors.
public enum MultiFlickDirection: String, Codable, CaseIterable, Hashable {
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT"
    case upRight = "UP_RIGHT", downRight = "DOWN_RIGHT", downLeft = "DOWN_LEFT", upLeft = "UP_LEFT", tap = "TAP"
    var angle: Double? {
        switch self {
        case .right: return 0
        case .downRight: return 35
        case .down: return 90
        case .downLeft: return 125
        case .left: return 180
        case .upLeft: return -125
        case .up: return -90
        case .upRight: return -35
        case .tap: return nil
        }
    }
    var cell: (Int, Int) {
        switch self {
        case .upLeft: return (0, 0)
        case .up: return (1, 0)
        case .upRight: return (2, 0)
        case .left: return (0, 1)
        case .tap: return (1, 1)
        case .right: return (2, 1)
        case .downLeft: return (0, 2)
        case .down: return (1, 2)
        case .downRight: return (2, 2)
        }
    }
}
public struct FlickPoint: Equatable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static func - (lhs: Self, rhs: Self) -> Self { .init(lhs.x - rhs.x, lhs.y - rhs.y) }
}
public struct MultiFlickConfiguration {
    public var threshold = 14.0
    public var circularThreshold = true
    public var stableDiagonal = false
    public var guideGrid = false
    public var startsAtKeyCenter = false
    public var keyWidth = 44.0, keyHeight = 44.0
    public init() {}
    func crossed(_ delta: FlickPoint) -> Bool {
        let threshold = max(1, threshold)
        return circularThreshold ? hypot(delta.x, delta.y) >= threshold : max(abs(delta.x), abs(delta.y)) >= threshold
    }
    func guidePosition(_ point: FlickPoint, down: FlickPoint) -> FlickPoint {
        let offset = startsAtKeyCenter ? point - down : point
        return .init(min(1, max(0, offset.x / max(1, keyWidth) + (startsAtKeyCenter ? 0.5 : 0))),
                     min(1, max(0, offset.y / max(1, keyHeight) + (startsAtKeyCenter ? 0.5 : 0))))
    }
    func direction(delta: FlickPoint, enabled: Set<MultiFlickDirection>, position: FlickPoint) -> MultiFlickDirection {
        guard crossed(delta), !enabled.isEmpty else { return .tap }
        if guideGrid {
            func cell(_ coordinate: Double) -> Int { coordinate < 1 / 3 ? 0 : (coordinate < 2 / 3 ? 1 : 2) }
            let column = cell(position.x), row = cell(position.y)
            let candidate = MultiFlickDirection.allCases.first { $0.cell == (column, row) } ?? .tap
            if candidate == .tap || enabled.contains(candidate) { return candidate }
            return MultiFlickDirection.allCases.filter { enabled.contains($0) }.min {
                func distance(_ d: MultiFlickDirection) -> Double {
                    pow(position.x - (Double(d.cell.0) + 0.5) / 3, 2) + pow(position.y - (Double(d.cell.1) + 0.5) / 3, 2)
                }
                return distance($0) < distance($1)
            } ?? .tap
        }
        let angle = atan2(delta.y, delta.x) * 180 / .pi
        var best = MultiFlickDirection.tap, bestDifference = Double.infinity
        for candidate in MultiFlickDirection.allCases where enabled.contains(candidate) {
            guard let center = candidate.angle else { continue }
            let raw = abs(angle - center), difference = min(raw, 360 - raw)
            if difference < bestDifference { best = candidate; bestDifference = difference }
        }
        return bestDifference <= 70 ? best : .tap
    }
    func guarded(_ candidate: MultiFlickDirection, entry: MultiFlickDirection, delta: FlickPoint,
                 enabled: Set<MultiFlickDirection>) -> MultiFlickDirection {
        guard stableDiagonal, enabled.contains(entry) else { return candidate }
        let distance: Double
        switch (entry, candidate) {
        case (.right, .upRight), (.left, .upLeft): distance = -delta.y
        case (.right, .downRight), (.left, .downLeft): distance = delta.y
        case (.up, .upRight), (.down, .downRight): distance = delta.x
        case (.up, .upLeft), (.down, .downLeft): distance = -delta.x
        default: return candidate
        }
        return distance >= threshold ? candidate : entry
    }
}

/// Pure event evaluator for TWO_STEP_FLICK and STICKY_TWO_STEP_FLICK.
/// It returns selections, never emits text on DOWN/MOVE/hold. UP consumes once.
public struct TwoStepFlickEvaluator {
    public typealias Map = [MultiFlickDirection: [MultiFlickDirection: String]]
    public let map: Map
    public let longPressMap: Map
    public let sticky: Bool
    public private(set) var first = MultiFlickDirection.tap
    public private(set) var second = MultiFlickDirection.tap
    public private(set) var longPress = false
    public private(set) var isActive = false
    public private(set) var secondStage = false
    public private(set) var holdPending = false
    private var config = MultiFlickConfiguration()
    private var down = FlickPoint(0, 0), intermediate = FlickPoint(0, 0)
    public init(map: Map, longPressMap: Map = [:], sticky: Bool = false) {
        self.map = map; self.longPressMap = longPressMap; self.sticky = sticky
    }
    public var selectedText: String? {
        let alternate = longPress ? longPressMap[first]?[second] : nil
        let value = alternate?.isEmpty == false ? alternate : map[first]?[second]
        return value?.isEmpty == false ? value : nil
    }
    public mutating func begin(at point: FlickPoint, configuration: MultiFlickConfiguration) {
        cancel(); config = configuration; down = point; intermediate = point
        isActive = true; holdPending = true
    }
    public mutating func hold() {
        guard isActive, holdPending, !secondStage else { return }
        holdPending = false
        // Sticky's long press expands the guide only; it has no alternate map.
        if !sticky { longPress = true }
    }
    private var enabledFirst: Set<MultiFlickDirection> {
        Set(MultiFlickDirection.allCases.filter { direction in
            direction != .tap && (map[direction]?[.tap]?.isEmpty == false ||
                (longPress && longPressMap[direction]?.values.contains(where: { !$0.isEmpty }) == true))
        })
    }
    private var enabledSecond: Set<MultiFlickDirection> {
        Set(MultiFlickDirection.allCases.filter { direction in
            direction != .tap && (map[first]?[direction]?.isEmpty == false ||
                (longPress && longPressMap[first]?[direction]?.isEmpty == false))
        })
    }
    private func secondDirection(at point: FlickPoint) -> MultiFlickDirection {
        let delta = point - intermediate
        return config.guarded(config.direction(delta: delta, enabled: enabledSecond,
                position: config.guidePosition(point, down: down)), entry: first, delta: delta, enabled: enabledSecond)
    }
    public mutating func move(to point: FlickPoint) {
        guard isActive else { return }
        let position = config.guidePosition(point, down: down)
        if !secondStage {
            let delta = point - down
            guard config.crossed(delta) else { return }
            if sticky { holdPending = false }
            let direction = config.direction(delta: delta, enabled: enabledFirst, position: position)
            guard direction != .tap else { return }
            first = direction; second = direction; intermediate = point
            secondStage = true; holdPending = false
        } else {
            let centered = config.guideGrid ? (position.x >= 1 / 3 && position.x < 2 / 3 && position.y >= 1 / 3 && position.y < 2 / 3)
                : hypot(point.x - down.x, point.y - down.y) < 70
            if !sticky && centered {
                guard !longPress else { return }
                first = .tap; second = .tap; secondStage = false; holdPending = false
                return
            }
            let candidate = secondDirection(at: point)
            second = candidate == .tap ? (sticky ? second : first) : candidate
        }
    }
    public mutating func end(at point: FlickPoint) -> String? {
        guard isActive else { return nil }
        if secondStage {
            let candidate = secondDirection(at: point)
            if candidate != .tap || second == .tap { second = candidate }
        } else {
            first = config.direction(delta: point - down, enabled: enabledFirst, position: config.guidePosition(point, down: down))
            second = sticky || first == .tap ? .tap : first
        }
        let output = selectedText
        cancel()
        return output
    }
    public mutating func cancel() {
        isActive = false; first = .tap; second = .tap; longPress = false; secondStage = false; holdPending = false
    }
}
