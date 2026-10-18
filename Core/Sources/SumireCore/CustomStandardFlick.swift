import Foundation

/// Pinned StandardFlickInputController uses five sectors, with FAR directions
/// representing left/right and the nearest LEFT/RIGHT mapping as fallback.
public struct CustomStandardFlick {
    public let values: [String]
    public init(placement: ImportedCustomLayout.Placement) throws {
        let mappings = placement.source["flicks"]?.array ?? []
        let firstState = mappings.map { $0["stateIndex"]?.integer ?? 0 }.min() ?? 0
        var ordered: [(String, String)] = []
        for mapping in mappings {
            guard (mapping["stateIndex"]?.integer ?? 0) == firstState else { continue }
            guard let direction = mapping["flickDirection"]?.string,
                  ["TAP", "UP", "DOWN", "UP_LEFT", "UP_LEFT_FAR", "UP_RIGHT", "UP_RIGHT_FAR"].contains(direction),
                  !ordered.contains(where: { $0.0 == direction }) else {
                throw PersonalDataError("標準フリックの方向が不正または重複しています")
            }
            guard (mapping["actionType"]?.string ?? "INPUT_TEXT") == "INPUT_TEXT" else {
                throw PersonalDataError("標準フリックの文字入力以外の操作は未対応です")
            }
            ordered.append((direction, mapping["actionValue"]?.string ?? ""))
        }
        func value(_ direction: String, fallback: String? = nil) -> String {
            ordered.first(where: { $0.0 == direction })?.1
                ?? fallback.flatMap { side in ordered.first(where: { $0.0.contains(side) })?.1 } ?? ""
        }
        values = [value("TAP"), value("UP_LEFT_FAR", fallback: "LEFT"), value("UP"),
                  value("UP_RIGHT_FAR", fallback: "RIGHT"), value("DOWN")]
    }
    public static func direction(dx: Double, dy: Double, threshold: Double = 14) -> FlickDirection {
        guard max(abs(dx), abs(dy)) >= max(1, threshold) else { return .tap }
        let angle = atan2(dy, dx) * 180 / .pi
        if angle > -45 && angle <= 45 { return .right }
        if angle > 45 && angle <= 135 { return .down }
        if angle < -45 && angle >= -135 { return .up }
        return .left
    }
}
