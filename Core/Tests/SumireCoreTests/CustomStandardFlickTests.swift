import XCTest
@testable import SumireCore

final class CustomStandardFlickTests: XCTestCase {
    func testReferenceDirectionsFallbackAndExplicitFarPrecedence() throws {
        let source = #"{"layout":{"rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"label":"あ","keyType":"STANDARD_FLICK"},"flicks":[{"flickDirection":"TAP","actionValue":"あ"},{"flickDirection":"UP_LEFT","actionValue":"近"},{"flickDirection":"UP_LEFT_FAR","actionValue":"い"},{"flickDirection":"UP","actionValue":"う"},{"flickDirection":"UP_RIGHT","actionValue":"え"},{"flickDirection":"DOWN","actionValue":"お"},{"stateIndex":1,"flickDirection":"TAP","actionValue":"別"}]}]}"#
        let key = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(source.utf8)).layouts.first?.placements.first)
        XCTAssertEqual(try CustomStandardFlick(placement: key).values, ["あ", "い", "う", "え", "お"])
        XCTAssertEqual(CustomStandardFlick.direction(dx: 0, dy: 0), .tap)
        XCTAssertEqual(CustomStandardFlick.direction(dx: 30, dy: 0), .right)
        XCTAssertEqual(CustomStandardFlick.direction(dx: -30, dy: 0), .left)
        XCTAssertEqual(CustomStandardFlick.direction(dx: 0, dy: -30), .up)
        XCTAssertEqual(CustomStandardFlick.direction(dx: 0, dy: 30), .down)
        XCTAssertEqual(CustomStandardFlick.direction(dx: 30, dy: 30), .right)
        XCTAssertEqual(CustomStandardFlick.direction(dx: 30, dy: -30), .left)
        XCTAssertEqual(CustomStandardFlick.direction(dx: -30, dy: -30), .up)
        XCTAssertEqual(CustomStandardFlick.direction(dx: -30, dy: 30), .down)
        let laterState = source.replacingOccurrences(of: "\"stateIndex\":1", with: "\"stateIndex\":-1")
        let first = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(laterState.utf8)).layouts.first?.placements.first)
        XCTAssertEqual(try CustomStandardFlick(placement: first).values, ["別", "", "", "", ""])
        let invalid = source.replacingOccurrences(of: "\"actionValue\":\"あ\"", with: "\"actionType\":\"PASTE\",\"actionValue\":\"あ\"")
        let unsupported = try XCTUnwrap(CustomLayoutImportPreview.parse(Data(invalid.utf8)).layouts.first?.placements.first)
        XCTAssertThrowsError(try CustomStandardFlick(placement: unsupported))
    }
}
