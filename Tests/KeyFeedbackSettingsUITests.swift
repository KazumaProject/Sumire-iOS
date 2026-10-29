import XCTest

final class KeyFeedbackSettingsUITests: XCTestCase {
    func testKeyFeedbackSettingsPersistThroughVisibleSettings() {
        let app = XCUIApplication()
        app.launch()
        openKeyFeedbackSettings(in: app)

        let vibration = app.switches["feedback-key-vibration-enabled"].switches.firstMatch
        let sound = app.switches["feedback-key-sound-enabled"].switches.firstMatch
        reveal(vibration, in: app)
        reveal(sound, in: app)
        XCTAssertTrue(vibration.exists)
        XCTAssertTrue(sound.exists)

        resetSettings(in: app)
        reveal(vibration, in: app)
        XCTAssertEqual(vibration.value as? String, "1")
        reveal(sound, in: app)
        XCTAssertEqual(sound.value as? String, "0")

        reveal(vibration, in: app)
        vibration.tap()
        XCTAssertEqual(vibration.value as? String, "0")
        reveal(sound, in: app)
        sound.tap()
        XCTAssertEqual(sound.value as? String, "1")
        let volume = app.sliders["feedback-key-sound-volume"]
        reveal(volume, in: app)
        XCTAssertTrue(volume.isHittable)
        volume.adjust(toNormalizedSliderPosition: 0.42)
        let storedVolume = volume.value as? String
        XCTAssertNotNil(storedVolume)

        app.buttons["完了"].tap()
        app.terminate()
        app.launch()
        openKeyFeedbackSettings(in: app)

        reveal(vibration, in: app)
        XCTAssertEqual(vibration.value as? String, "0")
        reveal(sound, in: app)
        XCTAssertEqual(sound.value as? String, "1")
        let restoredVolume = app.sliders["feedback-key-sound-volume"]
        reveal(restoredVolume, in: app)
        XCTAssertEqual(restoredVolume.value as? String, storedVolume)

        resetSettings(in: app)
    }

    private func openKeyFeedbackSettings(in app: XCUIApplication) {
        let category = app.buttons["settings-category-input"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()

        let destination = app.buttons["settings-destination-touchFeedback"]
        for _ in 0..<5 where !destination.isHittable { app.swipeUp() }
        XCTAssertTrue(destination.isHittable)
        destination.tap()
    }

    private func resetSettings(in app: XCUIApplication) {
        let reset = app.buttons["標準に戻す"]
        reveal(reset, in: app)
        XCTAssertTrue(reset.isHittable)
        reset.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
    }
}
