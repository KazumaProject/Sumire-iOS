import XCTest

final class SettingsDashboardTests: XCTestCase {
    func testCategoriesAndSharingDetailsUseVisibleNavigation() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["settings-preview"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sumire settings dashboard"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["settings-sharing-status"].tap()
        XCTAssertTrue(app.staticTexts["キーボードの準備と共有"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["sharing-status-detail"].exists)
        app.buttons["完了"].tap()
        app.buttons["settings-category-input"].tap()
        XCTAssertTrue(app.buttons["settings-destination-keyboards"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings-category-appearance"].tap()
        XCTAssertTrue(app.buttons["settings-destination-theme"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings-destination-candidates"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let application = app.buttons["settings-category-app"]
        for _ in 0..<4 where !application.isHittable { app.swipeUp() }
        XCTAssertTrue(application.isHittable); application.tap()
        app.buttons["settings-destination-licenses"].tap()
        XCTAssertTrue(app.buttons["完了"].waitForExistence(timeout: 3))
        app.buttons["完了"].tap()
    }

    func testSearchOpensThemeAndReportsNoResults() {
        let app = XCUIApplication(); app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Material")
        let theme = app.buttons["settings-destination-theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 3)); theme.tap()
        XCTAssertTrue(app.buttons["theme-preset-0"].waitForExistence(timeout: 3))
        app.buttons["完了"].tap()
        app.terminate(); app.launch()
        let fresh = app.searchFields.firstMatch; fresh.tap(); fresh.typeText("zzzz-no-setting")
        XCTAssertFalse(app.buttons["settings-destination-theme"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "zzzz-no-setting")).firstMatch.exists)
    }

    func testConversionSettingsExposeAndroidPredictionControls() {
        let app = XCUIApplication(); app.launch()
        app.buttons["settings-category-input"].tap()
        let conversion = app.buttons["settings-destination-conversion"]
        XCTAssertTrue(conversion.waitForExistence(timeout: 3)); conversion.tap()
        XCTAssertTrue(app.staticTexts["変換候補の予測"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["prediction-lookahead"].exists)
        let aggressiveness = app.descendants(matching: .any)["prediction-aggressiveness"]
        XCTAssertTrue(aggressiveness.exists)
        XCTAssertEqual(aggressiveness.buttons.count, 3)
        XCTAssertEqual(aggressiveness.buttons.element(boundBy: 0).label, "控えめ")
        XCTAssertEqual(aggressiveness.buttons.element(boundBy: 1).label, "標準")
        XCTAssertEqual(aggressiveness.buttons.element(boundBy: 2).label, "積極的")
    }

    func testPreviewRowsAndThemeKeepUncommittedInput() {
        let app = XCUIApplication(); app.launchArguments = ["-liveConversion", "NO"]
        app.launch(); app.buttons["settings-preview"].tap()
        let editor = app.textViews["入力テスト"]; XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["入力オプション"].tap()
        XCTAssertTrue(app.switches["ライブ変換"].exists)
        app.buttons["入力オプション"].tap(); editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["50音"].tap()
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        app.buttons["3段"].tap(); XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["preview-settings"].tap(); app.buttons["キーボードの配色"].tap()
        XCTAssertTrue(app.buttons["完了"].waitForExistence(timeout: 3)); app.buttons["完了"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["う"].tap(); XCTAssertEqual(editor.value as? String, "あいう")
    }

    func testLargeTextKeepsPreviewAndCategoryReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let preview = app.buttons["settings-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(preview.frame.height, 44)
        let appearance = app.buttons["settings-category-appearance"]
        for _ in 0..<5 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); appearance.tap()
        XCTAssertTrue(app.buttons["settings-destination-theme"].waitForExistence(timeout: 3))
    }
}
