import XCTest

final class KeyboardSizingSettingsTests: XCTestCase {
    func testSizeControlsKeepPortraitAndLandscapeProfilesIndependent() {
        let app = XCUIApplication()
        launchInputPreview(app)
        settingsButton("キー・文字サイズ", in: app).tap()

        let orientation = app.segmentedControls["keyboardSizingOrientationPicker"]
        let height = app.staticTexts["keyboardSizeHeightValue"]
        let width = app.staticTexts["keyboardSizeWidthValue"]
        let alignment = app.staticTexts["keyboardSizeAlignmentValue"]
        let heightSlider = app.sliders["keyboardSizeHeightSlider"]
        let widthSlider = app.sliders["keyboardSizeWidthSlider"]
        let alignmentSlider = app.sliders["keyboardSizeAlignmentSlider"]
        let reset = app.buttons["resetKeyboardSizeForOrientationButton"]
        let form = app.collectionViews["keyAppearanceSettingsForm"]

        func scrollForm(towardBottom: Bool) {
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.85 : 0.15))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.55 : 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        func reveal(_ element: XCUIElement, towardBottomIfMissing: Bool = true) {
            for _ in 0..<12 {
                guard element.exists else {
                    scrollForm(towardBottom: towardBottomIfMissing)
                    continue
                }
                let frame = element.frame
                let visibleForm = form.frame.intersection(app.frame)
                if frame.isEmpty || frame.maxY > visibleForm.maxY - 20 {
                    scrollForm(towardBottom: true)
                } else if frame.minY < visibleForm.minY + 20 {
                    scrollForm(towardBottom: false)
                } else if element.isHittable {
                    return
                } else {
                    scrollForm(towardBottom: towardBottomIfMissing)
                }
            }
            if !towardBottomIfMissing {
                for _ in 0..<6 {
                    if element.isHittable { return }
                    form.swipeDown()
                }
            }
            XCTAssertTrue(element.isHittable)
        }
        func resetBothOrientations() {
            reveal(orientation.buttons["横向き"], towardBottomIfMissing: false)
            orientation.buttons["横向き"].tap()
            reveal(reset, towardBottomIfMissing: false)
            reset.tap()
            reveal(orientation.buttons["縦向き"], towardBottomIfMissing: false)
            orientation.buttons["縦向き"].tap()
            reveal(reset, towardBottomIfMissing: false)
            reset.tap()
        }
        func displayedInteger(_ element: XCUIElement) -> Double {
            let digits = element.label.filter(\.isNumber)
            guard let value = Double(digits) else {
                XCTFail("数値を読み取れません: \(element.label)")
                return 0
            }
            return value
        }
        func currentSize() -> (height: Double, width: Double, alignment: Double) {
            reveal(height, towardBottomIfMissing: false)
            let currentHeight = displayedInteger(height)
            reveal(width)
            let currentWidth = displayedInteger(width) / 100
            reveal(alignment)
            let currentAlignment = displayedInteger(alignment) / 100
            return (height: currentHeight, width: currentWidth, alignment: currentAlignment)
        }
        func restore(_ size: (height: Double, width: Double, alignment: Double), orientationName: String) {
            reveal(orientation.buttons[orientationName], towardBottomIfMissing: false)
            orientation.buttons[orientationName].tap()
            reveal(heightSlider, towardBottomIfMissing: false)
            heightSlider.adjust(toNormalizedSliderPosition: (size.height - 160) / 440)
            reveal(widthSlider)
            let targetWidth = min(size.width, 0.99)
            widthSlider.adjust(toNormalizedSliderPosition: (targetWidth - 0.5) / 0.5)
            reveal(alignmentSlider)
            alignmentSlider.adjust(toNormalizedSliderPosition: size.alignment)
            if size.width >= 1 {
                widthSlider.adjust(toNormalizedSliderPosition: 1)
            } else if size.width < 0.99 {
                widthSlider.adjust(toNormalizedSliderPosition: (size.width - 0.5) / 0.5)
            }
        }

        XCTAssertTrue(orientation.waitForExistence(timeout: 5))
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        reveal(orientation.buttons["縦向き"], towardBottomIfMissing: false)
        orientation.buttons["縦向き"].tap()
        let originalPortraitSize = currentSize()
        reveal(orientation.buttons["横向き"], towardBottomIfMissing: false)
        orientation.buttons["横向き"].tap()
        let originalLandscapeSize = currentSize()
        defer {
            if orientation.exists && form.exists {
                restore(originalPortraitSize, orientationName: "縦向き")
                restore(originalLandscapeSize, orientationName: "横向き")
                if app.buttons["完了"].exists { app.buttons["完了"].tap() }
            }
        }
        reveal(orientation.buttons["縦向き"], towardBottomIfMissing: false)
        orientation.buttons["縦向き"].tap()
        resetBothOrientations()

        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, "高さ：275 pt")
        XCTAssertEqual(width.label, "幅：100%")
        reveal(heightSlider, towardBottomIfMissing: false)
        heightSlider.adjust(toNormalizedSliderPosition: 0.5)
        let portraitHeight = app.staticTexts["keyboardSizeHeightValue"].label

        reveal(widthSlider)
        widthSlider.adjust(toNormalizedSliderPosition: 0.7)
        let portraitWidth = app.staticTexts["keyboardSizeWidthValue"].label
        XCTAssertNotEqual(portraitWidth, "幅：100%")
        reveal(alignmentSlider)
        alignmentSlider.adjust(toNormalizedSliderPosition: 0.2)
        let portraitAlignment = app.staticTexts["keyboardSizeAlignmentValue"].label

        reveal(orientation.buttons["横向き"], towardBottomIfMissing: false)
        orientation.buttons["横向き"].tap()
        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, "高さ：275 pt")
        XCTAssertEqual(width.label, "幅：100%")
        reveal(alignment)
        XCTAssertEqual(alignment.label, "横位置：余白の左から50%")

        reveal(heightSlider, towardBottomIfMissing: false)
        heightSlider.adjust(toNormalizedSliderPosition: 0.3)
        let landscapeHeight = app.staticTexts["keyboardSizeHeightValue"].label
        reveal(widthSlider)
        widthSlider.adjust(toNormalizedSliderPosition: 0.6)
        let landscapeWidth = app.staticTexts["keyboardSizeWidthValue"].label
        reveal(alignmentSlider)
        alignmentSlider.adjust(toNormalizedSliderPosition: 0.8)
        let landscapeAlignment = app.staticTexts["keyboardSizeAlignmentValue"].label

        reveal(orientation.buttons["縦向き"], towardBottomIfMissing: false)
        orientation.buttons["縦向き"].tap()
        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, portraitHeight)
        XCTAssertEqual(width.label, portraitWidth)
        reveal(alignmentSlider)
        XCTAssertEqual(alignment.label, portraitAlignment)

        reveal(orientation.buttons["横向き"], towardBottomIfMissing: false)
        orientation.buttons["横向き"].tap()
        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, landscapeHeight)
        XCTAssertEqual(width.label, landscapeWidth)
        reveal(alignmentSlider)
        XCTAssertEqual(alignment.label, landscapeAlignment)

        reveal(reset, towardBottomIfMissing: false)
        reset.tap()
        reveal(orientation.buttons["縦向き"], towardBottomIfMissing: false)
        orientation.buttons["縦向き"].tap()
        reveal(reset, towardBottomIfMissing: false)
        reset.tap()
        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, "高さ：275 pt")
        XCTAssertEqual(width.label, "幅：100%")
        reveal(alignment)
        XCTAssertEqual(alignment.label, "横位置：余白の左から50%")
        reveal(orientation.buttons["横向き"], towardBottomIfMissing: false)
        orientation.buttons["横向き"].tap()
        reveal(height, towardBottomIfMissing: false)
        XCTAssertEqual(height.label, "高さ：275 pt")
        XCTAssertEqual(width.label, "幅：100%")
        reveal(alignment)
        XCTAssertEqual(alignment.label, "横位置：余白の左から50%")
    }
}
