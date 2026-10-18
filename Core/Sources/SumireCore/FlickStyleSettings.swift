import Foundation

public enum SumireFlickStyle: String, Codable, CaseIterable {
    case standard = "default", circle, twoStep = "second-flick", threeStep = "third-flick"
    case centerGuide = "center-guide-flick", donut = "sumire"
    public var referenceKeyType: String {
        switch self {
        case .standard: return "PETAL_FLICK"
        case .circle: return "STANDARD_FLICK"
        case .twoStep: return "TWO_STEP_FLICK"
        case .threeStep: return "HIERARCHICAL_FLICK"
        case .centerGuide: return "CENTER_GUIDE_FLICK"
        case .donut: return "CIRCULAR_FLICK"
        }
    }
}
public struct FlickStyleSettings: Codable, Equatable {
    public enum Rotation: String, Codable, CaseIterable { case standard = "default", clockwise, counterclockwise }
    public enum ThreeStepInput: String, Codable, CaseIterable { case contracted, voiced, all }
    public enum Diagonal: String, Codable, CaseIterable { case legacy, stable }
    public enum StartPosition: String, Codable, CaseIterable { case touchPoint = "touch_point", keyCenter = "key_center" }
    public enum Presentation: String, Codable, CaseIterable { case legacyGrid = "legacy_grid", guideAboveKey = "guide_above_key" }
    public static let storageKey = "sumire.flickStyle"
    public var style = SumireFlickStyle.standard
    public var rotation = Rotation.standard
    public var threeStepInput = ThreeStepInput.all
    public var diagonal = Diagonal.legacy
    public var startPosition = StartPosition.touchPoint
    public var presentation = Presentation.legacyGrid
    public var circularDirectionCount = 4
    public var hierarchicalModeAngleMargin = 20
    public init() {}
    public var normalized: Self {
        var value = self
        value.circularDirectionCount = min(7, max(4, value.circularDirectionCount))
        value.hierarchicalModeAngleMargin = min(34, max(0, value.hierarchicalModeAngleMargin))
        return value
    }
    public static func load(defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey), data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value.normalized
    }
    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: Self.storageKey) }
    }
}
