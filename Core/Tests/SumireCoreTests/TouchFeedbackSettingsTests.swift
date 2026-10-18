import XCTest
@testable import SumireCore
final class TouchFeedbackSettingsTests: XCTestCase {
    func testReferenceDefaultsAndPersistence() {
        let suite = "TouchFeedbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TouchFeedbackSettings.load(defaults: defaults)
        XCTAssertTrue(settings.popupVisible)
        XCTAssertFalse(settings.independentMultiTouch)
        XCTAssertEqual(settings.longPressMilliseconds, 300)
        XCTAssertEqual(settings.popupTextSize, 19)
        settings.independentMultiTouch = true
        settings.popupTextSize = 25
        settings.save(defaults: defaults)
        XCTAssertEqual(TouchFeedbackSettings.load(defaults: defaults), settings)
        defaults.set(Data("invalid".utf8), forKey: TouchFeedbackSettings.storageKey)
        XCTAssertEqual(TouchFeedbackSettings.load(defaults: defaults), TouchFeedbackSettings())
    }
    func testBoundsAndNonFiniteValues() {
        var value = TouchFeedbackSettings()
        value.longPressMilliseconds = -1
        value.popupScalePercent = .infinity
        value.popupTextSize = .nan
        XCTAssertEqual(value.normalized().longPressMilliseconds, 100)
        XCTAssertEqual(value.normalized().popupScalePercent, 100)
        XCTAssertEqual(value.normalized().popupTextSize, 19)
        value.longPressMilliseconds = 3000
        value.popupScalePercent = 10
        value.popupTextSize = 100
        XCTAssertEqual(value.normalized().longPressMilliseconds, 2000)
        XCTAssertEqual(value.normalized().popupScalePercent, 50)
        XCTAssertEqual(value.normalized().popupTextSize, 48)
    }
}
