import XCTest
@testable import SumireCore

final class ReferenceFlickMapsTests: XCTestCase {
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
