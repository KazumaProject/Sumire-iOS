import XCTest
@testable import SumireCore

final class MultiStageFlickTests: XCTestCase {
    private let map: TwoStepFlickEvaluator.Map = [
        .tap: [.tap: "か"], .left: [.tap: "き", .left: "き", .upLeft: "ぎ", .downLeft: "きゃ"],
        .up: [.tap: "く", .up: "く", .upRight: "ぐ"]]
    func testReleaseMetadataUsesFinalDirectionAndConsumesOnce() throws {
        var single = SingleStageFlickEvaluator(style: .standard, map: [.tap: "あ", .right: "え"])
        single.begin(at: .init(0, 0), configuration: .init())
        let selection = try XCTUnwrap(single.endSelection(at: .init(100, 0)))
        XCTAssertEqual(selection.direction, .right)
        XCTAssertEqual(selection.text, "え")
        XCTAssertFalse(selection.longPress)
        XCTAssertNil(single.endSelection(at: .init(100, 0)))
        var two = TwoStepFlickEvaluator(map: [.tap: [.tap:"か"], .right: [.tap:"か", .right:"け"]])
        two.begin(at: .init(0, 0), configuration: .init())
        let value = try XCTUnwrap(two.endSelection(at: .init(100, 0)))
        XCTAssertEqual(value.first, .right); XCTAssertEqual(value.second, .right)
        XCTAssertEqual(value.text, "け")
        XCTAssertNil(two.endSelection(at: .init(100, 0)))
        two.begin(at: .init(0, 0), configuration: .init()); two.hold()
        XCTAssertTrue(try XCTUnwrap(two.endSelection(at: .init(0, 0))).longPress)
    }
    func testTwoStepHoldExpandsGuideAndCancelClearsIt() {
        var evaluator = TwoStepFlickEvaluator(map: map, sticky: true)
        evaluator.begin(at: .init(0, 0), configuration: .init())
        XCTAssertFalse(evaluator.expandedGuide)
        evaluator.hold()
        XCTAssertTrue(evaluator.expandedGuide)
        XCTAssertFalse(evaluator.longPress)
        evaluator.cancel()
        XCTAssertFalse(evaluator.expandedGuide)
    }
    func testNormalHoldNeverAlsoTapsAndCancellation() {
        var key = TapHoldEvaluator()
        key.begin(at: .init(20, 20), configuration: .init())
        XCTAssertEqual(key.hold(), .longPress)
        XCTAssertNil(key.hold())
        XCTAssertEqual(key.end(), .upAfterLongPress)
        XCTAssertNil(key.end())
        key.begin(at: .init(20, 20), configuration: .init()); key.move(to: .init(100, 100))
        XCTAssertNil(key.end())
        key.begin(at: .init(20, 20), configuration: .init()); _ = key.hold()
        XCTAssertEqual(key.cancel(), .longPressCancelled)
    }
    func testGuideGridUsesRectangularCellsAndKeyCenterOrigin() {
        var config = MultiFlickConfiguration(); config.guideGrid = true
        config.keyWidth = 120; config.keyHeight = 60; config.startsAtKeyCenter = true
        let position = config.guidePosition(.init(40, 15), down: .init(10, 10))
        XCTAssertEqual(position, .init(0.75, 7.0 / 12.0))
        XCTAssertEqual(config.direction(delta: .init(30, 5), enabled: [.right, .upRight], position: position), .right)
        XCTAssertEqual(config.direction(delta: .init(30, 5), enabled: [.upRight], position: position), .upRight)
    }
    func testReferenceDefaultsAndBounds() {
        var settings = FlickStyleSettings()
        XCTAssertEqual(settings.style.referenceKeyType, "PETAL_FLICK")
        XCTAssertEqual(settings.presentation, .legacyGrid)
        XCTAssertEqual(settings.startPosition, .touchPoint)
        XCTAssertEqual(settings.diagonal, .legacy)
        XCTAssertEqual(settings.circularDirectionCount, 4)
        settings.circularDirectionCount = 100; settings.hierarchicalModeAngleMargin = -1
        XCTAssertEqual(settings.normalized.circularDirectionCount, 7)
        XCTAssertEqual(settings.normalized.hierarchicalModeAngleMargin, 0)
    }
    func testImportedTwoStepMapsPreserveDirectionsAndRejectDuplicate() throws {
        let mapping: LayoutJSON = .object(["firstDirection": .string("LEFT"), "secondDirection": .string("UP_LEFT"), "output": .string("ぎ")])
        func key(_ rows: [LayoutJSON]) -> ImportedCustomLayout.Placement {
            .init(id: "key", row: 0, column: 0, height: 2, width: 2, isSpacer: false, source: .object(["twoStepFlicks": .array(rows)]))
        }
        XCTAssertEqual(try CustomMultiStageFlick.twoStep(key([mapping]))[.left]?[.upLeft], "ぎ")
        XCTAssertThrowsError(try CustomMultiStageFlick.twoStep(key([mapping, mapping])))
    }
    func testRotationMovesDiacriticsButKeepsVowelAxis() {
        let map: TwoStepFlickEvaluator.Map = [.left: [.left: "き", .upLeft: "ぎ", .downLeft: "きゃ"]]
        let result = SumireFlickMapTransform.rotate(map, label: "か", rotation: .clockwise)
        XCTAssertEqual(result[.left]?[.left], "き")
        XCTAssertEqual(result[.left]?[.downLeft], "ぎ")
        XCTAssertEqual(result[.left]?[.upLeft], "きゃ")
        XCTAssertEqual(SumireFlickMapTransform.rotate(map, label: "な", rotation: .clockwise), map)
    }
    func testThreeStepInputFilterUsesUnicodeScalars() {
        let root: HierarchicalFlickEvaluator.Map = [.tap: .input("か"), .left: .input("が"), .up: .input("きゃ"), .right: .input("12"), .down: .input("！")]
        let contracted = SumireFlickMapTransform.transform([.normal: root, .dakuten: root], label: "か", input: .contracted, rotation: .clockwise)
        XCTAssertNil(contracted[.dakuten]); XCTAssertNil(contracted[.normal]?[.left]); XCTAssertNil(contracted[.normal]?[.right])
        XCTAssertEqual(contracted[.normal]?[.up], .input("きゃ"))
        let voiced = SumireFlickMapTransform.transform([.normal: root], label: "か", input: .voiced, rotation: .standard)
        XCTAssertNil(voiced[.normal]?[.up]); XCTAssertEqual(voiced[.normal]?[.left], .input("が"))
    }
    // Exact coordinates and expectations from pinned Android
    // TfbiDiagonalControllerTest.twoStep/threeStepRequiresPerpendicularTravelOnlyInStableMode.
    func testPinnedAndroidDiagonalEventTraces() {
        for sticky in [false, true] {
            for (stable, y, expected) in [(true, 68.0, "え"), (true, 75.0, "ぇ"), (false, 68.0, "ぇ")] {
                var configuration = MultiFlickConfiguration()
                configuration.threshold = 20; configuration.stableDiagonal = stable
                var engine = TwoStepFlickEvaluator(map: [.right: [.tap: "え", .right: "え", .downRight: "ぇ"]], sticky: sticky)
                engine.begin(at: .init(50, 50), configuration: configuration)
                engine.move(to: .init(75, 50)); engine.move(to: .init(125, y))
                XCTAssertEqual(engine.end(at: .init(125, y)), expected)
            }
        }
        for (stable, y, expected) in [(true, 69.0, "え"), (true, 72.0, "ぇ"), (false, 69.0, "ぇ")] {
            var configuration = MultiFlickConfiguration()
            configuration.threshold = 20; configuration.stableDiagonal = stable
            var engine = HierarchicalFlickEvaluator(maps: [.normal: [.tap: .input("あ"), .right: .submenu([.right: .input("え"), .downRight: .input("ぇ")])]])
            engine.begin(at: .init(50, 50), configuration: configuration)
            engine.move(to: .init(72, 50)); engine.move(to: .init(85, y))
            XCTAssertEqual(engine.end(), expected)
        }
    }
    func testTwoStepIntermediateOriginReturnAndRelease() {
        var engine = TwoStepFlickEvaluator(map: map)
        engine.begin(at: .init(0, 0), configuration: .init())
        engine.move(to: .init(-100, 0))
        XCTAssertEqual(engine.selectedText, "き")
        engine.move(to: .init(-140, -60))
        XCTAssertEqual(engine.end(at: .init(-140, -60)), "ぎ")
        XCTAssertNil(engine.end(at: .init(-140, -60)))
        engine.begin(at: .init(0, 0), configuration: .init())
        engine.move(to: .init(-100, 0)); engine.move(to: .init(-10, 0))
        XCTAssertFalse(engine.secondStage)
        XCTAssertEqual(engine.end(at: .init(0, 0)), "か")
    }
    func testStickyReturnRetainsSelectionAndCancelEmitsNothing() {
        var engine = TwoStepFlickEvaluator(map: map, sticky: true)
        engine.begin(at: .init(0, 0), configuration: .init())
        engine.move(to: .init(-100, 0)); engine.move(to: .init(-140, -60))
        engine.move(to: .init(-100, 0))
        XCTAssertEqual(engine.selectedText, "ぎ")
        XCTAssertEqual(engine.end(at: .init(-100, 0)), "ぎ")
        engine.begin(at: .init(0, 0), configuration: .init()); engine.cancel()
        XCTAssertNil(engine.end(at: .init(0, 0)))
    }
    func testLongPressAlternateAndUnconfiguredSector() {
        var engine = TwoStepFlickEvaluator(map: map, longPressMap: [.tap: [.tap: "が"]])
        engine.begin(at: .init(0, 0), configuration: .init()); engine.hold()
        XCTAssertEqual(engine.end(at: .init(0, 0)), "が")
        var single = SingleStageFlickEvaluator(style: .directionalLongPress, map: [.tap: "あ", .up: "う"], alternate: [.up: "ぅ"])
        single.begin(at: .init(0, 0), configuration: .init())
        single.move(to: .init(100, 0))
        XCTAssertNil(single.selected)
        XCTAssertNil(single.end(at: .init(100, 0)))
        single.begin(at: .init(0, 0), configuration: .init())
        single.move(to: .init(0, -100)); single.hold()
        XCTAssertEqual(single.end(at: .init(0, -100)), "ぅ")
    }
    func testStableDiagonalNeedsTurnDistance() {
        var config = MultiFlickConfiguration(); config.stableDiagonal = true
        XCTAssertEqual(config.guarded(.upRight, entry: .right, delta: .init(100, -13), enabled: [.right, .upRight]), .right)
        XCTAssertEqual(config.guarded(.upRight, entry: .right, delta: .init(100, -14), enabled: [.right, .upRight]), .upRight)
    }
    func testHierarchicalJitterGuardBackAndParentContinuation() {
        let child: HierarchicalFlickEvaluator.Map = [.left: .input("に"), .downLeft: .input("にゅ")]
        let root: HierarchicalFlickEvaluator.Map = [.tap: .input("な"), .left: .submenu(child, cancelOnTap: true, parentContinuations: [.up]), .up: .input("ぬ")]
        var engine = HierarchicalFlickEvaluator(maps: [.normal: root])
        engine.begin(at: .init(0, 0), configuration: .init()); engine.move(to: .init(-100, 0))
        XCTAssertEqual(engine.depth, 2); XCTAssertEqual(engine.selectedText, "に")
        engine.move(to: .init(0, 0)); XCTAssertEqual(engine.depth, 2)
        engine.move(to: .init(0, 0)); XCTAssertEqual(engine.depth, 1)
        XCTAssertEqual(engine.end(), "な")
        engine.begin(at: .init(0, 0), configuration: .init()); engine.move(to: .init(-100, 0)); engine.move(to: .init(0, -100))
        XCTAssertEqual(engine.depth, 1); XCTAssertEqual(engine.end(), "ぬ")
    }
    func testHierarchicalModeHotSwapAndReset() {
        let normal: HierarchicalFlickEvaluator.Map = [.tap: .input("か"), .up: .input("ぐ", triggers: .dakuten)]
        let voiced: HierarchicalFlickEvaluator.Map = [.tap: .input("が"), .up: .input("ぐ")]
        var engine = HierarchicalFlickEvaluator(maps: [.normal: normal, .dakuten: voiced])
        engine.begin(at: .init(0, 0), configuration: .init()); engine.move(to: .init(0, -100))
        XCTAssertEqual(engine.mode, .dakuten); XCTAssertEqual(engine.end(), "ぐ")
        XCTAssertEqual(engine.mode, .normal)
    }
    func testCircularCompactionMapSwitchAndExclusiveBoundaries() {
        let first: CircularFlickEvaluator.Map = [.tap: .text("あ"), .slot0: .text("う"), .slot1: .text("え"), .slot2: .text("お"), .slot3: .text("い"), .slot4: .text(""), .slot5: .mapSwitch]
        var engine = CircularFlickEvaluator(maps: [first, first.merging([.tap: .text("ぁ")]) { _, new in new }], directionCount: 7)
        XCTAssertEqual(engine.activeSlots, [.slot0, .slot1, .slot2, .slot3, .slot5])
        XCTAssertEqual(engine.effectiveRanges[.slot5]?.sweep, 72)
        engine.begin(at: .init(0, 0), configuration: .init())
        engine.move(to: .init(-95, -31))
        XCTAssertEqual(engine.mapIndex, 1)
        engine.move(to: .init(-95, -31)); XCTAssertEqual(engine.mapIndex, 1)
        engine.move(to: .init(0, 0)); XCTAssertEqual(engine.end(at: .init(0, 0)), .text("ぁ"))
        XCTAssertEqual(engine.mapIndex, 0)
        XCTAssertTrue(CircularFlickRange(start: 315, sweep: 90).contains(0))
        XCTAssertFalse(CircularFlickRange(start: 315, sweep: 90).contains(45))
    }
    func testPetalMovementCancelsHoldAndCenterGuideKeepsLastMove() {
        var petal = SingleStageFlickEvaluator(style: .petal, map: [.tap: "あ", .right: "え"], alternate: [.tap: "ぁ"])
        petal.begin(at: .init(0, 0), configuration: .init()); petal.move(to: .init(8, 0)); petal.hold()
        XCTAssertFalse(petal.longPress); XCTAssertEqual(petal.end(at: .init(0, 0)), "あ")
        var guide = SingleStageFlickEvaluator(style: .centerGuide, map: [.tap: "あ", .right: "え"])
        guide.begin(at: .init(0, 0), configuration: .init()); guide.move(to: .init(100, 0))
        XCTAssertEqual(guide.end(at: .init(0, 0)), "え")
    }
}
