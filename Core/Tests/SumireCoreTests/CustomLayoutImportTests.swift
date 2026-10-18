import XCTest
@testable import SumireCore

final class CustomLayoutImportTests: XCTestCase {
    private let layout = #"{"layout":{"layoutId":9007199254740993,"stableId":"layout-a","name":"配列","rowCount":1,"columnCount":2},"keysWithFlicks":[{"key":{"keyIdentifier":"a","row":0,"column":0,"label":"あ","action":"Text:あ","doubleTapAction":"LaunchApp:example","rowUnits":0,"columnUnits":0,"rowSpanUnits":2,"columnSpanUnits":1},"flicks":[{"stateIndex":0,"flickDirection":"UP_LEFT_FAR","actionType":"INPUT_TEXT","actionValue":"い"}],"longPressFlicks":[{"flickDirection":"UP","output":"う"}]}],"spacers":[{"itemIdentifier":"gap","rowUnits":0,"columnUnits":1,"rowSpanUnits":2,"columnSpanUnits":1}],"futureField":{"nested":[true,null,1.25]}}"#
    func testLegacyAndVersionsPreserveActionsAndIntegerIDs() throws {
        for version in 0...4 {
            let json = version == 0 ? "[\(layout)]" : "{\"schemaVersion\":\(version),\"layouts\":[\(layout)]}"
            let preview = try CustomLayoutImportPreview.parse(Data(json.utf8))
            XCTAssertTrue(preview.errors.isEmpty)
            XCTAssertEqual(preview.schemaVersion, version)
            let imported = try XCTUnwrap(preview.layouts.first)
            XCTAssertEqual(imported.originalLayoutID, 9007199254740993)
            XCTAssertEqual(imported.placements.count, 2)
            XCTAssertEqual(imported.placements[0].width, 1)
            XCTAssertTrue(imported.placements[1].isSpacer)
            let raw = try JSONDecoder().decode(LayoutJSON.self, from: Data(layout.utf8))
            XCTAssertEqual(imported.source, raw)
            XCTAssertEqual(try JSONDecoder().decode(LayoutJSON.self, from: JSONEncoder().encode(imported.source)), raw)
        }
        XCTAssertEqual(try CustomLayoutImportPreview.parse(Data(layout.utf8)).layouts.count, 1)
        XCTAssertEqual(try CustomLayoutImportPreview.parse(Data("{\"layouts\":[\(layout)]}".utf8)).layouts.count, 1)
    }
    func testInvalidLayoutDoesNotPreventValidLayoutAndUnknownVersionRejects() throws {
        let invalid = layout.replacingOccurrences(of: "\"columnUnits\":1", with: "\"columnUnits\":0")
        let preview = try CustomLayoutImportPreview.parse(Data("[\(invalid),\(layout)]".utf8))
        XCTAssertEqual(preview.layouts.count, 1)
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertTrue(preview.errors[0].hasPrefix("1件目:"))
        let duplicate = try CustomLayoutImportPreview.parse(Data("[\(layout),\(layout)]".utf8))
        XCTAssertEqual(duplicate.layouts.count, 1)
        XCTAssertEqual(duplicate.errors.count, 1)
        XCTAssertThrowsError(try CustomLayoutImportPreview.parse(Data("{\"schemaVersion\":5,\"layouts\":[\(layout)]}".utf8)))
        XCTAssertThrowsError(try CustomLayoutImportPreview.parse(Data("{\"schemaVersion\":true,\"layouts\":[\(layout)]}".utf8)))
    }
    func testHalfCellDimensionsAreDerivedAndSpacerDefaultsMatchReference() throws {
        let json = #"{"layout":{"name":"半マス"},"keysWithFlicks":[],"spacers":[{"rowUnits":2,"columnUnits":2}]}"#
        let preview = try CustomLayoutImportPreview.parse(Data(json.utf8))
        let item = try XCTUnwrap(preview.layouts.first)
        XCTAssertEqual(item.rows, 2)
        XCTAssertEqual(item.columns, 2)
        XCTAssertEqual(item.placements[0].width, 1)
        XCTAssertEqual(item.placements[0].height, 1)
        XCTAssertEqual(preview.warnings.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ImportedCustomLayout.self, from: JSONEncoder().encode(item)), item)
    }
}
