import XCTest

final class FlickStyleIntegrationUITests: XCTestCase {
    private func encodedStyle(_ style: String, start: String = "touch_point") -> String {
        let settings: [String: Any] = ["style": style, "rotation": "default", "threeStepInput": "all",
            "diagonal": "legacy", "startPosition": start, "presentation": "legacy_grid",
            "circularDirectionCount": 4, "hierarchicalModeAngleMargin": 20]
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }
    private func launch(_ app: XCUIApplication, arrangement: String = "toggle", style: String? = nil,
                        start: String = "touch_point") -> XCUIElement {
        app.launchArguments = ["-liveConversion", "NO", "-learningEnabled", "NO", "-sumire.keyArrangement", arrangement]
        if let style { app.launchArguments += ["-sumire.flickStyle", encodedStyle(style, start: start)] }
        launchInputPreview(app)
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        app.collectionViews.buttons["Sumire"].tap()
        XCTAssertTrue(app.buttons["sumire-a"].waitForExistence(timeout: 3))
        return editor
    }
    func testEveryArrangementModeAndStyleUsesLiveSurface() {
        let app = XCUIApplication()
        for arrangement in ["toggle", "flick", "switch-mode-effective"] {
            for style in ["default", "circle", "second-flick", "third-flick", "center-guide-flick", "sumire"] {
                let editor = launch(app, arrangement: arrangement, style: style)
                app.buttons["sumire-a"].tap()
                XCTAssertEqual(editor.value as? String, "あ", "\(arrangement)/\(style)/Japanese")
                app.buttons["sumire-delete_key"].tap()
                app.buttons[arrangement == "toggle" ? "sumire-change_input_mode_key" : "sumire-english_mode"].tap()
                app.buttons["sumire-a"].tap()
                XCTAssertEqual(editor.value as? String, "@", "\(arrangement)/\(style)/English")
                app.buttons["sumire-delete_key"].tap()
                app.buttons[arrangement == "toggle" ? "sumire-change_input_mode_key" : "sumire-number_mode"].tap()
                app.buttons["sumire-a"].tap()
                XCTAssertEqual(editor.value as? String, "1", "\(arrangement)/\(style)/Number")
                app.terminate()
            }
        }
    }
    func testPureTapKeepsToggleAndFlickBreaksToggle() {
        let app = XCUIApplication()
        let input = launch(app, style: "default")
        let key = app.buttons["sumire-ka"]
        key.tap(); key.tap()
        XCTAssertEqual(input.value as? String, "き")
        let origin = key.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(.init(dx: 0, dy: -65)))
        XCTAssertEqual(input.value as? String, "きく")
        key.tap(); XCTAssertEqual(input.value as? String, "きくか")
    }
    func testRepeatedCenterTapsFollowEachReferenceController() {
        let app = XCUIApplication()
        for (style, expected) in [("default", "き"), ("circle", "かか"), ("second-flick", "き"),
                                  ("third-flick", "かか"), ("center-guide-flick", "き"), ("sumire", "き")] {
            let input = launch(app, style: style)
            app.buttons["sumire-ka"].tap(); app.buttons["sumire-ka"].tap()
            XCTAssertEqual(input.value as? String, expected, style)
            app.terminate()
        }
    }
    func testMultiStageDirectionsDeliveredByUIKit() {
        let app = XCUIApplication()
        for (style, dx, expected) in [("second-flick", -65.0, "き"), ("third-flick", -65.0, "き"), ("sumire", 65.0, "け")] {
            let input = launch(app, style: style)
            let key = app.buttons["sumire-ka"]
            let origin = key.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(.init(dx: dx, dy: 0)))
            XCTAssertEqual(input.value as? String, expected, style)
            if style == "second-flick" {
                key.press(forDuration: 0.6)
                XCTAssertEqual(input.value as? String, expected + "か")
            }
            app.terminate()
        }
    }
    func testStyleSettingsPersistWithoutLosingComposition() {
        let app = XCUIApplication()
        let input = launch(app)
        app.buttons["sumire-a"].tap()
        settingsButton("スミレ入力のスタイル", in: app).tap()
        app.buttons["sumire-flick-style"].tap(); app.buttons["二段フリック"].tap()
        app.buttons["完了"].tap()
        XCTAssertEqual(input.value as? String, "あ")
        app.buttons["sumire-ka"].tap(); XCTAssertEqual(input.value as? String, "あか")
        app.terminate(); _ = launch(app)
        settingsButton("スミレ入力のスタイル", in: app).tap()
        XCTAssertTrue(app.buttons["sumire-flick-style"].label.contains("二段フリック"))
        app.buttons["sumire-flick-style"].tap(); app.buttons["標準"].tap()
        app.buttons["完了"].tap()
    }
}
