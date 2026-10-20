import XCTest
@testable import SumireCore

final class CustomGestureEditorTests: XCTestCase {
    private func editor(type: String = "NORMAL") throws -> CustomLayoutEditor {
        var value = CustomLayoutEditor(name: "Gesture fixture", rows: 1, columns: 1)
        value.putKey(id: "key", label: "基", action: "Text:基", special: false, row: 0, column: 0, height: 2, width: 2)
        try value.setKeyType(id: "key", type: type)
        return value
    }
    private func row(_ json: String) throws -> LayoutJSON {
        try JSONDecoder().decode(LayoutJSON.self, from: Data(json.utf8))
    }
    private func placement(_ editor: CustomLayoutEditor) throws -> ImportedCustomLayout.Placement {
        try XCTUnwrap(editor.validated().placements.first)
    }
    func testEverySupportedTypeCanBeCreatedAndDecodedAfterLibraryRoundTrip() throws {
        for type in ["NORMAL", "STANDARD_FLICK", "PETAL_FLICK", "CENTER_GUIDE_FLICK", "CROSS_FLICK", "CIRCULAR_FLICK",
                     "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK", "FLICK_LONG_PRESS"] {
            var value = try editor(type: type)
            let field: String
            let mapping: LayoutJSON
            switch type {
            case "CIRCULAR_FLICK":
                field = "circularFlicks"
                mapping = try row(#"{"stateIndex":0,"circularDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"円"}"#)
            case "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK", "FLICK_LONG_PRESS":
                field = "twoStepFlicks"
                mapping = try row(#"{"firstDirection":"TAP","secondDirection":"TAP","output":"段"}"#)
            default:
                field = "flicks"
                mapping = try row(#"{"stateIndex":0,"flickDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"単"}"#)
            }
            try value.setGestureMappings(id: "key", field: field, mappings: [mapping])
            var library = CustomKeyboardLibrary()
            try library.append([value.validated()])
            let encoded = try JSONEncoder().encode(library)
            let restored = try JSONDecoder().decode(CustomKeyboardLibrary.self, from: encoded)
            let layout = try XCTUnwrap(restored.layouts().first)
            let key = try XCTUnwrap(layout.placements.first)
            XCTAssertEqual(key.source["key"]?["keyType"], .string(type))
            XCTAssertEqual(key.source[field], .array([mapping]))
            let runtime = try CustomMultiStageFlick.runtimeDefinition(for: key, targets: CustomLayoutTargets(layouts: [layout]))
            if type == "NORMAL" { XCTAssertNil(runtime) }
            else { XCTAssertNotNil(runtime, type) }
        }
    }
    func testSelectedArraysPreserveUnrelatedMetadataAndUnknownActionRows() throws {
        let raw = #"{"layout":{"stableId":"preserve","name":"P","rowCount":1,"columnCount":1,"futureLayout":42},"keysWithFlicks":[{"key":{"keyIdentifier":"key","label":"基","keyType":"STANDARD_FLICK","action":"Text:基","futureKey":"keep"},"flicks":[{"flickDirection":"TAP","actionValue":"旧"}],"longPressFlicks":[{"flickDirection":"UP","output":"長","futureLong":true}],"futureItem":{"nested":"keep"}}]}"#
        let layout = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var value = CustomLayoutEditor(layout: layout)
        let before = value.source
        let unknown = try row(#"{"flickDirection":"UP","actionType":"FUTURE_ACTION","actionValue":"opaque","futureMapping":{"a":1}}"#)
        try value.setGestureMappings(id: "key", field: "flicks", mappings: [unknown])
        let changed = try placement(value)
        XCTAssertEqual(changed.source["flicks"], .array([unknown]))
        XCTAssertEqual(changed.source["key"], before["keysWithFlicks"]?.array?.first?["key"])
        XCTAssertEqual(changed.source["longPressFlicks"], before["keysWithFlicks"]?.array?.first?["longPressFlicks"])
        XCTAssertEqual(changed.source["futureItem"], before["keysWithFlicks"]?.array?.first?["futureItem"])
        XCTAssertEqual(value.source["layout"], before["layout"])
        XCTAssertTrue(CustomLayoutActionReview(layouts: [try value.validated()]).unsupported.contains {
            if case .unsupported(let raw, _) = $0.action { return raw.contains("FUTURE_ACTION") }
            return false
        })
    }
    func testMultiFieldUpdateAllowsAlternateOnlyMapAndRejectsAtomically() throws {
        var value = try editor(type: "FLICK_LONG_PRESS")
        value.putKey(id: "key", label: "基", action: "", special: false, row: 0, column: 0, height: 2, width: 2)
        let alternate = try row(#"{"firstDirection":"UP","secondDirection":"UP","output":"長"}"#)
        try value.setGestureMappings(id: "key", fields: ["twoStepFlicks": [], "twoStepLongPressFlicks": [alternate]])
        guard case .single(.directionalLongPress, let map, let held) = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: placement(value), targets: CustomLayoutTargets(layouts: []))).gesture else { return XCTFail("Wrong runtime") }
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(held[.up], "長")
        let before = value.source
        XCTAssertThrowsError(try value.setGestureMappings(id: "key", fields: ["twoStepFlicks": [], "twoStepLongPressFlicks": [alternate, alternate]]))
        XCTAssertEqual(value.source, before)
    }
    func testMalformedDuplicateUnknownFieldAndOversizeRejectWithoutMutation() throws {
        var value = try editor(type: "STANDARD_FLICK")
        let valid = try row(#"{"stateIndex":0,"flickDirection":"TAP","actionValue":"あ"}"#)
        try value.setGestureMappings(id: "key", field: "flicks", mappings: [valid])
        let before = value.source
        let stateOne = try row(#"{"stateIndex":1,"flickDirection":"UP","actionValue":"別"}"#)
        for update: [String: [LayoutJSON]] in [
            ["flicks": [.string("malformed")]], ["flicks": [valid, valid]],
            ["flicks": [valid, stateOne, stateOne]],
            ["longPressFlicks": [try row(#"{"flickDirection":"UP"}"#)]],
            ["circularFlicks": [try row(#"{"circularDirection":"SLOT_99"}"#)]],
            ["twoStepFlicks": [try row(#"{"firstDirection":"UP","output":"欠落"}"#)]],
            ["twoStepLongPressFlicks": [.null]], ["../flicks": [valid]],
            ["flicks": Array(repeating: valid, count: 4097)]
        ] {
            XCTAssertThrowsError(try value.setGestureMappings(id: "key", fields: update))
            XCTAssertEqual(value.source, before)
        }
        XCTAssertThrowsError(try value.setGestureMappings(id: "missing", field: "flicks", mappings: [valid]))
        XCTAssertEqual(value.source, before)
        XCTAssertThrowsError(try value.setKeyType(id: "key", type: "HIERARCHICAL_FLICK"))
        XCTAssertEqual(value.source, before)
    }
    func testClearingNativeCircularRowsCannotReactivatePreservedLegacyMappings() throws {
        let raw = #"{"layout":{"stableId":"legacy-circle","name":"Legacy","rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"keyIdentifier":"key","label":"円","keyType":"CIRCULAR_FLICK"},"flicks":[{"flickDirection":"TAP","actionValue":"旧","futureLegacy":true}]}]}"#
        let layout = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(raw.utf8)).layouts.first)
        var value = CustomLayoutEditor(layout: layout)
        let legacy = try placement(value).source["flicks"]
        let native = try row(#"{"circularDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"新"}"#)
        try value.setGestureMappings(id: "key", field: "circularFlicks", mappings: [native])
        XCTAssertEqual(try placement(value).source["flicks"], legacy)
        let before = value.source
        XCTAssertThrowsError(try value.setGestureMappings(id: "key", field: "circularFlicks", mappings: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("旧形式"))
        }
        XCTAssertEqual(value.source, before)
        guard case .circular(let maps) = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: placement(value), targets: CustomLayoutTargets(layouts: []))).gesture else { return XCTFail("Expected circular runtime") }
        XCTAssertEqual(maps.first?[.tap], .text("新"))
    }

}
