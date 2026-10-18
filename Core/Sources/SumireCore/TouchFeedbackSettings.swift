import Foundation

/// Standard five-direction flick feedback. Other Sumire input styles retain
/// their own maps and require their corresponding controllers.
public struct TouchFeedbackSettings: Codable, Equatable {
    public static let storageKey = "input.touchFeedback"
    public var popupVisible = true
    public var popupScalePercent = 100.0
    public var popupTextSize = 19.0
    public var independentMultiTouch = false
    public var longPressMilliseconds = 300
    public init() {}
    public func normalized() -> Self {
        var value = self
        value.popupScalePercent = popupScalePercent.isFinite ? min(200, max(50, popupScalePercent)) : 100
        value.popupTextSize = popupTextSize.isFinite ? min(48, max(8, popupTextSize)) : 19
        value.longPressMilliseconds = min(2000, max(100, longPressMilliseconds))
        return value
    }
    public static func load(defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey), data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized()
    }
    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(normalized()) { defaults.set(data, forKey: Self.storageKey) }
    }
}
