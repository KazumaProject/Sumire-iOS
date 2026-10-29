import XCTest
@testable import SumireCore

final class ImportedRomajiShortcutIntegrationTests: XCTestCase {
    func testAndroidRuleOrderSurvivesLibrarySaveAndControlsF9F10AliasChoice() throws {
        let fixtures: [(json: String, order: [String], half: String, full: String)] = [
            (
                #"[{"name":"hu-first","mapData":{"hu":{"first":"ふ","second":2},"fu":{"first":"ふ","second":2}}}]"#,
                ["hu", "fu"],
                "hu",
                "ｈｕ"
            ),
            (
                #"[{"name":"fu-first","mapData":{"fu":{"first":"ふ","second":2},"hu":{"first":"ふ","second":2}}}]"#,
                ["fu", "hu"],
                "fu",
                "ｆｕ"
            )
        ]

        for fixture in fixtures {
            let defaultsName = "ImportedRomajiShortcutIntegrationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }

            var library = RomajiLibrary()
            library.profiles = try RomajiLibrary.importAndroid(Data(fixture.json.utf8))
            let imported = try XCTUnwrap(library.profiles.first)
            XCTAssertEqual(imported.ruleOrder, fixture.order)

            library.activeID = imported.id
            try library.save(defaults: defaults)

            let restored = try RomajiLibrary.load(defaults: defaults)
            XCTAssertEqual(restored.activeID, imported.id)
            XCTAssertEqual(restored.profiles.first?.ruleOrder, fixture.order)

            let converter = try restored.converter()
            XCTAssertEqual(
                PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .half, using: converter),
                fixture.half
            )
            XCTAssertEqual(
                PhysicalKeyboardAlphabeticConversion.convert("ふ", to: .full, using: converter),
                fixture.full
            )
        }
    }
}
