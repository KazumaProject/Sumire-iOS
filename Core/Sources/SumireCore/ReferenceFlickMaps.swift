import Foundation

public enum ReferenceFlickDefinition {
    case single(SingleStageFlickEvaluator.Style, map: [MultiFlickDirection: String], alternate: [MultiFlickDirection: String])
    case twoStep(TwoStepFlickEvaluator.Map, alternate: TwoStepFlickEvaluator.Map, sticky: Bool)
    case hierarchical([HierarchicalKeyMode: HierarchicalFlickEvaluator.Map], orders: [String: [MultiFlickDirection]])
    case circular([CircularFlickEvaluator.Map])
}

/// Loads only the selected profile's payload. No process-global cache retains
/// every layout/style. Consumers retain one profile while its keyboard is shown.
public struct ReferenceFlickMaps {
    public struct Key: Decodable, Equatable {
        public let keyId: String?
        public let label: String
        public let keyType: String
        public let row: Int
        public let column: Int
    }
    private struct Index: Decodable {
        struct Profile: Decodable { let resource: String; let keys: [Key] }
        let version: Int
        let sourceRevision: String
        let profiles: [String: Profile]
    }
    private struct Payload: Decodable {
        let flickKeyMaps: [String: [[String: LayoutJSON]]]
        let circularFlickKeyMaps: [String: [[String: LayoutJSON]]]
        let twoStepFlickKeyMaps: [String: [String: [String: String]]]
        let longPressFlickKeyMaps: [String: [String: String]]
        let twoStepLongPressKeyMaps: [String: [String: [String: String]]]
        let hierarchicalFlickMaps: [String: RawHierarchy]
    }
    private struct RawHierarchy: Decodable {
        let normalMap: [String: RawNode]
        let dakutenMap: [String: RawNode]?
        let handakutenMap: [String: RawNode]?
        let directionOrders: [String: [String]]
    }
    private struct RawNode: Decodable {
        let type: String
        let char: String?
        let triggersMode: String?
        let modeSwitchBoundary: String?
        let nextMap: [String: RawNode]?
        let label: String?
        let cancelOnTap: Bool?
        let parentContinuationDirections: [String]?
    }
    public let keys: [Key]
    public let sourceRevision: String
    public let payloadBytes: Int
    private let payload: Payload
    public init(arrangement: SumireKeyArrangement, mode: TenKeyMode, style: SumireFlickStyle) throws {
        let indexURL = Bundle.module.url(forResource: "flick-map-index", withExtension: "json")
        guard let indexURL else { throw Self.invalid("index missing") }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        let modeName: String
        switch mode { case .japanese: modeName = "HIRAGANA"; case .english: modeName = "ENGLISH"; case .number: modeName = "SYMBOLS" }
        let name = arrangement.rawValue + "-" + modeName + "-" + style.rawValue
        guard index.version == 1, let profile = index.profiles[name],
              let url = Bundle.module.url(forResource: profile.resource, withExtension: "json") else { throw Self.invalid(name) }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 else { throw Self.invalid("payload size") }
        payload = try JSONDecoder().decode(Payload.self, from: data)
        keys = profile.keys; sourceRevision = index.sourceRevision; payloadBytes = data.count
    }
    public func key(row: Int, column: Int) -> Key? { keys.first { $0.row == row && $0.column == column } }
    public func definition(for key: Key, settings: FlickStyleSettings = .init()) throws -> ReferenceFlickDefinition? {
        let id = key.keyId ?? key.label
        switch key.keyType {
        case "NORMAL", "CROSS_FLICK": return nil // Existing function-key controller owns these.
        case "STANDARD_FLICK", "PETAL_FLICK", "CENTER_GUIDE_FLICK":
            guard let states = payload.flickKeyMaps[id] ?? payload.flickKeyMaps[key.label], let map = states.first else { throw Self.invalid(id) }
            let style: SingleStageFlickEvaluator.Style = key.keyType == "STANDARD_FLICK" ? .standard : (key.keyType == "CENTER_GUIDE_FLICK" ? .centerGuide : .petal)
            return .single(style, map: try cardinalText(map), alternate: cardinal(payload.longPressFlickKeyMaps[id] ?? payload.longPressFlickKeyMaps[key.label] ?? [:]))
        case "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK":
            guard let raw = payload.twoStepFlickKeyMaps[id] ?? payload.twoStepFlickKeyMaps[key.label] else { throw Self.invalid(id) }
            let map = try twoStep(raw)
            let alternate = try twoStep(payload.twoStepLongPressKeyMaps[id] ?? payload.twoStepLongPressKeyMaps[key.label] ?? [:])
            return .twoStep(SumireFlickMapTransform.rotate(map, label: key.label, rotation: settings.rotation), alternate: alternate, sticky: key.keyType == "STICKY_TWO_STEP_FLICK")
        case "HIERARCHICAL_FLICK":
            guard let raw = payload.hierarchicalFlickMaps[id] ?? payload.hierarchicalFlickMaps[key.label] else { throw Self.invalid(id) }
            var maps: [HierarchicalKeyMode: HierarchicalFlickEvaluator.Map] = [.normal: try nodes(raw.normalMap)]
            if let map = raw.dakutenMap { maps[.dakuten] = try nodes(map) }
            if let map = raw.handakutenMap { maps[.handakuten] = try nodes(map) }
            let originalOrders = try raw.directionOrders.mapValues { try $0.map(Self.direction) }
            let orders = SumireFlickMapTransform.transformOrders(originalOrders, maps: maps, label: key.label,
                input: settings.threeStepInput, rotation: settings.rotation)
            maps = SumireFlickMapTransform.transform(maps, label: key.label, input: settings.threeStepInput, rotation: settings.rotation)
            return .hierarchical(maps, orders: orders)
        case "CIRCULAR_FLICK":
            if let maps = payload.circularFlickKeyMaps[id] ?? payload.circularFlickKeyMaps[key.label] {
                return .circular(try maps.map { map in
                    try Dictionary(uniqueKeysWithValues: map.map { (try Self.slot($0.key), try output($0.value)) })
                })
            }
            guard let maps = payload.flickKeyMaps[id] ?? payload.flickKeyMaps[key.label] else { throw Self.invalid(id) }
            let legacy: [String: CircularFlickSlot] = ["TAP": .tap, "UP": .slot0, "UP_RIGHT_FAR": .slot1, "DOWN": .slot2, "UP_LEFT_FAR": .slot3, "UP_RIGHT": .slot4, "UP_LEFT": .slot5]
            return .circular(try maps.map { map in try Dictionary(uniqueKeysWithValues: map.map { entry in
                guard let slot = legacy[entry.key] else { throw Self.invalid(entry.key) }
                return (slot, try output(entry.value))
            }) })
        default: throw Self.invalid(key.keyType)
        }
    }
    private func output(_ raw: LayoutJSON) throws -> CircularFlickOutput {
        if raw["type"]?.string == "Input", let text = raw["char"]?.string { return .text(text, label: raw["label"]?.string) }
        if raw["type"]?.string == "Action", let action = raw["action"] {
            let label = raw["label"]?.string
            if action["type"]?.string == "MoveCustomKeyboardTab", label == "⇄" { return .mapSwitch }
            return .referenceAction(action, label: label)
        }
        throw Self.invalid("action")
    }
    private func cardinalText(_ raw: [String: LayoutJSON]) throws -> [MultiFlickDirection: String] {
        var texts: [String: String] = [:]
        for (direction, value) in raw {
            guard case .text(let text, _) = try output(value) else { throw Self.invalid("non-text single stage action") }
            texts[direction] = text
        }
        return cardinal(texts)
    }
    private func cardinal(_ raw: [String: String]) -> [MultiFlickDirection: String] {
        var result: [MultiFlickDirection: String] = [:]
        for (direction, key) in [(MultiFlickDirection.tap,"TAP"),(.up,"UP"),(.down,"DOWN"),(.left,"UP_LEFT_FAR"),(.right,"UP_RIGHT_FAR")] {
            result[direction] = raw[key] ?? (direction == .left ? raw["UP_LEFT"] : direction == .right ? raw["UP_RIGHT"] : nil)
        }
        return result
    }
    private func twoStep(_ raw: [String: [String: String]]) throws -> TwoStepFlickEvaluator.Map {
        try Dictionary(uniqueKeysWithValues: raw.map { first, map in
            (try Self.direction(first), try Dictionary(uniqueKeysWithValues: map.map { (try Self.direction($0.key), $0.value) }))
        })
    }
    private func nodes(_ raw: [String: RawNode], depth: Int = 0) throws -> HierarchicalFlickEvaluator.Map {
        guard depth < 64 else { throw Self.invalid("hierarchy depth") }
        return try Dictionary(uniqueKeysWithValues: raw.map { direction, node in
            let value: HierarchicalFlickNode
            switch node.type {
            case "Input":
                guard let text = node.char else { throw Self.invalid("input") }
                let mode: HierarchicalKeyMode?
                if let raw = node.triggersMode {
                    guard let parsed = HierarchicalKeyMode(rawValue: raw.lowercased()) else { throw Self.invalid(raw) }
                    mode = parsed
                } else { mode = nil }
                value = .input(text, triggers: mode, guardedBoundary: node.modeSwitchBoundary == "I_COLUMN_DIACRITIC")
            case "SubMenu":
                guard let next = node.nextMap else { throw Self.invalid("submenu") }
                value = .submenu(try nodes(next, depth: depth + 1), label: node.label, cancelOnTap: node.cancelOnTap ?? false,
                    parentContinuations: Set(try (node.parentContinuationDirections ?? []).map(Self.direction)))
            default: throw Self.invalid(node.type)
            }
            return (try Self.direction(direction), value)
        })
    }
    private static func slot(_ raw: String) throws -> CircularFlickSlot {
        if raw == "TAP" { return .tap }
        guard raw.hasPrefix("SLOT_"), let number = Int(raw.dropFirst(5)), let value = CircularFlickSlot(rawValue: number), number >= 0 else { throw invalid(raw) }
        return value
    }
    private static func direction(_ raw: String) throws -> MultiFlickDirection {
        guard let result = MultiFlickDirection(rawValue: raw) else { throw invalid(raw) }
        return result
    }
    private static func invalid(_ value: String) -> PersonalDataError { PersonalDataError("標準フリック定義が不正です: \(value)") }
}
