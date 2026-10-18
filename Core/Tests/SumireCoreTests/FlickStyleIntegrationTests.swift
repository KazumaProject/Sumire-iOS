import XCTest
@testable import SumireCore
final class FlickStyleIntegrationTests: XCTestCase {
    func testEveryTextKeyResolvesItsSelectedProfile() throws {
        for arrangement in SumireKeyArrangement.allCases {
            for mode in [TenKeyMode.japanese, .english, .number] {
                for style in SumireFlickStyle.allCases {
                    var settings = FlickStyleSettings(); settings.style = style
                    let profile = try ReferenceFlickMaps(arrangement: arrangement, mode: mode, style: style)
                    for key in arrangement.layout(mode: mode).keys where key.action == .text {
                        let reference = try XCTUnwrap(profile.key(row: key.row, column: key.column))
                        XCTAssertNotNil(try profile.definition(for: reference, settings: settings), "\(arrangement) \(mode) \(style) \(key.id)")
                    }
                }
            }
        }
    }
    func testSettingsBackupAndAbsentValueMigration() throws {
        let suite = "FlickStyleIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FlickStyleSettings.load(defaults: defaults), FlickStyleSettings())
        defaults.set("flick", forKey: "sumire.keyArrangement")
        var settings = FlickStyleSettings(); settings.style = .donut; settings.circularDirectionCount = 7
        settings.rotation = .counterclockwise; settings.threeStepInput = .voiced
        settings.save(defaults: defaults)
        let backup = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        defaults.removeObject(forKey: FlickStyleSettings.storageKey)
        try backup.restore(defaults: defaults)
        XCTAssertEqual(FlickStyleSettings.load(defaults: defaults), settings)
        XCTAssertEqual(defaults.string(forKey: "sumire.keyArrangement"), "flick")
        var invalid = settings; invalid.circularDirectionCount = 100
        defaults.set(try JSONEncoder().encode(invalid), forKey: FlickStyleSettings.storageKey)
        XCTAssertThrowsError(try KeyboardSettingsSnapshot.capture(defaults: defaults))
    }
    func testExplicitReferenceMarkersDoNotCycleOrBecomeLiteralText() {
        XCTAssertEqual(SumireFlickMarker.small.applying(to: "づ"), "っ")
        XCTAssertEqual(SumireFlickMarker.voiced.applying(to: "ぱ"), "ば")
        XCTAssertEqual(SumireFlickMarker.semivoiced.applying(to: "ば"), "ぱ")
        XCTAssertNil(SumireFlickMarker.voiced.applying(to: "が"))
        XCTAssertNil(SumireFlickMarker.small.applying(to: "ぁ"))
        XCTAssertNil(SumireFlickMarker.semivoiced.applying(to: "😀"))
        XCTAssertNil(SumireFlickMarker(rawValue: "^_^"))
    }
}
