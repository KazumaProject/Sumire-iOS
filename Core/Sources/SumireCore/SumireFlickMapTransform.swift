import Foundation

/// Port of SumireFlickRotationMapper / SumireFlickInputModeMapper (9506a0b).
/// Rotation changes voiced candidates around the vowel axis, not the whole key.
public enum SumireFlickMapTransform {
    private static let voicedLabels: Set<String> = ["か", "さ", "た", "は"]
    private static let kanaLabels: Set<String> = ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ"]
    private static func shouldSwap(_ axis: MultiFlickDirection, _ rotation: FlickStyleSettings.Rotation) -> Bool {
        switch rotation {
        case .standard: return false
        case .clockwise: return [.left, .up, .down].contains(axis)
        case .counterclockwise: return axis == .right
        }
    }
    private static func swap(_ direction: MultiFlickDirection, axis: MultiFlickDirection) -> MultiFlickDirection {
        let pair: [MultiFlickDirection]
        switch axis {
        case .left: pair = [.upLeft, .downLeft]
        case .right: pair = [.upRight, .downRight]
        case .up: pair = [.upLeft, .upRight]
        case .down: pair = [.downLeft, .downRight]
        default: return direction
        }
        return direction == pair[0] ? pair[1] : (direction == pair[1] ? pair[0] : direction)
    }
    public static func rotate(_ map: TwoStepFlickEvaluator.Map, label: String,
                              rotation: FlickStyleSettings.Rotation) -> TwoStepFlickEvaluator.Map {
        guard voicedLabels.contains(label) else { return map }
        return map.reduce(into: [:]) { result, row in
            result[row.key] = shouldSwap(row.key, rotation) ? Dictionary(uniqueKeysWithValues: row.value.map { (swap($0.key, axis: row.key), $0.value) }) : row.value
        }
    }
    public static func transform(_ maps: [HierarchicalKeyMode: HierarchicalFlickEvaluator.Map], label: String,
                                 input: FlickStyleSettings.ThreeStepInput, rotation: FlickStyleSettings.Rotation) -> [HierarchicalKeyMode: HierarchicalFlickEvaluator.Map] {
        var result = maps
        if input != .all && kanaLabels.contains(label) {
            result = result.mapValues { filter($0, input: input) }
            if input == .contracted { result.removeValue(forKey: .dakuten); result.removeValue(forKey: .handakuten) }
        }
        guard input != .contracted, voicedLabels.contains(label), rotation != .standard else { return result }
        return result.mapValues { root in
            root.reduce(into: [:]) { result, entry in
                if shouldSwap(entry.key, rotation), case .submenu(let child, let label, let cancel, let continuation) = entry.value {
                    result[entry.key] = .submenu(rotateStage(child, axis: entry.key), label: label, cancelOnTap: cancel, parentContinuations: continuation)
                } else { result[entry.key] = entry.value }
            }
        }
    }
    private static func rotateStage(_ map: HierarchicalFlickEvaluator.Map, axis: MultiFlickDirection) -> HierarchicalFlickEvaluator.Map {
        Dictionary(uniqueKeysWithValues: map.map { entry in
            let direction = swap(entry.key, axis: axis)
            let node: HierarchicalFlickNode
            if case .submenu(let child, let label, let cancel, let continuation) = entry.value {
                node = .submenu(entry.key != direction ? rotateStage(child, axis: axis) : child, label: label,
                    cancelOnTap: cancel, parentContinuations: Set(continuation.map { swap($0, axis: axis) }))
            } else { node = entry.value }
            return (direction, node)
        })
    }
    private static func allowed(_ text: String, input: FlickStyleSettings.ThreeStepInput) -> Bool {
        guard input != .all else { return true }
        if !text.isEmpty && text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) { return false }
        switch input {
        case .all: return true
        case .contracted: return !text.decomposedStringWithCanonicalMapping.unicodeScalars.contains { $0.value == 0x3099 || $0.value == 0x309a }
        case .voiced: return text.unicodeScalars.count <= 1 || !text.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
        }
    }
    private static func filter(_ map: HierarchicalFlickEvaluator.Map, input: FlickStyleSettings.ThreeStepInput) -> HierarchicalFlickEvaluator.Map {
        var result: HierarchicalFlickEvaluator.Map = [:]
        for (direction, node) in map {
            switch node {
            case .input(let text, _, _): if allowed(text, input: input) { result[direction] = node }
            case .submenu(let child, let label, let cancel, let continuation):
                let filtered = filter(child, input: input)
                if !filtered.isEmpty && (label.map { allowed($0, input: input) } ?? true) {
                    result[direction] = .submenu(filtered, label: label, cancelOnTap: cancel, parentContinuations: continuation)
                }
            }
        }
        let directions = Set(result.keys)
        return result.mapValues { node in
            if case .submenu(let child, let label, let cancel, let continuation) = node {
                return .submenu(child, label: label, cancelOnTap: cancel, parentContinuations: continuation.intersection(directions))
            }
            return node
        }
    }
}
