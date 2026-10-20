import XCTest
@testable import SumireCore

final class CustomNumberLayoutTests: XCTestCase {
    func testPinnedFourByFourPositionsAndSpecialColumn() throws {
        let layout = try CustomNumberLayout.layout()
        XCTAssertEqual(layout.rows, 4); XCTAssertEqual(layout.columns, 4)
        XCTAssertEqual(layout.placements.count, 16)
        let cells = [["1", "2", "3", "globe"], ["4", "5", "6", "space"],
                     ["7", "8", "9", "delete"], ["comma", "0", "dot", "enter"]]
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() {
                let key = try XCTUnwrap(layout.placements.first { $0.id == "number-" + value })
                XCTAssertEqual(key.row, row * 2); XCTAssertEqual(key.column, column * 2)
                XCTAssertEqual(key.width, 2); XCTAssertEqual(key.height, 2)
                XCTAssertEqual(key.source["key"]?["isSpecialKey"], .bool(column == 3))
            }
        }
        let commands = ["globe": "SwitchToNextIme", "space": "Space", "delete": "Delete", "enter": "NewLine"]
        for (id, action) in commands {
            let key = try XCTUnwrap(layout.placements.first { $0.id == "number-" + id })
            XCTAssertEqual(key.source["key"]?["action"], .string(action))
            XCTAssertNotNil(key.source["key"]?["drawableResourceName"]?.string)
        }
        XCTAssertFalse(layout.placements.contains { $0.source["key"]?["action"] == .string("ChangeInputMode") })
    }
    func testDigitAndPunctuationRuntimeActionsMatchReference() throws {
        let layout = try CustomNumberLayout.layout(), targets = CustomLayoutTargets(layouts: [])
        for digit in 0...9 {
            let key = try XCTUnwrap(layout.placements.first { $0.id == "number-\(digit)" })
            let runtime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(for: key, targets: targets))
            XCTAssertEqual(runtime.actions, [.tap: .text(String(digit))])
        }
        for (id, values) in [("comma", [",", "+", "-", "*", "/"]), ("dot", [".", "(", "%", ")", "="])] {
            let key = try XCTUnwrap(layout.placements.first { $0.id == "number-" + id })
            let runtime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(for: key, targets: targets))
            XCTAssertEqual(runtime.actions, Dictionary(uniqueKeysWithValues: zip(
                [MultiFlickDirection.tap, .left, .up, .right, .down], values).map { ($0.0, CustomKeyAction.text($0.1)) }))
            XCTAssertEqual(key.source["flicks"]?.array?.map { $0["flickDirection"]?.string },
                           ["TAP", "UP_LEFT_FAR", "UP", "UP_RIGHT_FAR", "DOWN"])
        }
        let deletion = try XCTUnwrap(layout.placements.first { $0.id == "number-delete" })
        XCTAssertEqual(deletion.source["key"]?["keyType"], .string("CROSS_FLICK"))
        let runtime = try XCTUnwrap(CustomMultiStageFlick.runtimeDefinition(for: deletion, targets: targets))
        XCTAssertEqual(runtime.actions, [.tap: .command(.delete), .left: .command(.deleteUntilBoundary)])
        XCTAssertTrue(CustomLayoutActionReview(layouts: [layout]).unsupported.isEmpty)
    }
    func testStableIdentityAndLibraryRoundTripPreserveMappings() throws {
        let first = try CustomNumberLayout.layout(), second = try CustomNumberLayout.layout()
        XCTAssertEqual(first.id, second.id)
        var library = CustomKeyboardLibrary(); try library.append([first])
        let restored = try JSONDecoder().decode(CustomKeyboardLibrary.self, from: JSONEncoder().encode(library))
        let layout = try XCTUnwrap(restored.layouts().first)
        XCTAssertEqual(layout.id, first.id)
        XCTAssertEqual(layout.placements.map(\.source), first.placements.map(\.source))
    }
}
