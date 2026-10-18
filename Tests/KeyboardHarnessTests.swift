import XCTest
import UIKit

final class KeyboardHarnessTests: XCTestCase {
    func testLastKeyboardRestoresWithoutToggle() {
        let app = XCUIApplication(); app.launch()
        app.textViews["入力テスト"].tap(); selectKeyboard("Sumire", in: app)
        app.terminate(); app.launch(); app.textViews["入力テスト"].tap()
        XCTAssertTrue(app.buttons["sumire-cursor_left_key"].waitForExistence(timeout: 5))
        selectKeyboard("50音", in: app)
        app.terminate(); app.launch(); app.textViews["入力テスト"].tap()
        XCTAssertTrue(app.buttons["gojuon-left"].waitForExistence(timeout: 5))
    }

    func testSumireDirectionalHoldAndDeleteFlick() {
        let app = XCUIApplication(); app.launch()
        let input = app.textViews["入力テスト"]; input.tap(); selectKeyboard("50音", in: app)
        for label in ["あ", "い", "う", "え", "お"] { app.buttons[label].tap() }
        selectKeyboard("Sumire", in: app)
        let cursor = app.buttons["sumire-cursor_left_key"]
        cursor.tap(); cursor.tap(); cursor.tap()
        let start = cursor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 45, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0.9)
        selectKeyboard("50音", in: app); app.buttons["か"].tap()
        XCTAssertEqual(input.value as? String, "あいうえおか")
        selectKeyboard("Sumire", in: app)
        let delete = app.buttons["sumire-delete_key"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        delete.press(forDuration: 0.05, thenDragTo: delete.withOffset(CGVector(dx: -45, dy: 0)))
        XCTAssertEqual(input.value as? String, "")
        selectKeyboard("50音", in: app)
        app.buttons["あ"].tap(); app.buttons["い"].tap(); app.buttons["gojuon-enter"].tap()
        selectKeyboard("Sumire", in: app)
        let committedDelete = app.buttons["sumire-delete_key"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        committedDelete.press(forDuration: 0.05, thenDragTo: committedDelete.withOffset(CGVector(dx: -45, dy: 0)))
        XCTAssertEqual(input.value as? String, "")
        selectKeyboard("50音", in: app)
    }

    func testExpandedCandidatesPreserveReadingAndCommitSelection() {
        let app = XCUIApplication(); app.launch()
        let input = app.textViews["入力テスト"]; input.tap(); selectKeyboard("50音", in: app)
        app.buttons["あ"].tap()
        app.buttons["い"].tap()
        let expand = app.buttons["candidate-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10)); expand.tap()
        XCTAssertTrue(app.buttons["候補欄を閉じる"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "あい")
        app.buttons["候補欄を閉じる"].tap()
        XCTAssertEqual(input.value as? String, "あい")
        expand.tap()
        let candidate = app.collectionViews.staticTexts["愛"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        XCTAssertEqual(input.value as? String, "愛")
        XCTAssertFalse(app.buttons["候補欄を閉じる"].exists)
    }

    func testKeyboardSelectionListIsEditable() {
        let app = XCUIApplication(); app.launch()
        let button = app.buttons["キーボードの選択・順序"]
        if !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        XCTAssertTrue(app.navigationBars["キーボードの選択・順序"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["使用するキーボード（上から切り替え）"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["keyboard-selection-row-builtin:tenKey"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["keyboard-selection-row-builtin:gojuon"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Keyboard selection list"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["完了"].tap()
    }

    func testVisualCustomRomajiAndDirectInputModes() {
        let app = XCUIApplication()
        for (mode, expected) in [("ローマ字をかなに変換", "か"), ("直接入力する", "ka")] {
            app.launch()
            let name = "ModeEditor-" + UUID().uuidString.prefix(8)
            app.buttons["Custom Keyboard"].tap(); app.buttons["新しい配列を作成"].tap()
            let field = app.textFields["配列名"]; field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + name)
            app.switches[mode].switches.firstMatch.tap()
            app.buttons["キーを追加"].tap()
            let text = app.textFields["入力する文字"]; text.tap()
            text.typeText(XCUIKeyboardKey.delete.rawValue + "ka")
            app.buttons["適用"].tap(); app.buttons["保存"].tap(); app.buttons["完了"].tap()
            app.terminate(); app.launch()
            let input = app.textViews["入力テスト"]; input.tap(); selectKeyboard(name, in: app)
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "あ")).firstMatch.tap()
            XCTAssertEqual(input.value as? String, expected)
            selectKeyboard("50音", in: app); app.buttons["Custom Keyboard"].tap()
            app.buttons[name].firstMatch.tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
            app.terminate()
        }
    }

    func testVisualCustomLayoutSwitchPreservesComposition() throws {
        let app = XCUIApplication(); app.launch()
        let prefix = "SwitchEditor-" + String(UUID().uuidString.prefix(8))
        let source = prefix + "-A", target = prefix + "-B"
        app.buttons["Custom Keyboard"].tap()
        func begin(_ name: String) {
            app.buttons["新しい配列を作成"].tap()
            let field = app.textFields["配列名"]; field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + name)
            app.buttons["キーを追加"].tap()
        }
        begin(target)
        app.buttons["適用"].tap(); app.buttons["保存"].tap()
        begin(source)
        let label = app.textFields["表示文字"]; label.tap(); label.typeText(XCUIKeyboardKey.delete.rawValue + "切替")
        app.buttons["customKeyAction"].tap(); app.buttons["カスタム配列に切り替え"].tap()
        app.buttons["customKeyLayoutTarget"].tap()
        try XCTUnwrap(app.buttons.matching(identifier: target).allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        app.buttons["適用"].tap(); app.buttons["保存"].tap(); app.buttons["完了"].tap()
        let input = app.textViews["入力テスト"]; input.tap(); selectKeyboard(target, in: app)
        func key(_ text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", text)).firstMatch
        }
        key("あ").tap(); XCTAssertEqual(input.value as? String, "あ")
        selectKeyboard(source, in: app); key("切替").tap()
        XCTAssertEqual(input.value as? String, "あ")
        key("あ").tap(); XCTAssertEqual(input.value as? String, "ああ")
        selectKeyboard("50音", in: app); app.buttons["Custom Keyboard"].tap()
        for name in [source, target] {
            app.buttons[name].firstMatch.tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
        }
    }

    func testCreateStandardFlickInVisualEditorAndType() {
        let app = XCUIApplication(); app.launch()
        let name = "FlickEditor-" + UUID().uuidString.prefix(8)
        app.buttons["Custom Keyboard"].tap(); app.buttons["新しい配列を作成"].tap()
        let nameField = app.textFields["配列名"]; nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (nameField.value as? String ?? "").count) + name)
        app.buttons["キーを追加"].tap()
        app.buttons["customKeyInputType"].tap(); app.buttons["標準フリック"].tap()
        for (label, value) in [("左の文字", "い"), ("上の文字", "う"), ("右の文字", "え"), ("下の文字", "お")] {
            let field = app.textFields[label]; field.tap(); field.typeText(value)
        }
        app.buttons["適用"].tap(); app.buttons["保存"].tap(); app.buttons["完了"].tap()
        app.terminate(); app.launch()
        let input = app.textViews["入力テスト"]; input.tap(); selectKeyboard(name, in: app)
        let key = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "あ")).firstMatch
        key.tap()
        for delta in [CGVector(dx: -45, dy: 0), CGVector(dx: 0, dy: -45), CGVector(dx: 45, dy: 0), CGVector(dx: 0, dy: 45)] {
            let start = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(delta))
        }
        XCTAssertEqual(input.value as? String, "あいうえお")
        selectKeyboard("50音", in: app); app.buttons["Custom Keyboard"].tap()
        app.buttons[name].firstMatch.tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
    }

    func testCreateCustomLayoutVisuallyAndPersistAfterRelaunch() {
        let app = XCUIApplication(); app.launch()
        let name = "UI配列-" + UUID().uuidString.prefix(8)
        app.buttons["Custom Keyboard"].tap()
        app.buttons["新しい配列を作成"].tap()
        let field = app.textFields["配列名"]
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
        app.buttons["キーを追加"].tap()
        app.buttons["適用"].tap()
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        let input = app.textViews["入力テスト"]
        input.tap(); selectKeyboard(name, in: app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "あ")).firstMatch.tap()
        XCTAssertEqual(input.value as? String, "あ")
        selectKeyboard("50音", in: app)
        app.buttons["Custom Keyboard"].tap()
        XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 5))
        app.buttons[name].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["4行 × 5列／1キー"].exists)
        app.buttons["この配列を削除"].tap()
        app.buttons["削除する"].tap()
        XCTAssertFalse(app.buttons[name].firstMatch.exists)
    }
    func testBackupExportPreparesDocumentAndCanBeCancelled() {
        let app = XCUIApplication(); app.launch()
        app.buttons["辞書のバックアップ"].tap()
        let save = app.buttons["バックアップを保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        // Preparing the document must complete and hand it to the system file exporter.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "キャンセル"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30))
        cancel.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        app.buttons["完了"].tap()
        XCTAssertTrue(app.textViews["入力テスト"].waitForExistence(timeout: 5))
    }
    func testEnglishPredictionsInTenKeySumireAndGojuon() {
        let app = XCUIApplication()
        for layout in ["テンキー", "Sumire", "50音"] {
            app.launchArguments = ["-sumire.keyArrangement", "toggle", "-learningEnabled", "NO"]
            app.launch()
            let editor = app.textViews["入力テスト"]; editor.tap()
            selectKeyboard(layout, in: app)
            func flick(_ id: String, dx: CGFloat, dy: CGFloat) {
                let start = app.buttons[id].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
            }
            if layout == "50音" {
                app.buttons["gojuon-mode"].tap()
                for id in ["gojuon-0-9", "gojuon-1-6", "gojuon-0-8"] { app.buttons[id].tap() }
            } else {
                let sumire = layout == "Sumire"
                app.buttons[sumire ? "sumire-change_input_mode_key" : "tenkey-mode"].tap()
                let ghi = sumire ? "sumire-ta" : "tenkey-1-0"
                flick(ghi, dx: 0, dy: -45)
                app.buttons[sumire ? "sumire-ma" : "tenkey-2-0"].tap()
                flick(ghi, dx: -45, dy: 0)
            }
            XCTAssertEqual(editor.value as? String, "iph", layout)
            if layout == "テンキー" {
                selectKeyboard("50音", in: app)
                XCTAssertEqual(editor.value as? String, "iph")
            }
            let phone = app.collectionViews.staticTexts["iPhone"].firstMatch
            XCTAssertTrue(phone.waitForExistence(timeout: 15), layout)
            phone.tap()
            XCTAssertEqual(editor.value as? String, "iPhone", layout)
            app.terminate()
        }
    }
    func testEnglishReadingSettingPersistsAndDisablesCandidates() {
        let app = XCUIApplication(); app.launchArguments = ["-learningEnabled", "NO"]; app.launch()
        func settings() {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分類辞書（")).firstMatch.tap()
        }
        func toggle() -> XCUIElement { app.switches["かなから英単語を表示"].switches.firstMatch }
        settings()
        XCTAssertTrue(toggle().waitForExistence(timeout: 5))
        let original = toggle().value as? String == "1"
        if original { toggle().tap() }
        XCTAssertEqual(toggle().value as? String, "0")
        app.buttons["完了"].tap()
        app.terminate(); app.launch()
        settings()
        XCTAssertEqual(toggle().value as? String, "0")
        app.buttons["完了"].tap()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        let candidates = app.collectionViews.firstMatch
        XCTAssertTrue(candidates.staticTexts["愛"].firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<8 {
            XCTAssertFalse(candidates.staticTexts["eye"].exists)
            candidates.swipeLeft()
        }
        XCTAssertFalse(candidates.staticTexts["eye"].exists)
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["改行"].tap()
        settings(); toggle().tap(); app.buttons["完了"].tap()
        app.terminate(); app.launch()
        settings()
        XCTAssertEqual(toggle().value as? String, "1")
        if !original { toggle().tap() }
        app.buttons["完了"].tap()
    }
    func testKanaEnglishReadingCandidateCanBeSelected() {
        let app = XCUIApplication(); app.launchArguments = ["-englishReadingEnabled", "YES"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        let candidates = app.collectionViews.firstMatch
        let eye = candidates.staticTexts["eye"].firstMatch
        for _ in 0..<12 {
            if eye.exists && eye.isHittable { break }
            candidates.swipeLeft()
        }
        XCTAssertTrue(eye.waitForExistence(timeout: 10))
        eye.tap()
        XCTAssertEqual(editor.value as? String, "eye")
    }
    func testEnglishPredictionSelectionDeletionAndSpace() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ABC"].tap()
        for key in ["i", "p", "h"] { app.buttons["qwerty-character-" + key].tap() }
        XCTAssertEqual(editor.value as? String, "iph")
        let phone = app.collectionViews.staticTexts["iPhone"].firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        phone.tap()
        XCTAssertEqual(editor.value as? String, "iPhone")
        app.buttons["空白"].tap()
        for key in ["h", "e", "l"] { app.buttons["qwerty-character-" + key].tap() }
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "iPhone he")
        app.buttons["空白"].tap()
        XCTAssertEqual(editor.value as? String, "iPhone he ")
        app.buttons["qwerty-character-a"].tap()
        app.buttons["改行"].tap()
        XCTAssertEqual(editor.value as? String, "iPhone he a\n")
    }
    func testJapaneseQwertyHalfWidthOptionsPreserveDownFlick() {
        let app = XCUIApplication()
        app.launchArguments = ["-qwerty.romaji.halfWidthNumbers", "YES", "-qwerty.romaji.halfWidthSymbols", "YES",
                               "-qwerty.romaji.flickUp", "YES", "-qwerty.romaji.flickDown", "YES"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ローマ字"].tap()
        func flick(_ letter: String, dy: CGFloat) {
            let point = app.buttons["qwerty-character-" + letter].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: dy)))
        }
        flick("q", dy: -45); flick("a", dy: -45); flick("a", dy: 45)
        app.buttons["123"].tap(); app.buttons["1"].tap()
        app.buttons["#+="].tap(); app.buttons["#"].tap()
        XCTAssertEqual(editor.value as? String, "1@Ａ1#")
    }
    func testQwertyNumberAndSymbolPagesUseReferenceOutputs() {
        let app = XCUIApplication(); app.launchArguments = ["-qwerty.english.flickUp", "YES", "-qwerty.romaji.flickUp", "YES"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ABC"].tap()
        app.buttons["123"].tap(); app.buttons["1"].tap()
        let one = app.buttons["qwerty-symbol-1-0-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        one.press(forDuration: 0.05, thenDragTo: one.withOffset(CGVector(dx: 0, dy: -45)))
        app.buttons["#+="].tap(); app.buttons["#"].tap()
        let bracket = app.buttons["qwerty-symbol-2-0-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bracket.press(forDuration: 0.05, thenDragTo: bracket.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertEqual(editor.value as? String, "1１#")
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ローマ字"].tap()
        app.buttons["123"].tap(); app.buttons["1"].tap(); app.buttons["「"].tap()
        app.buttons["#+="].tap(); app.buttons["#"].tap()
        XCTAssertEqual(editor.value as? String, "1１#１「＃")
    }
    func testQwertyFlickSettingsPersistIndependently() {
        let app = XCUIApplication(); app.launch()
        app.buttons["キー・文字サイズ"].tap()
        func select(_ title: String) {
            app.buttons["appearanceKeyboardPicker"].tap()
            app.buttons[title].tap()
        }
        func control(_ title: String) -> XCUIElement {
            app.switches[title].switches.firstMatch
        }
        let up = "上フリックで記号を入力", down = "下フリックで大文字を入力"
        func set(_ title: String, _ enabled: Bool) {
            let toggle = control(title)
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            if (toggle.value as? String == "1") != enabled { toggle.tap() }
        }
        select("QWERTY 英語")
        let oldEnglishUp = control(up).value as? String == "1", oldEnglishDown = control(down).value as? String == "1"
        set(up, true); set(down, false)
        select("QWERTY 日本語")
        let oldJapaneseUp = control(up).value as? String == "1", oldJapaneseDown = control(down).value as? String == "1"
        set(up, false); set(down, true)
        app.buttons["完了"].tap()
        app.terminate(); app.launch()
        app.buttons["キー・文字サイズ"].tap()
        select("QWERTY 英語")
        XCTAssertEqual(control(up).value as? String, "1")
        XCTAssertEqual(control(down).value as? String, "0")
        select("QWERTY 日本語")
        XCTAssertEqual(control(up).value as? String, "0")
        XCTAssertEqual(control(down).value as? String, "1")
        set(up, oldJapaneseUp); set(down, oldJapaneseDown)
        select("QWERTY 英語")
        set(up, oldEnglishUp); set(down, oldEnglishDown)
        app.buttons["完了"].tap()
    }
    func testQwertyFlicksInEnglishAndJapaneseWithGuides() {
        let app = XCUIApplication()
        app.launchArguments = ["-qwerty.english.flickUp", "YES", "-qwerty.english.flickDown", "YES",
                               "-qwerty.romaji.flickUp", "YES", "-qwerty.romaji.flickDown", "YES",
                               "-appearance.english.guidesVisible", "YES", "-appearance.romaji.guidesVisible", "YES"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ABC"].tap()
        func flick(_ letter: String, dy: CGFloat) {
            let point = app.buttons["qwerty-character-" + letter].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: 0, dy: dy)))
        }
        let english = XCTAttachment(screenshot: app.screenshot()); english.name = "QWERTY英語ガイド"; english.lifetime = .keepAlways; add(english)
        flick("a", dy: -45); flick("a", dy: 45)
        XCTAssertEqual(editor.value as? String, "@A")
        app.buttons["keyboard-switch"].press(forDuration: 0.8); app.buttons["ローマ字"].tap()
        let japanese = XCTAttachment(screenshot: app.screenshot()); japanese.name = "QWERTY日本語ガイド"; japanese.lifetime = .keepAlways; add(japanese)
        flick("q", dy: -45); flick("q", dy: 45)
        XCTAssertEqual(editor.value as? String, "@A１Ｑ")
    }
    func testQwertyShiftSpecialKeyTransitions() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        app.buttons["ABC"].tap()
        app.buttons["a"].tap()
        app.buttons["qwerty-shift"].tap()
        app.buttons["削除"].tap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "ON")
        app.buttons["空白"].tap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "ON")
        app.buttons["改行"].tap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "OFF")
        app.buttons["b"].tap()
        XCTAssertEqual(editor.value as? String, " \nb")
        app.buttons["qwerty-shift"].doubleTap()
        app.buttons["改行"].tap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "Caps Lock")
        app.buttons["C"].tap()
        app.buttons["123"].tap()
        app.buttons["ABC"].tap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "OFF")
        app.buttons["d"].tap()
        XCTAssertEqual(editor.value as? String, " \nb\nCd")
    }
    func testQwertyOneShotShiftAndCapsLock() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        app.buttons["ABC"].tap()
        app.buttons["qwerty-shift"].tap()
        app.buttons["A"].tap()
        XCTAssertTrue(app.buttons["b"].exists)
        app.buttons["b"].tap()
        XCTAssertEqual(editor.value as? String, "Ab")
        app.buttons["qwerty-shift"].doubleTap()
        XCTAssertEqual(app.buttons["qwerty-shift"].value as? String, "Caps Lock")
        app.buttons["C"].tap(); app.buttons["D"].tap()
        XCTAssertEqual(editor.value as? String, "AbCD")
        app.buttons["qwerty-shift"].tap()
        app.buttons["e"].tap()
        XCTAssertEqual(editor.value as? String, "AbCDe")
    }
    func testGojuonNumberCommandSwitchesToQwertyWithoutModifyingReading() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["gojuon-0-9"].tap()
        app.buttons["gojuon-mode"].tap()
        app.buttons["gojuon-0-0"].tap()
        app.buttons["gojuon-previous"].tap()
        XCTAssertEqual(editor.value as? String, "か2")
        app.buttons["gojuon-mode"].tap()
        app.buttons["gojuon-previous"].tap()
        XCTAssertEqual(editor.value as? String, "か2")
        app.buttons["gojuon-4-0"].tap()
        XCTAssertEqual(editor.value as? String, "か2")
        XCTAssertFalse(app.buttons["gojuon-mode"].exists)
        XCTAssertTrue(app.buttons["q"].waitForExistence(timeout: 3))
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["50音"].waitForExistence(timeout: 3))
        app.buttons["50音"].tap()
        XCTAssertEqual(editor.value as? String, "か2")
        app.buttons["gojuon-mode"].tap()
        app.buttons["gojuon-0-10"].tap()
        XCTAssertEqual(editor.value as? String, "か2あ")
    }
    func testGojuonModesPreserveInputAndMergedKeys() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        let sideWidth = app.buttons["gojuon-delete"].frame.width
        app.buttons["gojuon-0-10"].tap()
        app.buttons["gojuon-mode"].tap()
        XCTAssertEqual(app.buttons["gojuon-delete"].frame.width, sideWidth, accuracy: 1)
        let englishImage = XCTAttachment(screenshot: app.screenshot()); englishImage.name = "50音・英字"; englishImage.lifetime = .keepAlways; add(englishImage)
        XCTAssertEqual(editor.value as? String, "あ")
        XCTAssertFalse(app.buttons["gojuon-0-1"].exists)
        XCTAssertEqual(app.buttons["gojuon-0-0"].label, "a")
        XCTAssertGreaterThan(app.buttons["gojuon-4-0"].frame.width, app.buttons["gojuon-0-0"].frame.width * 1.8)
        app.buttons["gojuon-0-0"].tap()
        app.buttons["gojuon-4-0"].tap()
        app.buttons["gojuon-0-2"].tap()
        app.buttons["gojuon-0-3"].tap()
        XCTAssertEqual(editor.value as? String, "あaBc")
        app.buttons["gojuon-4-10"].tap()
        app.buttons["gojuon-0-0"].tap()
        XCTAssertEqual(editor.value as? String, "あaBcａ")
        app.buttons["gojuon-mode"].tap()
        XCTAssertEqual(app.buttons["gojuon-delete"].frame.width, sideWidth, accuracy: 1)
        let numberImage = XCTAttachment(screenshot: app.screenshot()); numberImage.name = "50音・数字"; numberImage.lifetime = .keepAlways; add(numberImage)
        XCTAssertFalse(app.buttons["gojuon-0-3"].exists)
        XCTAssertFalse(app.buttons["gojuon-0-4"].exists)
        app.buttons["gojuon-0-8"].tap()
        app.buttons["gojuon-4-10"].tap()
        app.buttons["gojuon-0-9"].tap()
        app.buttons["gojuon-3-0"].tap()
        XCTAssertEqual(editor.value as? String, "あaBcａ1２→")
        app.buttons["gojuon-mode"].tap()
        app.buttons["gojuon-0-9"].tap()
        XCTAssertEqual(editor.value as? String, "あaBcａ1２→か")
    }
    func testGojuonFlicksAndUnassignedDirection() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        func flick(_ id: String, dx: CGFloat, dy: CGFloat) {
            let centre = app.buttons[id].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: dx, dy: dy)))
        }
        flick("gojuon-0-10", dx: 0, dy: -45)
        XCTAssertEqual(editor.value as? String, "ぁ")
        flick("gojuon-0-9", dx: -45, dy: 0)
        flick("gojuon-0-5", dx: 45, dy: 0)
        flick("gojuon-0-0", dx: 0, dy: -45)
        XCTAssertEqual(editor.value as? String, "ぁがぱ」")
        flick("gojuon-0-6", dx: 0, dy: -45)
        XCTAssertEqual(editor.value as? String, "ぁがぱ」")
        app.buttons["gojuon-1-0"].tap()
        XCTAssertEqual(editor.value as? String, "ぁがぱ」？")
    }

    func testSumireRepeatedTapsAndFlickBreakCycle() {
        let app = XCUIApplication(); app.launchArguments = ["-sumire.keyArrangement", "toggle"]; app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("Sumire", in: app)
        app.buttons["sumire-a"].doubleTap()
        XCTAssertEqual(editor.value as? String, "い")
        app.buttons["sumire-change_input_mode_key"].tap()
        let abc = app.buttons["sumire-ka"]
        abc.doubleTap()
        XCTAssertEqual(editor.value as? String, "いb")
        let centre = abc.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertEqual(editor.value as? String, "いbc")
        abc.tap()
        XCTAssertEqual(editor.value as? String, "いbca")
        app.buttons["sumire-change_input_mode_key"].tap()
        app.buttons["sumire-a"].doubleTap()
        XCTAssertEqual(editor.value as? String, "いbca11")
    }

    func testSumireModesAcrossAllArrangements() {
        let app = XCUIApplication()
        for arrangement in ["toggle", "flick", "switch-mode-effective"] {
            app.launchArguments = ["-sumire.keyArrangement", arrangement]
            app.launch()
            let editor = app.textViews["入力テスト"]; editor.tap()
            selectKeyboard("Sumire", in: app)
            app.buttons["sumire-a"].tap()
            app.buttons[arrangement == "toggle" ? "sumire-change_input_mode_key" : "sumire-english_mode"].tap()
            app.buttons["sumire-ka"].tap()
            XCTAssertEqual(editor.value as? String, "あa")
            app.buttons["sumire-dakuten_toggle_key"].tap()
            XCTAssertEqual(editor.value as? String, "あA")
            let english = XCTAttachment(screenshot: app.screenshot()); english.lifetime = .keepAlways; add(english)
            app.buttons[arrangement == "toggle" ? "sumire-change_input_mode_key" : "sumire-number_mode"].tap()
            app.buttons["sumire-a"].tap(); app.buttons["sumire-a"].tap()
            XCTAssertEqual(editor.value as? String, "あA11")
            if arrangement == "switch-mode-effective" {
                app.buttons["sumire-colon_key"].tap()
                app.buttons["sumire-hyphen_key"].tap()
                XCTAssertEqual(editor.value as? String, "あA11:-")
            }
            let number = XCTAttachment(screenshot: app.screenshot()); number.lifetime = .keepAlways; add(number)
            app.buttons[arrangement == "toggle" ? "sumire-change_input_mode_key" : "sumire-kana_mode"].tap()
            XCTAssertEqual(app.buttons["sumire-a"].label, "あ")
            app.terminate()
        }
    }

    func testSumireArrangementPreviewPersistsAndPreservesInput() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("Sumire", in: app)
        app.buttons["sumire-a"].tap()
        var expected = "あ"
        for title in ["フリック", "カーソル", "トグル"] {
            app.buttons["キー・文字サイズ"].tap()
            app.buttons["sumireArrangementPicker"].tap()
            app.buttons[title].tap()
            let a = app.buttons["sumire-a"], enter = app.buttons["sumire-enter_key"]
            if title == "トグル" { XCTAssertGreaterThan(enter.frame.height, a.frame.height * 1.5) }
            else {
                XCTAssertEqual(enter.frame.height, a.frame.height, accuracy: 1)
                let right = app.buttons["sumire-cursor_right_key"]
                let space = app.buttons["sumire-space_convert_key"]
                if title == "フリック" { XCTAssertGreaterThan(right.frame.minY, space.frame.minY) }
                else { XCTAssertLessThan(right.frame.minY, space.frame.minY) }
            }
            let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
            app.buttons["完了"].tap(); editor.tap()
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertEqual(app.staticTexts["compositionReading"].label, expected)
            app.buttons["sumire-ka"].tap(); expected += "か"
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertEqual(app.staticTexts["compositionReading"].label, expected)
        }
        app.terminate(); app.launch()
        app.buttons["キー・文字サイズ"].tap()
        XCTAssertTrue(app.buttons["sumire-paste_key"].exists)
        app.buttons["完了"].tap()
    }

    func testTenKeyModesPreserveReadingAndEmptyFlick() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("テンキー", in: app)
        app.buttons["tenkey-0-0"].tap()
        app.buttons["tenkey-mode"].tap()
        XCTAssertEqual(editor.value as? String, "あ")
        let abc = app.buttons["tenkey-0-1"]
        abc.tap()
        XCTAssertEqual(editor.value as? String, "あa")
        let centre = abc.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 45, dy: 0)))
        XCTAssertEqual(editor.value as? String, "あa")
        app.buttons["keyboard-switch"].tap()
        XCTAssertEqual(editor.value as? String, "あA")
        let englishImage = XCTAttachment(screenshot: app.screenshot()); englishImage.lifetime = .keepAlways; add(englishImage)
        app.buttons["tenkey-mode"].tap()
        app.buttons["tenkey-0-0"].tap(); app.buttons["tenkey-0-0"].tap()
        XCTAssertEqual(editor.value as? String, "あA11")
        let numberImage = XCTAttachment(screenshot: app.screenshot()); numberImage.lifetime = .keepAlways; add(numberImage)
        app.buttons["tenkey-mode"].tap()
        XCTAssertEqual(app.buttons["tenkey-0-0"].label, "あ")
        XCTAssertEqual(editor.value as? String, "あA11")
    }

    func testTenKeyReferenceGridAndInput() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("テンキー", in: app)
        let a = app.buttons["tenkey-0-0"], ka = app.buttons["tenkey-0-1"]
        XCTAssertTrue(a.waitForExistence(timeout: 3))
        XCTAssertLessThan(app.buttons["tenkey-previous"].frame.maxX, a.frame.minX)
        XCTAssertGreaterThan(app.buttons["tenkey-delete"].frame.minX, app.buttons["tenkey-0-2"].frame.maxX)
        XCTAssertEqual(a.frame.midY, app.buttons["tenkey-delete"].frame.midY, accuracy: 1)
        XCTAssertEqual(app.buttons["tenkey-enter"].frame.midY, app.buttons["tenkey-3-1"].frame.midY, accuracy: 1)
        XCTAssertEqual(app.buttons["tenkey-enter"].frame.height, a.frame.height, accuracy: 1)
        a.tap(); app.buttons["tenkey-previous"].tap()
        XCTAssertEqual(editor.value as? String, "ぉ")
        app.buttons["tenkey-delete"].tap(); ka.tap()
        app.buttons["keyboard-switch"].tap()
        XCTAssertEqual(editor.value as? String, "が")
        selectKeyboard("Sumire", in: app)
        XCTAssertEqual(editor.value as? String, "が")
        selectKeyboard("テンキー", in: app)
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
    }

    func testGojuonReferencePositionsAndModifierPopup() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["キーボードのサイズ変更"].tap()
        app.buttons["この向きのサイズをリセット"].tap()
        app.buttons["サイズ変更を完了"].tap()
        let a = app.buttons["gojuon-0-10"], wa = app.buttons["gojuon-0-1"]
        XCTAssertEqual(app.buttons["gojuon-4-10"].frame.maxY - a.frame.minY, 220, accuracy: 2)
        XCTAssertGreaterThan(a.frame.minX, wa.frame.maxX)
        XCTAssertEqual(a.frame.midY, app.buttons["gojuon-delete"].frame.midY, accuracy: 1)
        XCTAssertLessThan(app.buttons["gojuon-left"].frame.maxX, wa.frame.minX)
        XCTAssertGreaterThan(app.buttons["gojuon-enter"].frame.height, a.frame.height * 2.5)
        a.tap(); app.buttons["gojuon-previous"].tap()
        XCTAssertEqual(editor.value as? String, "ぉ")
        app.buttons["gojuon-delete"].tap()
        app.buttons["gojuon-0-9"].tap(); app.buttons["keyboard-switch"].tap()
        XCTAssertEqual(editor.value as? String, "が")
        selectKeyboard("Sumire", in: app)
        XCTAssertEqual(editor.value as? String, "が")
        selectKeyboard("50音", in: app)
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
    }

    func testClipboardAutomaticTextPreviewPreservesInput() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-test-text", "-clipboardAutomaticPreview", "YES"]
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        let description = app.buttons["clipboard-description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        let previewed = NSPredicate(format: "label == %@", "すみれ clipboard 🪻")
        expectation(for: previewed, evaluatedWith: description)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(editor.value as? String, "")
        selectKeyboard("Sumire", in: app)
        app.buttons["sumire-a"].tap()
        XCTAssertEqual(editor.value as? String, "あ")
        XCTAssertFalse(app.buttons["clipboard-preview"].exists)
        app.terminate()
    }

    func testClipboardTextDetectionAndPaste() {
        let app = XCUIApplication()
        #if targetEnvironment(simulator)
        UIPasteboard.general.setItems([["public.utf8-plain-text": "すみれ clipboard 🪻"]], options: [.localOnly: true])
        #else
        app.launchArguments = ["--clipboard-test-text"]
        #endif
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        let preview = app.buttons["clipboard-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        addUIInterruptionMonitor(withDescription: "Paste permission") { alert in
            for title in ["Allow Paste", "ペーストを許可"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        preview.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow Paste", "ペーストを許可")).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        XCTAssertEqual(editor.value as? String, "すみれ clipboard 🪻")
        XCTAssertFalse(preview.exists)
        #if targetEnvironment(simulator)
        UIPasteboard.general.items = []
        #endif
    }

    func testClipboardImageDetectionAndPreview() {
        let app = XCUIApplication()
        #if targetEnvironment(simulator)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
        UIPasteboard.general.setItems([["public.png": image.pngData()!]], options: [.localOnly: true])
        #else
        app.launchArguments = ["--clipboard-test-image"]
        #endif
        app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        let preview = app.buttons["clipboard-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clipboard-description"].label.contains("画像"))
        addUIInterruptionMonitor(withDescription: "Paste permission") { alert in
            for title in ["Allow Paste", "ペーストを許可"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        preview.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Allow Paste", "ペーストを許可")).firstMatch
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        XCTAssertTrue(app.staticTexts["画像は入力先の貼り付けメニューから挿入してください"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        #if targetEnvironment(simulator)
        UIPasteboard.general.items = []
        #endif
    }

    private func selectKeyboard(_ title: String, in app: XCUIApplication) {
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }
    func testKeyGroupsPreviewAndPersistence() {
        let app = XCUIApplication(); app.launchArguments = ["-sumire.keyArrangement", "toggle"]; app.launch()
        app.buttons["キー・文字サイズ"].tap()
        XCTAssertTrue(app.otherElements["keyboardAppearancePreview"].waitForExistence(timeout: 3))
        app.buttons["通常キーを標準値に戻す"].tap()
        app.buttons["特殊キー"].tap(); app.buttons["特殊キーを標準値に戻す"].tap()
        app.buttons["通常キー"].tap()
        let a = app.buttons["sumire-a"], ka = app.buttons["sumire-ka"]
        let modifier = app.buttons["sumire-dakuten_toggle_key"]
        let beforeModifier = modifier.frame.width
        let paste = app.buttons["sumire-paste_key"]
        let beforeA = a.frame.width, beforeKa = ka.frame.width, beforePaste = paste.frame.width
        let preview = app.otherElements["keyboardAppearancePreview"].frame
        XCTAssertGreaterThan(app.buttons["sumire-delete_key"].frame.midX, preview.minX + preview.width * 0.8)
        app.sliders["キーサイズ"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThan(a.frame.width, beforeA)
        XCTAssertLessThan(ka.frame.width, beforeKa)
        XCTAssertLessThan(modifier.frame.width, beforeModifier)
        let resizedModifier = modifier.frame.width
        XCTAssertEqual(paste.frame.width, beforePaste, accuracy: 1)
        app.buttons["特殊キー"].tap()
        app.sliders["キーサイズ"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThan(paste.frame.width, beforePaste)
        XCTAssertEqual(modifier.frame.width, resizedModifier, accuracy: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launch(); app.buttons["キー・文字サイズ"].tap()
        XCTAssertLessThan(app.buttons["sumire-a"].frame.width, beforeA)
        XCTAssertLessThan(app.buttons["sumire-paste_key"].frame.width, beforePaste)
        app.buttons["通常キーを標準値に戻す"].tap()
        app.buttons["特殊キー"].tap(); app.buttons["特殊キーを標準値に戻す"].tap()
        app.buttons["完了"].tap()
    }
    func testJapaneseQwertyPlacementAndInputMode() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("ローマ字", in: app)
        let a = app.buttons["a"], longVowel = app.buttons["ー"]
        XCTAssertEqual(a.frame.midY, longVowel.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(longVowel.frame.midX, app.buttons["l"].frame.midX)
        XCTAssertEqual(app.buttons["削除"].frame.midY, app.buttons["z"].frame.midY, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["qwerty-input-mode"].frame.minY, a.frame.maxY)
        for key in ["k", "o", "ー", "h", "i", "ー"] { app.buttons[key].tap() }
        XCTAssertEqual(editor.value as? String, "こーひー")
        app.buttons["qwerty-input-mode"].tap()
        XCTAssertEqual(editor.value as? String, "こーひー")
        app.buttons["x"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("x") == true)
        app.buttons["123"].tap(); app.buttons["「"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("x「") == true)
        app.buttons["ABC"].tap()
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Japanese QWERTY layout"; image.lifetime = .keepAlways; add(image)
    }
    func testEnglishQwertyReferencePlacementAndPages() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("ABC", in: app)
        let q = app.buttons["q"], a = app.buttons["a"], z = app.buttons["z"]
        let shift = app.buttons["⇧"], delete = app.buttons["削除"]
        XCTAssertGreaterThan(a.frame.minX, q.frame.minX)
        XCTAssertLessThan(shift.frame.midX, z.frame.midX)
        XCTAssertEqual(shift.frame.midY, z.frame.midY, accuracy: 1)
        XCTAssertEqual(delete.frame.midY, z.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["空白"].frame.width, app.buttons["keyboard-switch"].frame.width)
        a.tap(); shift.tap(); app.buttons["B"].tap()
        app.buttons["123"].tap(); app.buttons["1"].tap()
        app.buttons["#+="].tap(); app.buttons["#"].tap()
        app.buttons["ABC"].tap()
        XCTAssertEqual(editor.value as? String, "aB1#")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "English QWERTY layout"; image.lifetime = .keepAlways; add(image)
    }
    func testKeyboardSwitchTapAndLongPressPreserveReading() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        app.buttons["あ"].tap()
        XCTAssertFalse(app.buttons["テンキー"].exists)
        selectKeyboard("テンキー", in: app)
        XCTAssertEqual(editor.value as? String, "あ")
        app.buttons["keyboard-switch"].tap()
        XCTAssertTrue(app.buttons["q"].exists)
        XCTAssertEqual(editor.value as? String, "あ")
        selectKeyboard("Sumire", in: app)
        XCTAssertTrue(app.buttons["sumire-a"].exists)
        XCTAssertEqual(editor.value as? String, "あ")
        selectKeyboard("50音", in: app)
        XCTAssertEqual(editor.value as? String, "あ")
    }

    func testCustomStandardFlickImportedDirections() throws {
        let app = XCUIApplication()
        let id = "StandardFlick-" + String(UUID().uuidString.prefix(8))
        let source: [String: Any] = ["layout": ["stableId": id, "name": id, "rowCount": 2, "columnCount": 3],
            "keysWithFlicks": [["key": ["keyIdentifier": "standard", "label": "あ", "keyType": "STANDARD_FLICK"],
                "flicks": zip(["TAP", "UP_LEFT_FAR", "UP", "UP_RIGHT_FAR", "DOWN"], ["あ", "い", "う", "え", "お"]).map {
                    ["flickDirection": $0, "actionType": "INPUT_TEXT", "actionValue": $1]
                }]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
        app.launch(); app.buttons["Custom Keyboard"].tap(); app.buttons["配列JSONを入力"].tap()
        let jsonEditor = app.textViews["customLayoutJSON"]
        jsonEditor.tap(); jsonEditor.typeText(json); app.buttons["内容を検証"].tap()
        XCTAssertTrue(app.staticTexts["有効：1件／不正：0件"].waitForExistence(timeout: 5))
        app.buttons["有効な配列を追加"].tap(); app.buttons["完了"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap(); selectKeyboard(id, in: app)
        let key = app.buttons["custom-standard"]
        key.tap()
        for delta in [CGVector(dx: -45, dy: 0), CGVector(dx: 0, dy: -45), CGVector(dx: 45, dy: 0), CGVector(dx: 0, dy: 45)] {
            let start = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(delta))
        }
        XCTAssertEqual(editor.value as? String, "あいうえお")
        selectKeyboard("50音", in: app)
        app.buttons["Custom Keyboard"].tap()
        app.buttons[id].tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
        app.buttons["完了"].tap()
    }

    func testCustomNormalKeysAndLayoutSwitchPreserveReading() throws {
        let app = XCUIApplication()
        let id = "Runtime-" + String(UUID().uuidString.prefix(8))
        let json = "{\"schemaVersion\":4,\"layouts\":[{\"layout\":{\"stableId\":\"\(id)\",\"name\":\"\(id)\",\"rowCount\":1,\"columnCount\":2},\"keysWithFlicks\":[{\"key\":{\"keyIdentifier\":\"a\",\"label\":\"あ\",\"column\":0}},{\"key\":{\"keyIdentifier\":\"switch\",\"label\":\"次\",\"column\":1,\"action\":\"MoveToCustomKeyboard:\(id)-B\"}}]},{\"layout\":{\"stableId\":\"\(id)-B\",\"name\":\"\(id)-B\",\"rowCount\":1,\"columnCount\":1},\"keysWithFlicks\":[{\"key\":{\"keyIdentifier\":\"i\",\"label\":\"い\"}}]}]}"
        app.launch(); app.buttons["Custom Keyboard"].tap(); app.buttons["配列JSONを入力"].tap()
        let jsonEditor = app.textViews["customLayoutJSON"]
        jsonEditor.tap(); jsonEditor.typeText(json); app.buttons["内容を検証"].tap()
        XCTAssertTrue(app.staticTexts["有効：2件／不正：0件"].waitForExistence(timeout: 5))
        app.buttons["有効な配列を追加"].tap()
        app.buttons["selectedCustomLayout"].tap()
        try XCTUnwrap(app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        app.buttons["完了"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap(); selectKeyboard(id, in: app)
        app.buttons["custom-a"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Custom normal keys"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["custom-switch"].tap()
        XCTAssertEqual(editor.value as? String, "あ")
        app.buttons["custom-i"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        selectKeyboard("50音", in: app)
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["Custom Keyboard"].tap()
        for name in [id, id + "-B"] {
            app.buttons[name].tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
        }
        app.buttons["完了"].tap()
    }

    func testCustomLayoutImportReviewSelectionAndDeletion() throws {
        let app = XCUIApplication()
        let name = "Layout-" + String(UUID().uuidString.prefix(8))
        let json = "{\"schemaVersion\":4,\"layouts\":[{\"layout\":{\"stableId\":\"\(name)\",\"name\":\"\(name)\",\"rowCount\":1,\"columnCount\":1},\"keysWithFlicks\":[{\"key\":{\"keyIdentifier\":\"a\",\"label\":\"A\",\"action\":\"VoiceInput\"}}]}]}"
        app.launch(); app.buttons["Custom Keyboard"].tap(); app.buttons["配列JSONを入力"].tap()
        let editor = app.textViews["customLayoutJSON"]
        editor.tap(); editor.typeText(json)
        app.buttons["内容を検証"].tap()
        XCTAssertTrue(app.staticTexts["有効：1件／不正：0件"].waitForExistence(timeout: 5))
        app.buttons[name].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'VoiceInput'")).firstMatch.exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Custom layout review"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["BackButton"].tap()
        app.buttons["有効な配列を追加"].tap()
        let selected = app.buttons["selectedCustomLayout"]
        selected.tap()
        try XCTUnwrap(app.buttons.matching(identifier: name).allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        app.buttons["完了"].tap(); app.terminate(); app.launch()
        app.buttons["Custom Keyboard"].tap()
        XCTAssertTrue(selected.label.contains(name))
        app.buttons[name].tap(); app.buttons["この配列を削除"].tap(); app.buttons["削除する"].tap()
        XCTAssertFalse(app.buttons[name].exists)
        app.buttons["完了"].tap()
    }

    func testLearningPersistsCanBeDisabledAndCleared() throws {
        let app = XCUIApplication()
        func clear() {
            app.buttons["学習データをすべて削除"].tap(); app.buttons["削除する"].tap()
            XCTAssertTrue(app.staticTexts["学習データを削除しました"].waitForExistence(timeout: 5))
        }
        func firstCandidate() -> XCUIElement { app.collectionViews.cells.element(boundBy: 0) }
        app.launch()
        let learning = app.switches["変換を学習"].switches.firstMatch
        if learning.value as? String == "0" { learning.tap() }
        clear()
        app.textViews["入力テスト"].tap(); app.buttons["あ"].tap()
        let second = app.collectionViews.cells.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let baseline = firstCandidate().label, learned = second.label
        XCTAssertNotEqual(baseline, learned)
        second.tap()
        XCTAssertTrue(app.staticTexts["学習しました"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); app.textViews["入力テスト"].tap(); app.buttons["あ"].tap()
        XCTAssertTrue(firstCandidate().waitForExistence(timeout: 10))
        XCTAssertEqual(firstCandidate().label, learned)
        learning.tap()
        let ordinary = NSPredicate(format: "label == %@", baseline)
        expectation(for: ordinary, evaluatedWith: firstCandidate())
        waitForExpectations(timeout: 10)
        learning.tap()
        expectation(for: NSPredicate(format: "label == %@", learned), evaluatedWith: firstCandidate())
        waitForExpectations(timeout: 10)
        clear()
        expectation(for: ordinary, evaluatedWith: firstCandidate())
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["compositionReading"].label, "あ")
    }

    func testCustomRomajiRuleSurvivesRelaunchAndDrivesInput() throws {
        let app = XCUIApplication()
        let name = "Test-" + String(UUID().uuidString.prefix(8))
        app.launch(); app.buttons["カスタムローマ字"].tap()
        app.buttons["標準をコピーして作成"].tap()
        let field = app.textFields["名前"]
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + name)
        app.textFields["romajiRuleInput"].tap(); app.textFields["romajiRuleInput"].typeText("a")
        app.textFields["romajiRuleOutput"].tap(); app.textFields["romajiRuleOutput"].typeText("す")
        app.buttons["規則を反映"].tap(); app.buttons["保存"].tap()
        app.buttons["activeRomajiProfile"].tap(); try XCTUnwrap(app.buttons.matching(identifier: name).allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        app.buttons["完了"].tap(); app.terminate(); app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap(); selectKeyboard("ローマ字", in: app); app.buttons["a"].tap()
        XCTAssertEqual(editor.value as? String, "す")
        app.buttons["カスタムローマ字"].tap()
        app.buttons["activeRomajiProfile"].tap(); app.buttons["標準（312規則）"].tap()
        app.buttons[name].tap(); app.buttons["この設定を削除"].tap()
        XCTAssertFalse(app.buttons[name].exists)
        app.buttons["完了"].tap()
        XCTAssertEqual(editor.value as? String, "す")
    }

    func testThemePersistsAndSwitchingPreservesComposition() throws {
        let app = XCUIApplication()
        app.launch()
        let picker = app.buttons["keyboardColorMode"]
        func openTheme() {
            let button = app.buttons["キーボードの配色"]
            for _ in 0..<8 {
                if button.isHittable { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["theme-seed-color"].exists)
        }
        openTheme()
        picker.tap(); app.buttons["ダーク"].tap()
        app.buttons["完了"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap(); selectKeyboard("50音", in: app)
        app.buttons["あ"].tap(); app.buttons["い"].tap()
        app.buttons["gojuon-left"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Dark keyboard theme with composing cursor"; dark.lifetime = .keepAlways; add(dark)
        openTheme()
        picker.tap(); app.buttons["ライト"].tap()
        app.buttons["完了"].tap()
        XCTAssertTrue(app.buttons["か"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "あい")
        XCTAssertEqual(app.staticTexts["compositionReading"].label, "あい")
        app.buttons["か"].tap()
        XCTAssertEqual(editor.value as? String, "あかい")
        let light = XCTAttachment(screenshot: app.screenshot())
        light.name = "Light keyboard theme preserving composing cursor"; light.lifetime = .keepAlways; add(light)
        app.terminate(); app.launch()
        openTheme()
        XCTAssertTrue(picker.label.contains("ライト"))
        picker.tap(); app.buttons["システム"].tap()
        app.buttons["完了"].tap()
    }

    func testRegisteredWordAndExactTemplateReachNativeCandidates() throws {
        let app = XCUIApplication()
        for (template, reading, surface) in [(false, "あ", "SumirePersonalTest"), (true, "い", "Sumire template line one\nline two")] {
            app.launch()
            app.buttons["ユーザー辞書・定型文"].tap()
            if template { app.buttons["定型文"].tap() }
            let existing = app.buttons.containing(.staticText, identifier: surface).firstMatch
            if existing.exists { existing.tap(); app.buttons["この登録を削除"].tap() }
            app.buttons["登録を追加"].tap()
            let readingField = app.textFields["personalReading"]
            readingField.tap(); readingField.typeText(reading)
            let wordField = template ? app.textViews["personalText"] : app.textFields["personalText"]
            wordField.tap(); wordField.typeText(surface)
            let score = app.textFields["personalScore"]
            score.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            score.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "-20000")
            app.buttons["保存"].tap()
            app.buttons["完了"].tap()
            app.terminate(); app.launch()
            let editor = app.textViews["入力テスト"]
            editor.tap(); app.buttons[reading].tap()
            let candidate = app.collectionViews.cells.matching(NSPredicate(format: "label == %@", surface)).firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 15))
            candidate.tap()
            XCTAssertEqual(editor.value as? String, surface)
            app.buttons["ユーザー辞書・定型文"].tap()
            if template { app.buttons["定型文"].tap() }
            app.buttons.containing(.staticText, identifier: surface).firstMatch.tap()
            app.buttons["この登録を削除"].tap()
            app.buttons["完了"].tap()
            app.terminate()
        }
    }

    func testResizeToolbarPersistsSeparatelyAcrossRotationAndLaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        let resize = app.buttons["キーボードのサイズ変更"]
        XCTAssertTrue(resize.waitForExistence(timeout: 5))
        app.buttons["あ"].tap()
        XCTAssertFalse(resize.exists)
        app.buttons["削除"].tap()
        XCTAssertTrue(resize.exists)
        resize.tap()
        app.buttons["この向きのサイズをリセット"].tap()
        let originalY = app.buttons["あ"].frame.minY
        let top = app.otherElements["キーボードの高さ"]
        let start = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        app.buttons["サイズ変更を完了"].tap()
        let portraitY = app.buttons["あ"].frame.minY
        XCTAssertGreaterThan(portraitY, originalY + 20)
        XCUIDevice.shared.orientation = .landscapeLeft
        resize.tap()
        app.buttons["この向きのサイズをリセット"].tap()
        app.buttons["サイズ変更を完了"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.buttons["あ"].frame.minY, portraitY, accuracy: 3)
        app.terminate(); app.launch(); app.textViews["入力テスト"].tap()
        XCTAssertEqual(app.buttons["あ"].frame.minY, portraitY, accuracy: 3)
        resize.tap(); app.buttons["この向きのサイズをリセット"].tap(); app.buttons["サイズ変更を完了"].tap()
    }

    func testKeyboardWidthsAreSavedForBothOrientations() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch(); app.textViews["入力テスト"].tap(); selectKeyboard("Sumire", in: app)
        let resize = app.buttons["キーボードのサイズ変更"]
        func reset() {
            resize.tap(); app.buttons["この向きのサイズをリセット"].tap()
            app.buttons["サイズ変更を完了"].tap()
        }
        func narrow(_ distance: CGFloat) -> CGFloat {
            resize.tap()
            let edge = app.otherElements["キーボードの左端"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: distance, dy: 0)))
            app.buttons["サイズ変更を完了"].tap()
            return app.buttons["sumire-a"].frame.width
        }
        reset()
        let originalPortrait = app.buttons["sumire-a"].frame.width
        let portrait = narrow(65)
        XCTAssertLessThan(portrait, originalPortrait - 4)
        XCUIDevice.shared.orientation = .landscapeLeft
        reset()
        let originalLandscape = app.buttons["sumire-a"].frame.width
        let landscape = narrow(110)
        XCTAssertLessThan(landscape, originalLandscape - 8)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.buttons["sumire-a"].frame.width, portrait, accuracy: 2)
        app.terminate(); app.launch(); app.textViews["入力テスト"].tap(); selectKeyboard("Sumire", in: app)
        XCTAssertEqual(app.buttons["sumire-a"].frame.width, portrait, accuracy: 2)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(app.buttons["sumire-a"].frame.width, landscape, accuracy: 2)
        reset()
        XCUIDevice.shared.orientation = .portrait
        reset()
    }

    func testKeyGuideSettingsAndIcons() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["キー・文字サイズ"].tap()
        app.buttons["通常キーを標準値に戻す"].tap()
        app.sliders["キーサイズ"].adjust(toNormalizedSliderPosition: 1.0 / 3.0)
        app.sliders["キー文字サイズ"].adjust(toNormalizedSliderPosition: 0.5)
        app.collectionViews.firstMatch.swipeUp()
        let toggle = app.switches["フリックガイドを表示"].switches.firstMatch
        if toggle.value as? String == "0" { toggle.tap() }
        app.sliders["ガイド文字サイズ"].adjust(toNormalizedSliderPosition: 0.3)
        app.buttons["完了"].tap()
        app.textViews["入力テスト"].tap(); selectKeyboard("Sumire", in: app)
        let aFrame = app.buttons["sumire-a"].frame
        let pitch = app.buttons["sumire-ka"].frame.midX - aFrame.midX
        XCTAssertEqual(aFrame.width, (pitch - 6) * 0.8, accuracy: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sumire inline guides and reference icons"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["sumire-a"].tap()
        XCTAssertEqual(app.textViews["入力テスト"].value as? String, "あ")
        app.buttons["キー・文字サイズ"].tap()
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["通常キーを標準値に戻す"].tap()
        app.buttons["完了"].tap()
    }

    func testSumireGridPlacementFlickAndModeChange() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        selectKeyboard("Sumire", in: app)
        let a = app.buttons["sumire-a"]
        let ka = app.buttons["sumire-ka"]
        let paste = app.buttons["sumire-paste_key"]
        let enter = app.buttons["sumire-enter_key"]
        let delete = app.buttons["sumire-delete_key"]
        let space = app.buttons["sumire-space_convert_key"]
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertLessThan(paste.frame.midX, a.frame.midX)
        XCTAssertLessThan(a.frame.midX, ka.frame.midX)
        XCTAssertEqual(a.frame.minY, delete.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(enter.frame.height, 2 * delete.frame.height)
        XCTAssertEqual(enter.frame.minX, space.frame.minX, accuracy: 1)
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -35, dy: 0)))
        XCTAssertEqual(editor.value as? String, "い")
        XCTAssertEqual(enter.label, "確定")
        XCTAssertEqual(space.label, "変換")
        selectKeyboard("50音", in: app)
        XCTAssertEqual(editor.value as? String, "い")
        app.buttons["ゆ"].tap()
        XCTAssertEqual(editor.value as? String, "いゆ")
        selectKeyboard("Sumire", in: app)
        enter.tap()
        XCTAssertEqual(enter.label, "改行")
        XCTAssertEqual(editor.value as? String, "いゆ")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Sumire reference grid"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDirectInputAndStandardKeyboardReference() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["1段"].tap()
        let editor = app.textViews["入力テスト"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        selectKeyboard("50音", in: app)
        let key = app.buttons["あ"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        XCTAssertEqual(editor.value as? String, "あ")
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "")
        let custom = XCTAttachment(screenshot: app.screenshot())
        custom.name = "Sumire native input harness"
        custom.lifetime = .keepAlways
        add(custom)
        // SwiftUI exposes a labelled container and the actual UISwitch separately.
        // Tapping the container's centre hits its label, leaving the value unchanged.
        app.switches["Sumire の入力面を試す"].switches.firstMatch.tap()
        XCTAssertEqual(app.switches["Sumire の入力面を試す"].value as? String, "0")
        editor.tap()
        // The system may restore Sumire's extension as the active input method.
        // Advance through the system globe before capturing Apple's keyboard.
        for _ in 0..<6 {
            if app.keyboards.firstMatch.exists { break }
            let globe = app.buttons["Next keyboard"]
            guard globe.waitForExistence(timeout: 2) else { break }
            globe.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let system = XCTAttachment(screenshot: app.screenshot())
        system.name = "iOS standard keyboard reference"
        system.lifetime = .keepAlways
        add(system)
    }

    func testCategorySettingLoadsRealKampoDictionary() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分類辞書（")).firstMatch
        settings.tap()
        app.buttons["分類辞書をすべて無効"].tap()
        let kampo = app.switches["category-kampo"]
        if !kampo.isHittable { app.swipeUp() }
        kampo.switches.firstMatch.tap()
        app.buttons["完了"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        for key in "あんえいとう" { app.buttons[String(key)].tap() }
        let candidate = app.collectionViews.staticTexts["安栄湯"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()
        XCTAssertEqual(editor.value as? String, "安栄湯")
        settings.tap()
        app.buttons["分類辞書をすべて無効"].tap()
        app.buttons["完了"].tap()
    }

    func testTenKeyFlickModifierToggleAndLayoutChange() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        selectKeyboard("テンキー", in: app)
        func flick(_ key: String, x: CGFloat, y: CGFloat) {
            let start = app.buttons[key].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: x, dy: y)))
        }
        app.buttons["か"].tap()
        app.buttons["゛"].tap()
        flick("た", x: 0, y: -35)
        app.buttons["゛"].tap()
        flick("か", x: 0, y: 35)
        flick("あ", x: 0, y: -35)
        XCTAssertEqual(editor.value as? String, "がっこう")
        let school = app.collectionViews.staticTexts["学校"].firstMatch
        XCTAssertTrue(school.waitForExistence(timeout: 10))
        school.tap()
        XCTAssertEqual(editor.value as? String, "学校")
        app.buttons["あ"].doubleTap()
        XCTAssertEqual(editor.value as? String, "学校い")
        app.buttons["→"].tap()
        app.buttons["あ"].tap()
        XCTAssertEqual(editor.value as? String, "学校いあ")
        selectKeyboard("50音", in: app)
        XCTAssertEqual(editor.value as? String, "学校いあ")
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "学校い")
        app.buttons["ゆ"].tap()
        app.buttons["よ"].tap()
        XCTAssertEqual(editor.value as? String, "学校いゆよ")
    }

    func testRomajiConversionLayoutSwitchAndEnglish() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        selectKeyboard("ローマ字", in: app)
        for key in "nihongo" { app.buttons[String(key)].tap() }
        XCTAssertEqual(editor.value as? String, "にほんご")
        selectKeyboard("ABC", in: app)
        XCTAssertEqual(editor.value as? String, "にほんご")
        let japanese = app.collectionViews.staticTexts["日本語"].firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 10))
        japanese.tap()
        XCTAssertEqual(editor.value as? String, "日本語")
        app.buttons["⇧"].tap()
        app.buttons["A"].tap()
        XCTAssertEqual(editor.value as? String, "日本語A")
        app.buttons["かな"].tap()
        selectKeyboard("ローマ字", in: app)
        for key in "kan" { app.buttons[String(key)].tap() }
        XCTAssertEqual(editor.value as? String, "日本語Aかn")
        app.buttons["改行"].tap()
        XCTAssertEqual(editor.value as? String, "日本語Aかん")
    }

    func testOmissionToggleRecomputesWithoutLosingReading() throws {
        let app = XCUIApplication()
        app.launch()
        let omission = app.switches["修飾キー省略"]
        if omission.value as? String == "1" { omission.switches.firstMatch.tap() }
        let editor = app.textViews["入力テスト"]
        editor.tap()
        for key in ["か", "つ", "こ", "う"] { app.buttons[key].tap() }
        XCTAssertEqual(editor.value as? String, "かつこう")
        omission.switches.firstMatch.tap()
        let school = app.collectionViews.staticTexts["学校"].firstMatch
        XCTAssertTrue(school.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "かつこう")
        omission.switches.firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "かつこう")
        XCTAssertFalse(school.exists)
        omission.switches.firstMatch.tap()
        XCTAssertTrue(school.waitForExistence(timeout: 15))
        school.tap()
        XCTAssertEqual(editor.value as? String, "学校")
        omission.switches.firstMatch.tap()
    }

    func testLiveConversionTogglePreservesReading() throws {
        let app = XCUIApplication()
        app.launch()
        let live = app.switches["ライブ変換"]
        if live.value as? String == "1" { live.switches.firstMatch.tap() }
        let editor = app.textViews["入力テスト"]
        editor.tap()
        app.buttons["あ"].tap()
        app.buttons["い"].tap()
        XCTAssertTrue(app.collectionViews.staticTexts["愛"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "あい")
        live.switches.firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "愛")
        live.switches.firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["あ"].tap()
        XCTAssertEqual(editor.value as? String, "あいあ")
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["改行"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
    }

    func testNativeConversionSelectionAndCommit() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["1段"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        app.buttons["あ"].tap()
        app.buttons["い"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        let candidate = app.collectionViews.staticTexts["愛"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()
        XCTAssertEqual(editor.value as? String, "愛")
        app.buttons["あ"].tap()
        XCTAssertEqual(editor.value as? String, "愛あ")
        app.buttons["削除"].tap()
        XCTAssertEqual(editor.value as? String, "愛")
        XCTAssertFalse(app.collectionViews.staticTexts["愛"].firstMatch.exists)
    }

    func testGojuonDevFunctionRowsAcrossModesAndRotation() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launch()
        app.textViews["入力テスト"].tap()
        selectKeyboard("50音", in: app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for _ in 0..<3 {
                let previous = app.buttons["gojuon-previous"].frame
                let left = app.buttons["gojuon-left"].frame
                let right = app.buttons["gojuon-right"].frame
                let symbols = app.buttons["gojuon-symbols"].frame
                let mode = app.buttons["gojuon-mode"].frame
                let switching = app.buttons["keyboard-switch"].frame
                XCTAssertEqual(left.minY, right.minY, accuracy: 1)
                XCTAssertEqual(left.width, right.width, accuracy: 1)
                XCTAssertGreaterThan(right.midX, left.midX)
                XCTAssertLessThan(previous.midY, left.midY)
                XCTAssertLessThan(left.midY, symbols.midY)
                XCTAssertLessThan(symbols.midY, mode.midY)
                XCTAssertLessThan(mode.midY, switching.midY)
                XCTAssertEqual(previous.width, switching.width, accuracy: 1)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Gojuon-dev-\(orientation.rawValue)-\(app.buttons["gojuon-mode"].label)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                app.buttons["gojuon-mode"].tap()
            }
        }
        app.buttons["keyboard-switch"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["テンキー"].waitForExistence(timeout: 3))
        app.buttons["テンキー"].tap()
    }

    func testDeleteAndCursorHoldRepeatAndStopOnRelease() {
        let app = XCUIApplication(); app.launch()
        let editor = app.textViews["入力テスト"]; editor.tap()
        selectKeyboard("50音", in: app)
        for _ in 0..<8 { app.buttons["あ"].tap() }
        app.buttons["gojuon-enter"].tap()
        app.buttons["gojuon-left"].press(forDuration: 0.8)
        app.buttons["い"].tap()
        let moved = editor.value as? String ?? ""
        XCTAssertTrue(moved.contains("いああ"), "Held left must move more than one character: \(moved)")
        app.buttons["gojuon-right"].press(forDuration: 1.2)
        app.buttons["う"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("う"))
        app.buttons["gojuon-enter"].tap()
        app.buttons["gojuon-delete"].press(forDuration: 0.8)
        let remaining = editor.value as? String ?? ""
        XCTAssertLessThan(remaining.count, moved.count - 1)
        app.buttons["か"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("か"))
    }

    func testMarkedCommitThenCursorMovementPreservesSurroundingText() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        selectKeyboard("50音", in: app)
        app.buttons["あ"].tap()
        app.buttons["い"].tap()
        XCTAssertEqual(editor.value as? String, "あい")
        app.buttons["gojuon-left"].tap()
        app.buttons["か"].tap()
        XCTAssertEqual(editor.value as? String, "あかい")
        app.buttons["gojuon-right"].tap()
        app.buttons["き"].tap()
        XCTAssertEqual(editor.value as? String, "あかいき")
        app.buttons["gojuon-delete"].tap()
        XCTAssertEqual(editor.value as? String, "あかい")
    }

    func testCandidateRowChangesPreserveTextAndKeyHeight() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["1段"].tap()
        let editor = app.textViews["入力テスト"]
        editor.tap()
        let key = app.buttons["あ"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        let originalHeight = key.frame.height
        let originalTop = key.frame.minY
        for rows in [2, 3, 1] {
            app.buttons["\(rows)段"].tap()
            XCTAssertEqual(editor.value as? String, "あ")
            XCTAssertEqual(key.frame.height, originalHeight, accuracy: 1)
            // Adding candidate rows raises the top edge of the keyboard while
            // the unchanged key area remains at the same screen position.
            XCTAssertEqual(key.frame.minY, originalTop, accuracy: 1)
        }
        key.tap()
        XCTAssertEqual(editor.value as? String, "ああ")
    }
}
