#if DEBUG
import XCTest
import SumireCore
@testable import Sumire

final class CustomGestureDraftTests: XCTestCase {
    func testReadingAndEditingOneRowPreservesCommandsAliasesAndUnknownFields() throws {
        let source: LayoutJSON = .object(["flicks": .array([
            .object(["stateIndex": .integer(4), "flickDirection": .string("UP_LEFT"),
                     "actionType": .string("DELETE"), "actionValue": .string("old"), "iconValue": .string("keep")]),
            .object(["stateIndex": .integer(9), "flickDirection": .string("TAP"), "actionValue": .string("other")])]),
            "longPressFlicks": .array([.object(["flickDirection": .string("UP"), "output": .string("長")])])])
        var draft = CustomGestureDraft(source: source)
        XCTAssertTrue(draft.changes.isEmpty)
        draft.rows["flicks"]?[0].set("actionValue", .string("updated"))
        let changed = try XCTUnwrap(draft.changes["flicks"])
        XCTAssertEqual(draft.changes.count, 1)
        XCTAssertEqual(changed[0]["actionType"], .string("DELETE"))
        XCTAssertEqual(changed[0]["iconValue"], .string("keep"))
        XCTAssertEqual(changed[0]["flickDirection"], .string("UP_LEFT"))
        XCTAssertEqual(changed[1], source["flicks"]?.array?[1])
    }
    func testRetainedUnresolvedTargetsSurviveOtherRowAndMetadataEdits() throws {
        let missing: LayoutJSON = .object(["flickDirection": .string("UP"), "actionType": .string("MoveToCustomKeyboard"),
            "actionValue": .string("missing-layout"), "future": .object(["keep": .bool(true)])])
        var draft = CustomGestureDraft(source: .object(["flicks": .array([missing,
            .object(["flickDirection": .string("TAP"), "actionType": .string("INPUT_TEXT"), "actionValue": .string("あ")])])]))
        draft.rows["flicks"]?[1].set("actionValue", .string("い"))
        XCTAssertTrue(draft.newlyAssignedLayoutTargets.isEmpty)
        XCTAssertEqual(draft.changes["flicks"]?[0], missing)
        draft.rows["flicks"]?[0].set("stateIndex", .integer(3))
        XCTAssertTrue(draft.newlyAssignedLayoutTargets.isEmpty)
        XCTAssertEqual(draft.changes["flicks"]?[0]["future"], missing["future"])
        // The same retained row moves to the native circular array, preserving UUID.
        draft.prepare(type: "CIRCULAR_FLICK", label: "unused")
        XCTAssertTrue(draft.newlyAssignedLayoutTargets.isEmpty)
        XCTAssertEqual(draft.changes["circularFlicks"]?[0]["future"], missing["future"])
    }
    func testNewAndRetargetedLayoutReferencesAreEmittedIncludingEmptyTarget() throws {
        let target: LayoutJSON = .object(["flickDirection": .string("UP"), "actionType": .string("MoveToCustomKeyboard"),
            "actionValue": .string("old"), "future": .integer(42)])
        var draft = CustomGestureDraft(source: .object(["flicks": .array([target])]))
        draft.rows["flicks"]?[0].set("actionValue", .string("new"))
        XCTAssertEqual(draft.newlyAssignedLayoutTargets.count, 1)
        XCTAssertEqual(draft.newlyAssignedLayoutTargets.first?["actionValue"], .string("new"))
        XCTAssertEqual(draft.newlyAssignedLayoutTargets.first?["future"], .integer(42))
        draft.rows["flicks"]?[0].set("actionValue", .string("old"))
        XCTAssertTrue(draft.newlyAssignedLayoutTargets.isEmpty)
        draft.rows["flicks", default: []].append(.init(.object(["flickDirection": .string("TAP"),
            "actionType": .string("MoveToCustomKeyboard"), "actionValue": .string("")])))
        let newlyAssigned = try XCTUnwrap(draft.newlyAssignedLayoutTargets.first)
        XCTAssertEqual(newlyAssigned["actionValue"], .string(""))
        XCTAssertEqual(draft.newlyAssignedLayoutTargets.count, 1)
        if case .unsupported = CustomKeyAction.flick(type: "MoveToCustomKeyboard",
            value: newlyAssigned["actionValue"]?.string, targets: CustomLayoutTargets(layouts: [])) {} else {
            XCTFail("A newly assigned empty target must fail validation")
        }
    }
    func testEveryNewSupportedGestureCanBeSavedAndLoadedAsRuntime() throws {
        for (type, _) in CustomGestureDraft.types where type != "NORMAL" {
            var editor = CustomLayoutEditor(rows: 1, columns: 1)
            editor.putKey(id: "a", label: "あ", action: "Text:あ", special: false, row: 0, column: 0, height: 2, width: 2)
            try editor.setKeyType(id: "a", type: type)
            var draft = CustomGestureDraft(); draft.prepare(type: type, label: "あ")
            try editor.setGestureMappings(id: "a", fields: draft.changes)
            var library = CustomKeyboardLibrary(); try library.append([editor.validated()])
            let layout = try XCTUnwrap(library.layouts().first)
            let key = try XCTUnwrap(layout.placements.first)
            XCTAssertNotNil(try CustomMultiStageFlick.runtimeDefinition(for: key, targets: CustomLayoutTargets(layouts: [layout])), type)
        }
    }
    func testLegacyCircularPreparationIsExplicitAndPreservesSparseStatesMetadata() throws {
        let rows: [LayoutJSON] = [
            .object(["stateIndex": .integer(7), "flickDirection": .string("UP"), "actionType": .string("INPUT_TEXT"), "actionValue": .string("あ"), "iconValue": .string("keep")]),
            .object(["stateIndex": .integer(30), "flickDirection": .string("TAP"), "actionValue": .string("次")])]
        var draft = CustomGestureDraft(source: .object(["flicks": .array(rows)]))
        XCTAssertTrue(draft.changes.isEmpty)
        draft.prepare(type: "CIRCULAR_FLICK", label: "unused")
        let updated = try XCTUnwrap(draft.changes["circularFlicks"])
        XCTAssertEqual(updated[0]["stateIndex"], .integer(7))
        XCTAssertEqual(updated[0]["circularDirection"], .string("SLOT_0"))
        XCTAssertEqual(updated[0]["iconValue"], .string("keep"))
        XCTAssertEqual(draft.rows["flicks"]?.map(\.source), rows)
        draft.reorderCircularMaps([30, 7])
        XCTAssertEqual(draft.rows["circularFlicks"]?[0].source["stateIndex"], .integer(1))
        XCTAssertEqual(draft.rows["circularFlicks"]?[1].source["stateIndex"], .integer(0))
        draft.addCircularMap()
        XCTAssertEqual(draft.rows["circularFlicks"]?.last?.source["stateIndex"], .integer(2))
    }
    func testTwoStepStartGuideIdentifiesUnreachableNormalBranchesWithoutDroppingRows() {
        var draft = CustomGestureDraft(source: .object(["twoStepFlicks": .array([
            .object(["firstDirection": .string("UP"), "secondDirection": .string("LEFT"), "output": .string("え")]),
            .object(["firstDirection": .string("UP"), "secondDirection": .string("TAP"), "output": .string(""), "extra": .integer(42)])])]))
        XCTAssertEqual(draft.missingTwoStepStarts, ["UP"])
        draft.addTwoStepStart("UP", output: "あ")
        XCTAssertTrue(draft.missingTwoStepStarts.isEmpty)
        XCTAssertEqual(draft.rows["twoStepFlicks"]?.count, 2)
        XCTAssertEqual(draft.rows["twoStepFlicks"]?[1].source["extra"], .integer(42))
    }

}
#endif
