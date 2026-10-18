import Foundation
import MaterialColorUtilities

/// Material 1.13.0 content-based roles used by Android Sumire. The pinned Swift
/// implementation is checked against that Java version, including contrast curves.
public struct MaterialContentColors: Equatable {
    public let surface: UInt32
    public let surfaceContainer: UInt32
    public let surfaceContainerLow: UInt32
    public let surfaceContainerHigh: UInt32
    public let surfaceContainerHighest: UInt32
    public let surfaceVariant: UInt32
    public let onSurface: UInt32
    public let secondaryContainer: UInt32
    public let onSecondaryContainer: UInt32
    public let primary: UInt32
    public let onPrimary: UInt32

    public static func resolve(seedARGB: UInt32, dark: Bool, contrastLevel: Double = 0) -> Self {
        let contrast = contrastLevel.isFinite ? min(1, max(-1, contrastLevel)) : 0
        let key = CacheKey(seed: seedARGB | 0xff00_0000, dark: dark, contrast: contrast)
        // Upstream DynamicColor has small mutable caches. Serialize access as
        // themes may also be requested by non-UI clients of the core library.
        Cache.lock.lock()
        defer { Cache.lock.unlock() }
        if let found = Cache.values[key] { return found }
        let scheme = SchemeContent(sourceColorHct: Hct(Int(key.seed)), isDark: dark, contrastLevel: contrast)
        let colors = Self(
            surface: UInt32(scheme.surface),
            surfaceContainer: UInt32(scheme.surfaceContainer),
            surfaceContainerLow: UInt32(scheme.surfaceContainerLow),
            surfaceContainerHigh: UInt32(scheme.surfaceContainerHigh),
            surfaceContainerHighest: UInt32(scheme.surfaceContainerHighest),
            surfaceVariant: UInt32(scheme.surfaceVariant),
            onSurface: UInt32(scheme.onSurface),
            secondaryContainer: UInt32(scheme.secondaryContainer),
            onSecondaryContainer: UInt32(scheme.onSecondaryContainer),
            primary: UInt32(scheme.primary),
            onPrimary: UInt32(scheme.onPrimary))
        if Cache.order.count == 8 { Cache.values.removeValue(forKey: Cache.order.removeFirst()) }
        Cache.order.append(key)
        Cache.values[key] = colors
        return colors
    }

    private struct CacheKey: Hashable {
        let seed: UInt32
        let dark: Bool
        let contrast: Double
    }
    private enum Cache {
        static let lock = NSLock()
        static var order: [CacheKey] = []
        static var values: [CacheKey: MaterialContentColors] = [:]
    }
}

/// Bundled, offline notices for the exact code included in the application.
public enum MaterialColorUtilitiesNotice {
    public static var attributionURL: URL? {
        Bundle.module.url(forResource: "MaterialColorUtilities-NOTICE", withExtension: "txt")
    }
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: "MaterialColorUtilities-LICENSE", withExtension: "txt")
    }
}
