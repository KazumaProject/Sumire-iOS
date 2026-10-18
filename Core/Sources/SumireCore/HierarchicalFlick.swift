import Foundation

public enum HierarchicalKeyMode: String, Codable, Hashable { case normal, dakuten, handakuten }
public indirect enum HierarchicalFlickNode: Equatable {
    case input(String, triggers: HierarchicalKeyMode? = nil, guardedBoundary: Bool = false)
    case submenu([MultiFlickDirection: HierarchicalFlickNode], label: String? = nil,
                 cancelOnTap: Bool = false, parentContinuations: Set<MultiFlickDirection> = [])
    public var label: String? {
        switch self {
        case .input(let text, _, _): return text
        case .submenu(let map, let label, _, _): return label ?? map[.tap]?.label
        }
    }
}

/// Hierarchical controller uses the original DOWN center throughout the tree,
/// while the diagonal guard measures displacement from each submenu entry.
public struct HierarchicalFlickEvaluator {
    public typealias Map = [MultiFlickDirection: HierarchicalFlickNode]
    public let maps: [HierarchicalKeyMode: Map]
    public var modeSwitchAngleMargin = 20.0
    public private(set) var mode = HierarchicalKeyMode.normal
    public private(set) var selected = MultiFlickDirection.tap
    public private(set) var isActive = false
    public private(set) var expandedGuide = false
    public private(set) var holdPending = false
    public var depth: Int { stages.count }
    public var visibleMap: Map { effectiveMap }
    private var stages: [Map] = []
    private var entries: [MultiFlickDirection] = []
    private var anchors: [FlickPoint] = []
    private var down = FlickPoint(0, 0)
    private var config = MultiFlickConfiguration()
    private var jitterGuard = false
    public init(maps: [HierarchicalKeyMode: Map]) { self.maps = maps }
    public mutating func begin(at point: FlickPoint, configuration: MultiFlickConfiguration) {
        cancel(); config = configuration; down = point
        stages = [maps[.normal] ?? [:]]; entries = [.tap]; anchors = [point]
        isActive = true; holdPending = true
    }
    public mutating func hold() {
        guard isActive, holdPending, stages.count <= 1 else { return }
        holdPending = false; expandedGuide = true
    }
    private var continuationMap: Map {
        guard stages.count > 1, let entry = entries.last,
              case .submenu(_, _, _, let directions) = stages[stages.count - 2][entry] else { return [:] }
        let parent = stages[stages.count - 2]
        return Dictionary(uniqueKeysWithValues: directions.filter { $0 != entry }.compactMap { direction in
            parent[direction].map { (direction, $0) }
        })
    }
    private var effectiveMap: Map { continuationMap.merging(stages.last ?? [:]) { _, child in child } }
    private mutating func pop() { stages.removeLast(); entries.removeLast(); anchors.removeLast() }
    public mutating func move(to point: FlickPoint) {
        guard isActive, let map = stages.last else { return }
        let delta = point - down
        let enabled = Set(effectiveMap.keys)
        let candidate = config.direction(delta: delta, enabled: enabled, position: config.guidePosition(point, down: down))
        let direction = config.guarded(candidate, entry: entries.last ?? .tap,
            delta: point - (anchors.last ?? down), enabled: enabled)
        if direction == .tap {
            if jitterGuard { jitterGuard = false; return }
            if selected != .tap, stages.count > 1, let entry = entries.last,
               case .submenu(_, _, true, _) = stages[stages.count - 2][entry] {
                pop(); selected = entries.last ?? .tap
            }
            return
        }
        holdPending = false; jitterGuard = false
        var selectionMap = map
        var node = map[direction]
        if node == nil, let continuation = continuationMap[direction] {
            pop(); selectionMap = stages.last ?? [:]; node = continuation
        }
        if direction == selected {
            if let node { updateMode(node, direction: direction, delta: delta, selectionMap: selectionMap, point: point) }
            return
        }
        selected = direction
        switch node {
        case .input:
            if let node { updateMode(node, direction: direction, delta: delta, selectionMap: selectionMap, point: point) }
        case .submenu(let child, _, _, _):
            stages.append(child); entries.append(direction); anchors.append(point); jitterGuard = true
        case nil: break
        }
    }
    private mutating func updateMode(_ node: HierarchicalFlickNode, direction: MultiFlickDirection,
                                    delta: FlickPoint, selectionMap: Map, point: FlickPoint) {
        guard case .input(_, let trigger?, let guarded) = node, trigger != mode else { return }
        if guarded, let targetAngle = direction.angle {
            let angle = atan2(delta.y, delta.x) * 180 / .pi
            func difference(_ target: Double) -> Double { let raw = abs(angle - target); return min(raw, 360 - raw) }
            let alternatives = selectionMap.keys.filter { $0 != direction }.compactMap(\.angle).map(difference)
            if let nearest = alternatives.min(), difference(targetAngle) + modeSwitchAngleMargin >= nearest { return }
        }
        mode = trigger
        let root = maps[trigger] ?? maps[.normal] ?? [:]
        var rebuilt = [root], current = root
        for direction in entries.dropFirst() {
            guard case .submenu(let child, _, _, _) = current[direction] else {
                stages = [root]; entries = [entries.first ?? .tap]; anchors = [down]
                return
            }
            rebuilt.append(child); current = child
        }
        stages = rebuilt
    }
    public var selectedText: String? {
        let node = stages.last?[selected]
        let output: String?
        switch node {
        case .input(let text, _, _): output = text
        case .submenu(let next, _, _, _):
            if case .input(let text, _, _) = next[.tap] { output = text } else { output = nil }
        case nil: output = nil
        }
        return output?.isEmpty == false ? output : nil
    }
    public mutating func end() -> String? {
        guard isActive else { return nil }
        let output = selectedText; cancel(); return output
    }
    public mutating func cancel() {
        stages.removeAll(keepingCapacity: true); entries.removeAll(keepingCapacity: true); anchors.removeAll(keepingCapacity: true)
        selected = .tap; mode = .normal; isActive = false; expandedGuide = false; holdPending = false; jitterGuard = false
    }
}
