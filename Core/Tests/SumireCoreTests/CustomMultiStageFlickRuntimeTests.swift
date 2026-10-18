import XCTest
@testable import SumireCore

final class CustomMultiStageFlickRuntimeTests: XCTestCase {
    private func placement(_ key: String, fields: String = "") throws -> ImportedCustomLayout.Placement {
        let extra = fields.isEmpty ? "" : ",\(fields)"
        let source = """
        {"layout":{"stableId":"runtime","name":"runtime","rowCount":1,"columnCount":1},
         "keysWithFlicks":[{"key":{"keyIdentifier":"key","label":"K",\(key)}\(extra)}]}
        """
        return try XCTUnwrap(CustomLayoutImportPreview.parse(Data(source.utf8)).layouts.first?.placements.first)
    }

    func testSingleStagePreservesFarDirectionActionAndLongPress() throws {
        let key = try placement(#""keyType":"STANDARD_FLICK","action":"Text:基""#,
            fields: #""flicks":[{"stateIndex":0,"flickDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"た"},{"stateIndex":0,"flickDirection":"UP_LEFT","actionType":"INPUT_TEXT","actionValue":"近"},{"stateIndex":0,"flickDirection":"UP_LEFT_FAR","actionType":"INPUT_TEXT","actionValue":"遠"},{"stateIndex":0,"flickDirection":"UP","actionType":"DELETE"},{"stateIndex":1,"flickDirection":"TAP","actionValue":"別"}],"longPressFlicks":[{"flickDirection":"UP","output":"長"}]"#)
        let runtime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: key, targets: CustomLayoutTargets(layouts: [])))
        guard case .single(.standard, let map, let alternate) = runtime.gesture else {
            return XCTFail("Expected the standard single-stage evaluator")
        }
        XCTAssertEqual(map[.tap], "た")
        XCTAssertEqual(map[.left], "遠")
        XCTAssertEqual(map[.up], "⌫")
        XCTAssertEqual(alternate[.up], "長")
        XCTAssertEqual(runtime.actions[.up], .command(.delete))
        XCTAssertEqual(runtime.longPressActions[.up], .text("長"))
    }

    func testSingleStageRejectsDirectionsOutsidePinnedAndroidSchema() throws {
        let key = try placement(#""keyType":"STANDARD_FLICK""#,
            fields: #""flicks":[{"stateIndex":0,"flickDirection":"DOWN_LEFT","actionValue":"不正"}]"#)
        XCTAssertThrowsError(try CustomMultiStageFlick.runtimeDefinition(
            for: key, targets: CustomLayoutTargets(layouts: [])))
    }

    func testTwoStepAndStickyMapsDecodeTheirOwnHoldBehavior() throws {
        let key = try placement(#""keyType":"TWO_STEP_FLICK""#,
            fields: #""twoStepFlicks":[{"firstDirection":"UP","secondDirection":"RIGHT","output":"二"}],"twoStepLongPressFlicks":[{"firstDirection":"UP","secondDirection":"RIGHT","output":"長"}]"#)
        let runtime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: key, targets: CustomLayoutTargets(layouts: [])))
        guard case .twoStep(let map, let alternate, let sticky) = runtime.gesture else {
            return XCTFail("Expected two-step gesture")
        }
        XCTAssertFalse(sticky)
        XCTAssertEqual(map[.up]?[.right], "二")
        XCTAssertEqual(alternate[.up]?[.right], "長")

        let stickyKey = try placement(#""keyType":"STICKY_TWO_STEP_FLICK""#,
            fields: #""twoStepFlicks":[{"firstDirection":"UP","secondDirection":"UP","output":"継"}],"twoStepLongPressFlicks":[{"firstDirection":"UP","secondDirection":"UP","output":"使わない"}]"#)
        let stickyRuntime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: stickyKey, targets: CustomLayoutTargets(layouts: [])))
        guard case .twoStep(_, let stickyAlternate, let stickyMode) = stickyRuntime.gesture else {
            return XCTFail("Expected sticky two-step gesture")
        }
        XCTAssertTrue(stickyMode)
        XCTAssertTrue(stickyAlternate.isEmpty)
    }

    func testCircularActionsAndDirectionalLongPressDecode() throws {
        let circular = try placement(#""keyType":"CIRCULAR_FLICK""#,
            fields: #""circularFlicks":[{"stateIndex":0,"circularDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"中心"},{"stateIndex":0,"circularDirection":"SLOT_0","actionType":"INPUT_TEXT","actionValue":"上"},{"stateIndex":0,"circularDirection":"SLOT_1","actionType":"DELETE"}]"#)
        let circularRuntime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: circular, targets: CustomLayoutTargets(layouts: [])))
        guard case .circular(let maps) = circularRuntime.gesture else {
            return XCTFail("Expected circular gesture")
        }
        XCTAssertEqual(maps.first?[.tap], .text("中心"))
        XCTAssertEqual(maps.first?[.slot0], .text("上"))
        XCTAssertEqual(maps.first?[.slot1], .action("DELETE", value: nil, label: "DELETE"))

        let longPress = try placement(#""keyType":"FLICK_LONG_PRESS""#,
            fields: #""twoStepFlicks":[{"firstDirection":"TAP","secondDirection":"TAP","output":"基"},{"firstDirection":"UP_LEFT","secondDirection":"UP_LEFT","output":"斜"},{"firstDirection":"UP","secondDirection":"UP","output":"上"}],"twoStepLongPressFlicks":[{"firstDirection":"UP","secondDirection":"UP","output":"長"}]"#)
        let longPressRuntime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: longPress, targets: CustomLayoutTargets(layouts: [])))
        guard case .single(.directionalLongPress, let map, let alternate) = longPressRuntime.gesture else {
            return XCTFail("Expected directional long press gesture")
        }
        XCTAssertEqual(map[.tap], "基")
        XCTAssertEqual(map[.upLeft], "斜")
        XCTAssertEqual(map[.up], "上")
        XCTAssertEqual(alternate[.up], "長")
    }

    func testDirectionalLongPressUsesOnlyTextualKeyTapFallback() throws {
        let textual = try placement(#""keyType":"FLICK_LONG_PRESS","action":"InputText:K""#,
            fields: #""twoStepFlicks":[{"firstDirection":"UP","secondDirection":"UP","output":"上"}]"#)
        let textualRuntime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: textual, targets: CustomLayoutTargets(layouts: [])))
        XCTAssertEqual(textualRuntime.actions[.tap], .inputText("K"))
        guard case .single(_, let textualMap, _) = textualRuntime.gesture else {
            return XCTFail("Expected directional long-press gesture")
        }
        XCTAssertEqual(textualMap[.tap], "K")

        let command = try placement(#""keyType":"FLICK_LONG_PRESS","action":"Delete""#,
            fields: #""twoStepFlicks":[{"firstDirection":"UP","secondDirection":"UP","output":"上"}]"#)
        let commandRuntime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(
            for: command, targets: CustomLayoutTargets(layouts: [])))
        XCTAssertNil(commandRuntime.actions[.tap])
        guard case .single(_, let commandMap, _) = commandRuntime.gesture else {
            return XCTFail("Expected directional long-press gesture")
        }
        XCTAssertNil(commandMap[.tap])
    }

    func testCircularFlickCompactsSparseStateIndexesLikeAndroid() throws {
        let key = try placement(#""keyType":"CIRCULAR_FLICK""#,
            fields: #""circularFlicks":[{"stateIndex":0,"circularDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"一"},{"stateIndex":2,"circularDirection":"TAP","actionType":"INPUT_TEXT","actionValue":"三"}]"#)
        let maps = try CustomMultiStageFlick.circular(key)
        XCTAssertEqual(maps.count, 2)
        XCTAssertEqual(maps[0][.tap], .text("一"))
        XCTAssertEqual(maps[1][.tap], .text("三"))
    }

    func testUnsupportedHierarchyIsRejectedInsteadOfBecomingTapText() throws {
        let key = try placement(#""keyType":"HIERARCHICAL_FLICK""#,
            fields: #""flicks":[{"flickDirection":"TAP","actionValue":"誤変換しない"}]"#)
        XCTAssertThrowsError(try CustomMultiStageFlick.runtimeDefinition(
            for: key, targets: CustomLayoutTargets(layouts: [])))
    }
}
