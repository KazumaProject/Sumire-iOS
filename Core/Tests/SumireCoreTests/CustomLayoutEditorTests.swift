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
    func testSwapKeyPlacementsExchangesFullHalfCellPlacementAndPreservesOtherData() throws {
        let raw = #"{"layout":{"stableId":"swap-layout","name":"交換","rowCount":2,"columnCount":3,"unknownLayoutField":"keep"},"keysWithFlicks":[{"key":{"keyIdentifier":"left","label":"左","keyType":"NORMAL","rowUnits":0,"columnUnits":0,"rowSpanUnits":2,"columnSpanUnits":2,"unknownKeyField":{"value":"left"}},"flicks":[{"flickDirection":"UP","actionValue":"左上"}],"unknownItemField":"left-item"},{"key":{"keyIdentifier":"wide","label":"右","keyType":"STANDARD_FLICK","rowUnits":2,"columnUnits":3,"rowSpanUnits":2,"columnSpanUnits":3,"row":1,"column":1},"unknownItemField":"wide-item"}],"spacers":[{"itemIdentifier":"reserved-space","rowUnits":2,"columnUnits":0,"rowSpanUnits":2,"columnSpanUnits":2,"unknownSpacerField":"keep"}]}"#
        let imported = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var editor = CustomLayoutEditor(layout: imported)
        let before = editor.source

        try editor.swapKeyPlacements(draggedID: "left", targetID: "wide")
        let swapped = try editor.validated()
        let left = try XCTUnwrap(swapped.placements.first { $0.id == "left" })
        let wide = try XCTUnwrap(swapped.placements.first { $0.id == "wide" })
        let spacer = try XCTUnwrap(swapped.placements.first { $0.id == "reserved-space" })

        XCTAssertEqual(left.row, 2)
        XCTAssertEqual(left.column, 3)
        XCTAssertEqual(left.height, 2)
        XCTAssertEqual(left.width, 3)
        XCTAssertEqual(wide.row, 0)
        XCTAssertEqual(wide.column, 0)
        XCTAssertEqual(wide.height, 2)
        XCTAssertEqual(wide.width, 2)
        XCTAssertEqual(spacer.row, 2)
        XCTAssertEqual(spacer.column, 0)
        XCTAssertEqual(spacer.height, 2)
        XCTAssertEqual(spacer.width, 2)
        XCTAssertEqual(left.source["key"]?["label"], .string("左"))
        XCTAssertEqual(left.source["key"]?["unknownKeyField"]?["value"], .string("left"))
        XCTAssertEqual(left.source["flicks"], before["keysWithFlicks"]?.array?.first?["flicks"])
        XCTAssertEqual(left.source["unknownItemField"], .string("left-item"))
        XCTAssertEqual(wide.source["unknownItemField"], .string("wide-item"))
        XCTAssertEqual(spacer.source["unknownSpacerField"], .string("keep"))
        XCTAssertEqual(swapped.source["layout"]?["unknownLayoutField"], .string("keep"))

        try editor.swapKeyPlacements(draggedID: "left", targetID: "wide")
        XCTAssertEqual(editor.source, before, "Swapping the same pair twice should restore the original source exactly")
    }

    func testSwapKeyPlacementsRejectsMissingAndSpacerIDsWithoutChangingSource() throws {
        let raw = #"{"layout":{"stableId":"swap-layout","rowCount":1,"columnCount":2},"keysWithFlicks":[{"key":{"keyIdentifier":"a","label":"あ","rowUnits":0,"columnUnits":0,"rowSpanUnits":2,"columnSpanUnits":2}}],"spacers":[{"itemIdentifier":"space","rowUnits":0,"columnUnits":2,"rowSpanUnits":2,"columnSpanUnits":2}]}"#
        let imported = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var editor = CustomLayoutEditor(layout: imported)
        let original = editor.source

        XCTAssertNoThrow(try editor.swapKeyPlacements(draggedID: "a", targetID: "a"))
        XCTAssertEqual(editor.source, original)
        XCTAssertThrowsError(try editor.swapKeyPlacements(draggedID: "a", targetID: "missing"))
        XCTAssertEqual(editor.source, original)
        XCTAssertThrowsError(try editor.swapKeyPlacements(draggedID: "a", targetID: "space"))
        XCTAssertEqual(editor.source, original)
    }

    func testSwapKeyPlacementsRejectsInvalidCurrentLayoutAtomically() throws {
        var editor = CustomLayoutEditor(name: "重複", rows: 1, columns: 2)
        editor.putKey(id: "a", label: "あ", action: "Text:あ", special: false, row: 0, column: 0, height: 2, width: 2)
        editor.putKey(id: "b", label: "い", action: "Text:い", special: false, row: 0, column: 0, height: 2, width: 2)
        let original = editor.source

        XCTAssertThrowsError(try editor.swapKeyPlacements(draggedID: "a", targetID: "b"))
        XCTAssertEqual(editor.source, original)
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
