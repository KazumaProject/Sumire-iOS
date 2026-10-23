import XCTest
@testable import SumireCore

final class KeyboardToolbarDateOptionsTests: XCTestCase {
    func testDateOptionsMatchAndroidShortcutFormats() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-29T12:00:00Z"))
        let values = KeyboardToolbarDateOptions.strings(
            for: date,
            locale: Locale(identifier: "ja_JP"),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )

        XCTAssertEqual(values, [
            "2/29",
            "2024/02/29",
            "2月29日(木)",
            "令和6年2月29日",
            "R6/02/29",
            "木曜日"
        ])
    }

    func testDateOptionsUseTheSuppliedTimeZoneForDayAndWeekday() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-01T00:30:00Z"))
        let values = KeyboardToolbarDateOptions.strings(
            for: date,
            locale: Locale(identifier: "ja_JP"),
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        )

        XCTAssertEqual(values[0], "2/29")
        XCTAssertEqual(values[1], "2024/02/29")
        XCTAssertEqual(values[2], "2月29日(木)")
        XCTAssertEqual(values[3], "令和6年2月29日")
        XCTAssertEqual(values[4], "R6/02/29")
        XCTAssertEqual(values[5], "木曜日")
    }
}
