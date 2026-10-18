import XCTest
@testable import SumireCore

final class ReferenceFlickMapsTests: XCTestCase {
    func testBundledKanaGestureExamples() throws {
        var config = MultiFlickConfiguration(); config.threshold = 28; config.centerReturnRadius = 70 / 2.625
        let twoProfile = try ReferenceFlickMaps(arrangement: .toggle, mode: .japanese, style: .twoStep)
        let twoKey = try XCTUnwrap(twoProfile.keys.first { $0.label == "か" })
        guard case .twoStep(let map, let alternate, let sticky) = try twoProfile.definition(for: twoKey) else { return XCTFail() }
        var two = TwoStepFlickEvaluator(map: map, longPressMap: alternate, sticky: sticky)
        two.begin(at: .init(0, 0), configuration: config); two.move(to: .init(-40, 0))
        XCTAssertEqual(two.end(at: .init(-60, 0)), "き")
        two.begin(at: .init(0, 0), configuration: config); two.move(to: .init(-40, 0)); two.move(to: .init(-90, 35))
        XCTAssertEqual(two.end(at: .init(-90, 35)), "ぎ")
        two.begin(at: .init(0, 0), configuration: config); two.move(to: .init(-40, 0)); two.move(to: .init(0, 0))
        XCTAssertEqual(two.end(at: .init(0, 0)), "か")
        let profile = try ReferenceFlickMaps(arrangement: .toggle, mode: .japanese, style: .threeStep)
        let key = try XCTUnwrap(profile.keys.first { $0.label == "か" })
        guard case .hierarchical(let maps, let orders) = try profile.definition(for: key) else { return XCTFail() }
        var three = HierarchicalFlickEvaluator(maps: maps, directionOrders: orders)
        three.begin(at: .init(0, 0), configuration: config); three.move(to: .init(-40, 0)); three.move(to: .init(0, -60)); three.move(to: .init(-60, -100))
        XCTAssertEqual(three.end(), "きゅう")
    }
    func testCircularPostProcessingAndMapSwitch() throws {
        let profile = try ReferenceFlickMaps(arrangement: .toggle, mode: .japanese, style: .donut)
        let key = try XCTUnwrap(profile.keys.first { $0.label == "か" })
        let settings = [CircularSlotSetting(mode: 0, keyIdentifier: "か", slot: 4, action: .switchMap)]
        guard case .circular(let maps) = try profile.definition(for: key, slotSettings: settings) else { return XCTFail("circular") }
        XCTAssertTrue(maps.allSatisfy { $0[.slot4] == .mapSwitch })
        var evaluator = CircularFlickEvaluator(maps: maps, directionCount: 5)
        evaluator.begin(at: .init(0, 0), configuration: .init())
        let range = try XCTUnwrap(evaluator.effectiveRanges[.slot4])
        let angle = (range.start + range.sweep / 2) * Double.pi / 180
        evaluator.move(to: .init(cos(angle) * 100, sin(angle) * 100))
        XCTAssertEqual(evaluator.mapIndex, 1)
        evaluator.move(to: .init(0, 0))
        XCTAssertEqual(evaluator.end(at: .init(0, 0)), .text("が"))
        let raw: [CircularFlickEvaluator.Map] = [[.tap:.text("あ"),.slot4:.text("old")]]
        XCTAssertNil(CircularSlotSetting.apply(raw, settings: [], mode: 0, keyIdentifier: "あ", isSpecialKey: false)[0][.slot4])
        XCTAssertEqual(CircularSlotSetting.apply(raw, settings: [], mode: 0, keyIdentifier: "あ", isSpecialKey: true), raw)
    }
    func testPinnedKanaMapsAndRotationOrders() throws {
        let two = try ReferenceFlickMaps(arrangement: .toggle, mode: .japanese, style: .twoStep)
        let key = try XCTUnwrap(two.keys.first { $0.label == "か" })
        guard case .twoStep(let map, _, _) = try two.definition(for: key) else { return XCTFail("two step") }
        XCTAssertEqual(map[.left]?[.left], "き")
        XCTAssertEqual(map[.left]?[.downLeft], "ぎ")
        let three = try ReferenceFlickMaps(arrangement: .toggle, mode: .japanese, style: .threeStep)
        let threeKey = try XCTUnwrap(three.keys.first { $0.label == "か" })
        var settings = FlickStyleSettings()
        settings.rotation = .clockwise
        guard case .hierarchical(let maps, let orders) = try three.definition(for: threeKey, settings: settings),
              case .submenu(let left, _, _, _) = maps[.normal]?[.left],
              case .input(let text, _, _) = left[.upLeft] else { return XCTFail("rotated hierarchy") }
        XCTAssertEqual(text, "ぎ")
        XCTAssertEqual(orders["normal/LEFT"]?.prefix(2), [.left, .upLeft])
        XCTAssertEqual(Set(orders["normal/LEFT"] ?? []), Set(left.keys))
    }
    func testEnglishTwoStepKeepsActualPetalKeyType() throws {
        let maps = try ReferenceFlickMaps(arrangement: .toggle, mode: .english, style: .twoStep)
        let key = try XCTUnwrap(maps.keys.first { $0.label == "ABC" })
        XCTAssertEqual(key.keyType, "PETAL_FLICK")
        guard case .single(.petal, let values, _) = try maps.definition(for: key) else { return XCTFail("petal") }
        XCTAssertEqual(values[.tap], "a")
    }
    func testEveryPinnedProfileAndKeyLoadsWithoutFallback() throws {
        var profiles = 0
        var definitions = 0
        for arrangement in SumireKeyArrangement.allCases {
            for mode in [TenKeyMode.japanese, .english, .number] {
                for style in SumireFlickStyle.allCases {
                    let maps = try ReferenceFlickMaps(arrangement: arrangement, mode: mode, style: style)
                    XCTAssertEqual(maps.sourceRevision, "9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93")
                    XCTAssertLessThanOrEqual(maps.payloadBytes, 256 * 1024)
                    XCTAssertFalse(maps.keys.isEmpty)
                    for key in maps.keys {
                        do {
                            let definition = try maps.definition(for: key)
                            if ["NORMAL", "CROSS_FLICK"].contains(key.keyType) { XCTAssertNil(definition) }
                            else { XCTAssertNotNil(definition); definitions += 1 }
                        } catch { XCTFail("\(arrangement)/\(mode)/\(style)/\(key.label): \(error)") }
                    }
                    profiles += 1
                }
            }
        }
        XCTAssertEqual(profiles, 54)
        XCTAssertGreaterThan(definitions, 500)
    }
}
