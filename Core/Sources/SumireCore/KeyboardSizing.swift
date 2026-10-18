import Foundation

public enum KeyboardOrientation: String, Codable { case portrait, landscape }

/// Height excludes candidate rows and the system bottom inset. Width is relative to the host's available
/// width, so a saved value also survives a change of device or window size.
public struct KeyboardSize: Codable, Equatable {
    public var height: Double
    public var width: Double
    public var alignment: Double
    public init(height: Double, width: Double = 1, alignment: Double = 0.5) {
        self.height = height; self.width = width; self.alignment = alignment
    }
    public static func standard(_ orientation: KeyboardOrientation) -> Self {
        // Reference default key grid: 220 dp. The iOS surface also reserves
        // 27 pt reading + 14 pt outer padding + two 7 pt stack gaps.
        // Candidate rows are added separately by KeyboardSurface.
        Self(height: 275)
    }
    public var normalized: Self {
        Self(height: height.isFinite ? min(600, max(160, height)) : 275,
             width: width.isFinite ? min(1, max(0.5, width)) : 1,
             alignment: alignment.isFinite ? min(1, max(0, alignment)) : 0.5)
    }
}

public struct KeyboardSizingStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public static func key(_ orientation: KeyboardOrientation) -> String { "keyboardSize." + orientation.rawValue }
    public func load(_ orientation: KeyboardOrientation) -> KeyboardSize {
        guard let data = defaults.data(forKey: Self.key(orientation)),
              let size = try? JSONDecoder().decode(KeyboardSize.self, from: data) else {
            return .standard(orientation)
        }
        return size.normalized
    }
    public func save(_ size: KeyboardSize, for orientation: KeyboardOrientation) throws {
        // Store all dimensions together, so readers never observe a mixed edit.
        defaults.set(try JSONEncoder().encode(size.normalized), forKey: Self.key(orientation))
    }
    public func reset(_ orientation: KeyboardOrientation) { defaults.removeObject(forKey: Self.key(orientation)) }
}
