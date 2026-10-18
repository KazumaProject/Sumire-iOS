import XCTest
@testable import SumireCore

final class CustomLayoutEditorTests: XCTestCase {
    func testInputModePersistsWithoutChangingKeys() throws {
        var editor = CustomLayoutEditor()
        editor.putKey(id: "ka", label: "ka", action: "Text:ka", special: false, row: 0, column: 0, height: 2, width: 2)
        let originalKeys = editor.source["keysWithFlicks"]
        for (romaji, direct) in [(true, false), (true, true), (false, true), (false, false)] {
            editor.setInputMode(romaji: romaji, direct: direct)
            let layout = try editor.validated()
            var library = CustomKeyboardLibrary(); try library.append([layout])
            let restored = try XCTUnwrap(library.layouts().first)
            XCTAssertEqual(restored.source["layout"]?["isRomaji"], .bool(romaji))
            XCTAssertEqual(restored.source["layout"]?["isDirectMode"], .bool(direct))
            XCTAssertEqual(restored.source["keysWithFlicks"], originalKeys)
        }
    }
    func testStandardFlickEditsFeedRuntimeAndPreserveOtherStates() throws {
        let raw = #"{"layout":{"rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"keyIdentifier":"a","keyType":"STANDARD_FLICK"},"flicks":[{"stateIndex":0,"flickDirection":"UP_LEFT","actionValue":"旧","iconValue":"keep"},{"stateIndex":2,"flickDirection":"TAP","actionValue":"別"}],"extra":"unchanged"}]}"#
        let imported = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var editor = CustomLayoutEditor(layout: imported)
        let before = editor.source
        XCTAssertThrowsError(try editor.setStandardFlick(id: "a", values: ["too few"]))
        XCTAssertEqual(editor.source, before)
        try editor.setStandardFlick(id: "a", values: ["あ", "い", "う", "え", "お"])
        let key = try XCTUnwrap(editor.validated().placements.first)
        XCTAssertEqual(try CustomStandardFlick(placement: key).values, ["あ", "い", "う", "え", "お"])
        let mappings = try XCTUnwrap(key.source["flicks"]?.array)
        XCTAssertEqual(mappings.count, 6)
        XCTAssertEqual(mappings[1]["iconValue"], .string("keep"))
        XCTAssertEqual(mappings.last?["actionValue"], .string("別"))
        XCTAssertEqual(key.source["extra"], .string("unchanged"))
        try editor.setKeyType(id: "a", type: "NORMAL")
        XCTAssertEqual(try editor.validated().placements.first?.source["flicks"], key.source["flicks"])
        XCTAssertThrowsError(try editor.setKeyType(id: "missing", type: "NORMAL"))
    }
    func testCreateEditRejectOverlapAndPreserveImportedFields() throws {
        var editor = CustomLayoutEditor(name: "作成", rows: 2, columns: 2)
        editor.putKey(id: "a", label: "あ", action: "InputText:あ", special: false, row: 0, column: 0, height: 2, width: 2)
        var library = CustomKeyboardLibrary()
        try library.append([editor.validated()])
        let id = try XCTUnwrap(library.layouts().first?.id)
        library.activeID = id
        editor.putKey(id: "b", label: "い", action: "InputText:い", special: false, row: 0, column: 0, height: 2, width: 2)
        XCTAssertThrowsError(try editor.validated())
        editor.putKey(id: "b", label: "い", action: "InputText:い", special: false, row: 0, column: 2, height: 2, width: 2)
        try library.replace(editor.validated())
        XCTAssertEqual(library.activeID, id)
        XCTAssertEqual(try library.layouts().first?.placements.count, 2)
        editor.configure(name: "狭い", rows: 1, columns: 1)
        XCTAssertThrowsError(try editor.validated())
        let raw = #"{"layout":{"name":"参照","rowCount":1,"columnCount":1,"extra":"keep"},"keysWithFlicks":[{"key":{"label":"あ","keyType":"FLICK","unknown":42},"flicks":[{"flickDirection":"UP","actionValue":"う"}]}]}"#
        let imported = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var editing = CustomLayoutEditor(layout: imported)
        let keyID = imported.placements[0].id
        editing.putKey(id: keyID, label: "か", action: "InputText:か", special: false, row: 0, column: 0, height: 2, width: 2)
        let updated = try editing.validated()
        XCTAssertEqual(updated.placements.count, 1)
        XCTAssertEqual(updated.id, imported.id)
        XCTAssertEqual(updated.placements[0].id, keyID)
        XCTAssertEqual(updated.source["layout"]?["extra"], .string("keep"))
        XCTAssertEqual(updated.placements[0].source["flicks"], imported.placements[0].source["flicks"])
        XCTAssertEqual(updated.placements[0].source["key"]?["keyType"], .string("FLICK"))
        XCTAssertEqual(updated.placements[0].source["key"]?["unknown"], .integer(42))
        editing.removeKey(id: keyID)
        XCTAssertTrue(try editing.validated().placements.isEmpty)
    }
}
