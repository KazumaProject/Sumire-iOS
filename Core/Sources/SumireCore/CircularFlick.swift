import Foundation

public enum CircularFlickSlot: Int, Codable, CaseIterable, Hashable {
    case tap = -1, slot0, slot1, slot2, slot3, slot4, slot5, slot6
}
public struct CircularFlickRange: Equatable {
    public var start: Double, sweep: Double
    public init(start: Double, sweep: Double) { self.start = start; self.sweep = sweep }
    static func normalize(_ value: Double) -> Double { let value = value.truncatingRemainder(dividingBy: 360); return value < 0 ? value + 360 : value }
    func contains(_ angle: Double) -> Bool {
        let start = Self.normalize(start), angle = Self.normalize(angle)
        if sweep >= 360 { return true }
        let end = start + sweep
        return end > 360 ? angle >= start || angle < Self.normalize(end) : angle >= start && angle < end
    }
    public static func even(count: Int) -> [CircularFlickSlot: Self] {
        let count = min(7, max(4, count)), sweep = 360 / Double(min(7, max(4, count)))
        return Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            (CircularFlickSlot(rawValue: index)!, Self(start: normalize(270 - sweep / 2 + sweep * Double(index)), sweep: sweep))
        })
    }
}
public enum CircularFlickOutput: Equatable {
    case text(String, label: String? = nil)
    /// Caller dispatches the preserved action identifier; no Android action is
    /// silently substituted. mapSwitch corresponds to MoveCustomKeyboardTab/⇄.
    case action(String, value: String? = nil, label: String)
    case mapSwitch
    case referenceAction(LayoutJSON, label: String?)
    var isEffective: Bool {
        if case .text(let text, let label) = self { return !text.isEmpty || label?.isEmpty == false }
        return true
    }
}
public struct CircularFlickEvaluator {
    public typealias Map = [CircularFlickSlot: CircularFlickOutput]
    public let maps: [Map]
    public let directionCount: Int
    public let configuredRanges: [CircularFlickSlot: CircularFlickRange]
    public private(set) var mapIndex = 0
    public private(set) var selected = CircularFlickSlot.tap
    public private(set) var isActive = false
    public private(set) var expandedGuide = false
    public private(set) var holdPending = false
    private var down = FlickPoint(0, 0)
    private var config = MultiFlickConfiguration()
    public init(maps: [Map], directionCount: Int = 4, ranges: [CircularFlickSlot: CircularFlickRange]? = nil) {
        self.maps = maps; self.directionCount = min(7, max(4, directionCount))
        self.configuredRanges = ranges ?? CircularFlickRange.even(count: directionCount)
    }
    public var currentMap: Map { maps.indices.contains(mapIndex) ? maps[mapIndex] : [:] }
    public var activeSlots: [CircularFlickSlot] {
        (0..<directionCount).compactMap { index in
            let slot = CircularFlickSlot(rawValue: index)!
            return index < 4 || currentMap[slot]?.isEffective == true ? slot : nil
        }
    }
    public var effectiveRanges: [CircularFlickSlot: CircularFlickRange] {
        let slots = activeSlots
        if slots.count == directionCount && slots.allSatisfy({ configuredRanges[$0] != nil }) { return configuredRanges }
        let compact = CircularFlickRange.even(count: slots.count)
        return Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element, compact[CircularFlickSlot(rawValue: $0.offset)!]!) })
    }
    private var switchSlot: CircularFlickSlot? { activeSlots.first { currentMap[$0] == .mapSwitch } }
    public mutating func begin(at point: FlickPoint, configuration: MultiFlickConfiguration) {
        cancel(); down = point; config = configuration; isActive = true; holdPending = true
    }
    public mutating func hold() {
        guard isActive, holdPending else { return }
        holdPending = false; expandedGuide = true
    }
    public func direction(at point: FlickPoint) -> CircularFlickSlot {
        let delta = point - down
        guard config.crossed(delta) else { return .tap }
        let angle = atan2(delta.y, delta.x) * 180 / .pi, ranges = effectiveRanges
        return activeSlots.first { ranges[$0]?.contains(angle) == true } ?? .tap
    }
    public mutating func move(to point: FlickPoint) {
        guard isActive else { return }
        let next = direction(at: point)
        if next != selected && next != .tap { holdPending = false }
        if maps.count > 1, next == switchSlot {
            expandedGuide = true
            if selected != next { mapIndex = (mapIndex + 1) % maps.count }
        }
        selected = next
    }
    public mutating func end(at point: FlickPoint) -> CircularFlickOutput? {
        guard isActive else { return nil }
        let final = direction(at: point)
        let output = maps.count > 1 && final == switchSlot ? nil : currentMap[final]
        cancel(); return output
    }
    public mutating func cancel() {
        isActive = false; expandedGuide = false; holdPending = false; mapIndex = 0; selected = .tap
    }
}
