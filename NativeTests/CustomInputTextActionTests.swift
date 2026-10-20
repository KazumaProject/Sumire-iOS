#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

/// Production custom-key callback dispatch, not direct invocation of the action helper.
/// Expected marker semantics follow pinned Android df1f383 IMEService InputText.
@MainActor
final class CustomInputTextActionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let domain = "custom-input-text-" + UUID().uuidString
        let defaults: UserDefaults
        let surface = Sumire.KeyboardSurface()
        var reading = ""
        var inserted = ""
        init(actions: [(String, String)], direct: Bool = false, romaji: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            var editor = CustomLayoutEditor(name: "InputText fixture", rows: 1, columns: actions.count)
            editor.setInputMode(romaji: romaji, direct: direct)
            for (index, item) in actions.enumerated() {
                editor.putKey(id: item.0, label: item.0, action: item.1, special: true,
                              row: 0, column: index * 2, height: 2, width: 2)
            }
            var library = CustomKeyboardLibrary()
            try library.append([editor.validated()])
            library.activeID = try XCTUnwrap(library.layouts().first?.id)
            try library.save(defaults: defaults)
            let id = "custom:" + (try XCTUnwrap(library.activeID))
            try KeyboardSelection(ids: [id]).save(defaults: defaults)
            defaults.set(id, forKey: "keyboard.lastUsed")
            surface.settingsDefaults = defaults
            surface.updateMarkedText = { [weak self] in self?.reading = $0 }
            surface.updateMarkedSelection = { [weak self] text, _ in self?.reading = text }
            surface.insert = { [weak self] in self?.inserted += $0 }
            surface.commitMarkedText = { [weak self] text in
                self?.inserted += text
                self?.reading = ""
            }
            surface.reloadCustomLayouts()
            surface.reloadRomaji()
            surface.reloadAppearance()
        }
        deinit { defaults.removePersistentDomain(forName: domain) }
        func tap(_ id: String) throws {
            let key = try XCTUnwrap(descendants(surface).first {
                $0.accessibilityIdentifier == "custom-" + id
            } as? Sumire.RepeatingKey)
            XCTAssertTrue(key.isEnabled)
            let callback = try XCTUnwrap(key.onCommittedPress)
            callback(true)
        }
        func contains(_ id: String) -> Bool {
            descendants(surface).contains { $0.accessibilityIdentifier == id }
        }
        private func descendants(_ view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
    }

    func testKanaMarkersModifyPriorKanaWithoutInsertingTheirNames() throws {
        let fixture = try Fixture(actions: [("ha", "Text:は"), ("a", "Text:あ"),
            ("voice", "InputText:濁点"), ("semi", "InputText:半濁点"), ("small", "InputText:ひらがな小文字")])
        try fixture.tap("voice")
        XCTAssertEqual(fixture.reading, "")
        try fixture.tap("ha")
        try fixture.tap("voice")
        XCTAssertEqual(fixture.reading, "ば")
        try fixture.tap("semi")
        XCTAssertEqual(fixture.reading, "ぱ")
        try fixture.tap("a")
        try fixture.tap("small")
        XCTAssertEqual(fixture.reading, "ぱぁ")
        XCTAssertEqual(fixture.inserted, "")
    }

    func testFaceTokenOpensSymbolsOnlyWhenEmptyAndOtherwiseMakesSmallKana() throws {
        let empty = try Fixture(actions: [("face", "InputText:^_^")])
        try empty.tap("face")
        XCTAssertTrue(empty.contains("symbol-keyboard"))
        XCTAssertEqual(empty.reading, "")
        XCTAssertEqual(empty.inserted, "")
        let composing = try Fixture(actions: [("a", "Text:あ"), ("face", "InputText:^_^")])
        try composing.tap("a")
        try composing.tap("face")
        XCTAssertEqual(composing.reading, "ぁ")
        XCTAssertFalse(composing.contains("symbol-keyboard"))
        XCTAssertEqual(composing.inserted, "")
    }

    func testTextPayloadsStayLiteralAndPunctuationHonorsDirectMode() throws {
        for direct in [false, true] {
            let fixture = try Fixture(actions: [("literal", "Text:濁点"), ("colon", "InputText::"), ("hyphen", "InputText:-")], direct: direct)
            try fixture.tap("literal")
            try fixture.tap("colon")
            try fixture.tap("hyphen")
            XCTAssertEqual(fixture.reading, direct ? "" : "濁点:-")
            XCTAssertEqual(fixture.inserted, direct ? "濁点:-" : "")
        }
    }

    func testInputTextPunctuationBypassesRomajiConversionWithoutFlushingPendingLetters() throws {
        let literal = try Fixture(actions: [("hyphen", "InputText:-"), ("colon", "InputText::")], romaji: true)
        try literal.tap("hyphen")
        try literal.tap("colon")
        XCTAssertEqual(literal.reading, "-:")
        XCTAssertEqual(literal.inserted, "")
        let text = try Fixture(actions: [("hyphen", "Text:-")], romaji: true)
        try text.tap("hyphen")
        XCTAssertEqual(text.reading, "ー")
        for (letter, punctuation) in [("k", "-"), ("n", ":")] {
            let pending = try Fixture(actions: [("letter", "Text:" + letter), ("punctuation", "InputText:" + punctuation)], romaji: true)
            try pending.tap("letter")
            XCTAssertEqual(pending.reading, letter)
            try pending.tap("punctuation")
            XCTAssertEqual(pending.reading, letter + punctuation)
            XCTAssertEqual(pending.inserted, "")
        }
    }

}
#endif
