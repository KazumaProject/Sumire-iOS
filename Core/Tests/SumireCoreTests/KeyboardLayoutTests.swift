import XCTest
@testable import SumireCore

final class KeyboardLayoutTests: XCTestCase {
    func testSumireModeSpecificMappingsAndAllNineGrids() throws {
        for arrangement in SumireKeyArrangement.allCases {
            for mode in TenKeyMode.allCases {
                let layout = arrangement.layout(mode: mode)
                try layout.validate()
                XCTAssertEqual(layout.keys.reduce(0) { $0 + $1.rowSpan * $1.columnSpan }, 20)
            }
        }
        XCTAssertEqual(SumireInput.outputs(.english, arrangement: .toggle, index: 0), ["@", "#", "/", "_", "1"])
        XCTAssertEqual(SumireInput.outputs(.number, arrangement: .flick, index: 4)[2], "x")
        XCTAssertEqual(SumireInput.outputs(.number, arrangement: .toggle, index: 10)[3], "√")
        XCTAssertEqual(SumireInput.outputs(.number, arrangement: .cursor, index: 9), ["@", "/", "~", ";", ""])
        XCTAssertEqual(SumireKeyArrangement.cursor.layout(mode: .number).keys.first { $0.id == "colon_key" }?.label, ":")
    }
    func testSumireArrangementsHaveCompleteNonOverlappingGrids() throws {
        for arrangement in SumireKeyArrangement.allCases {
            let layout = arrangement.kanaLayout
            try layout.validate()
            XCTAssertEqual(layout.keys.reduce(0) { $0 + $1.rowSpan * $1.columnSpan }, 20)
            XCTAssertEqual(layout.keys.filter { $0.action == .nextKeyboard }.count, 1)
            XCTAssertEqual(layout.keys.first { $0.id == "a" }?.column, 1)
        }
        XCTAssertEqual(SumireKeyArrangement.flick.kanaLayout.keys.first { $0.id == "cursor_right_key" }?.row, 2)
        XCTAssertEqual(SumireKeyArrangement.cursor.kanaLayout.keys.first { $0.id == "cursor_right_key" }?.row, 1)
        XCTAssertEqual(SumireKeyArrangement.toggle.kanaLayout.keys.first { $0.id == "enter_key" }?.rowSpan, 2)
    }
    func testSpanningKeysRejectOverlapAndOverflow() throws {
        let enter = KeyboardLayout.Key(id: "enter", label: "改行", row: 2, column: 4, rowSpan: 2, action: .enter)
        let occupied = KeyboardLayout.Key(id: "overlap", label: "x", row: 3, column: 4, action: .text)
        XCTAssertThrowsError(try KeyboardLayout(rows: 4, columns: 5, keys: [enter, occupied]).validate()) {
            XCTAssertEqual($0 as? KeyboardLayout.ValidationError, .overlap("enter", "overlap"))
        }
        let overflow = KeyboardLayout.Key(id: "overflow", label: "", row: Int.max, column: 0, rowSpan: Int.max, action: .text)
        XCTAssertThrowsError(try KeyboardLayout(rows: 4, columns: 5, keys: [overflow]).validate())
        XCTAssertThrowsError(try KeyboardLayout(rows: 4, columns: 5, keys: [enter, enter]).validate())
        try KeyboardLayout.sumireKana.validate()
        let encoded = try JSONEncoder().encode(KeyboardLayout.sumireKana)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardLayout.self, from: encoded), .sumireKana)
    }
}
