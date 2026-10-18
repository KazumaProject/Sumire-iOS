import XCTest
@testable import SumireCore

final class KeyboardThemeTests: XCTestCase {
    func testThemePersistsAndInvalidValuesFallBack() {
        let name = "SumireThemeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(KeyboardTheme.load(defaults: defaults), KeyboardTheme())
        let theme = KeyboardTheme(hue: 0.2, mode: .dark)
        theme.save(defaults: defaults)
        XCTAssertEqual(KeyboardTheme.load(defaults: UserDefaults(suiteName: name)!), theme)
        defaults.set("future-mode", forKey: "theme.mode")
        defaults.set(-5, forKey: "theme.hue")
        XCTAssertEqual(KeyboardTheme.load(defaults: defaults), KeyboardTheme(hue: 0, mode: .system))
        XCTAssertEqual(KeyboardTheme(hue: .nan).hue, 0.73)
    }
    func testSeedColorPersistsWithoutChangingLegacyHue() {
        let name = "SumireThemeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.2, forKey: "theme.hue")
        let legacy = KeyboardTheme.load(defaults: defaults)
        XCTAssertEqual(legacy.saturation, 0.5)
        XCTAssertEqual(legacy.brightness, 0.7)
        XCTAssertEqual(legacy.tones(dark: false).key.brightness, 1)
        XCTAssertEqual(legacy.tones(dark: true).accent.brightness, 0.75)
        let custom = KeyboardTheme(hue: 0.8, mode: .light, saturation: 0.1, brightness: 0.4)
        custom.save(defaults: defaults)
        XCTAssertEqual(KeyboardTheme.load(defaults: defaults), custom)
        XCTAssertEqual(custom.tones(dark: false).accent.saturation, 0.1)
        XCTAssertEqual(custom.tones(dark: false).accent.brightness, 0.4)
    }

    func testNeutralSeedAndInvalidValuesProduceFiniteBoundedTones() {
        XCTAssertEqual(KeyboardTheme(saturation: .nan, brightness: .infinity).saturation, 0.5)
        XCTAssertEqual(KeyboardTheme(saturation: .nan, brightness: .infinity).brightness, 0.7)
        for dark in [false, true] {
            for brightness in [-1.0, 0, 0.7, 1, 10] {
                let tones = KeyboardTheme(saturation: 0, brightness: brightness).tones(dark: dark)
                for tone in [tones.background, tones.key, tones.function, tones.accent] {
                    XCTAssertEqual(tone.saturation, 0)
                    XCTAssertTrue((0...1).contains(tone.brightness))
                    XCTAssertTrue(tone.brightness.isFinite)
                }
            }
        }
    }
}
