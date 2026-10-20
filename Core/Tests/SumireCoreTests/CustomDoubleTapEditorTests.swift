import XCTest
@testable import SumireCore

final class CustomDoubleTapEditorTests: XCTestCase {
    func testBindingEditsPreserveImportedGestureAndUnknownFields() throws {
        let raw = #"{"layout":{"stableId":"a","name":"A","rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"keyIdentifier":"key","action":"Delete","isSpecialKey":true,"keyType":"STANDARD_FLICK","futureFlag":42},"flicks":[{"flickDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"あ","futureMapping":true}],"futureItem":"preserved"}]}"#
        let original = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var editor = CustomLayoutEditor(layout: original)
        let item = try XCTUnwrap(editor.source["keysWithFlicks"]?.array?.first)
        try editor.setDoubleTap(id: "key", enabled: true, action: "Paste")
        let changed = try XCTUnwrap(editor.source["keysWithFlicks"]?.array?.first)
        XCTAssertEqual(changed["flicks"], item["flicks"])
        XCTAssertEqual(changed["futureItem"], .string("preserved"))
        XCTAssertEqual(changed["key"]?["futureFlag"], .integer(42))
        XCTAssertEqual(changed["key"]?["doubleTapPolicy"], .string("EXCLUSIVE"))
        try editor.setDoubleTap(id: "key", enabled: false, action: "Paste")
        XCTAssertEqual(editor.source["keysWithFlicks"]?.array?.first?["key"]?["doubleTapEnabled"], .bool(false))
        let saved = try editor.validated()
        XCTAssertEqual(saved.placements.first?.source["flicks"], item["flicks"])
    }
    func testInvalidBindingEditIsAtomic() throws {
        var editor = CustomLayoutEditor()
        editor.putKey(id: "key", label: "削除", action: "Delete", special: true, row: 0, column: 0, height: 2, width: 2)
        let before = editor.source
        XCTAssertThrowsError(try editor.setDoubleTap(id: "key", enabled: true, action: ""))
        XCTAssertEqual(editor.source, before)
        XCTAssertThrowsError(try editor.setDoubleTap(id: "missing", enabled: true, action: "Paste"))
        XCTAssertEqual(editor.source, before)
    }
}
