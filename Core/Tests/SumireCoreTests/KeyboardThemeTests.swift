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
        XCTAssertEqual(legacy.seedARGB, 0xffa1_b359)
        let custom = KeyboardTheme(hue: 0.8, mode: .light, saturation: 0.1, brightness: 0.4)
        custom.save(defaults: defaults)
        XCTAssertEqual(KeyboardTheme.load(defaults: defaults), custom)
        XCTAssertEqual(custom.seedARGB, 0xff64_5c66)
        XCTAssertNotEqual(custom.tones(dark: false), legacy.tones(dark: false))
    }

    func testNeutralSeedAndInvalidValuesProduceFiniteBoundedTones() {
        XCTAssertEqual(KeyboardTheme(saturation: .nan, brightness: .infinity).saturation, 0.5)
        XCTAssertEqual(KeyboardTheme(saturation: .nan, brightness: .infinity).brightness, 0.7)
        for dark in [false, true] {
            for brightness in [-1.0, 0, 0.7, 1, 10] {
                let tones = KeyboardTheme(saturation: 0, brightness: brightness).tones(dark: dark)
                for tone in [tones.background, tones.key, tones.function, tones.accent] {
                    XCTAssertTrue((0...1).contains(tone.saturation))
                    XCTAssertTrue((0...1).contains(tone.hue))
                    XCTAssertTrue((0...1).contains(tone.brightness))
                    XCTAssertTrue(tone.brightness.isFinite)
                    XCTAssertEqual(tone.argb >> 24, 255)
                }
            }
        }
    }

    func testSavedHSVStillRepresentsTheSameRGBSeed() {
        for argb: UInt32 in [0xff00_0000, 0xffff_ffff, 0xff80_8080, 0xffff_0000, 0xff00_ff00,
                             0xff00_00ff, 0xffff_ff00, 0xff12_3456, 0xff67_50a4, 0xff01_0101] {
            let rgb = KeyboardThemeTone(argb: argb)
            XCTAssertEqual(KeyboardTheme(hue: rgb.hue, saturation: rgb.saturation,
                                         brightness: rgb.brightness).seedARGB, argb)
        }
        XCTAssertEqual(KeyboardTheme(hue: 1, saturation: 1, brightness: 1).seedARGB, 0xffff_0000)
    }

    func testKeyboardRolesFollowReferenceLightAndDarkDrawables() {
        let theme = KeyboardTheme()
        for dark in [false, true] {
            let roles = MaterialContentColors.resolve(seedARGB: theme.seedARGB, dark: dark)
            let tones = theme.tones(dark: dark)
            XCTAssertEqual(tones.background.argb, roles.surfaceContainer)
            XCTAssertEqual(tones.key.argb, dark ? roles.surfaceContainerHighest : roles.surface)
            XCTAssertEqual(tones.function.argb, roles.secondaryContainer)
            XCTAssertEqual(tones.keyPressed.argb, dark ? roles.surfaceContainerHigh : roles.surfaceVariant)
            XCTAssertEqual(tones.functionPressed.argb, dark ? 0xffd1_d1d1 : roles.surfaceContainerHigh)
            XCTAssertEqual(tones.accent.argb, roles.primary)
            XCTAssertEqual(tones.foreground.argb, roles.onSurface)
            XCTAssertEqual(tones.accentForeground.argb, roles.onPrimary)
        }
    }
}
