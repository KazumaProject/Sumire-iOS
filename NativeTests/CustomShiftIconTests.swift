import XCTest
import UIKit
@testable import Sumire

@MainActor
final class CustomShiftIconTests: XCTestCase {
    func testShiftStatesHaveDistinctTemplateImages() throws {
        let icons: [KeyboardIcon] = [.shift, .shiftActive, .capsLock, .capsLockOutline]
        let images = try icons.map { icon -> Data in
            XCTAssertEqual(icon.image.size, CGSize(width: 24, height: 24))
            XCTAssertEqual(icon.image.renderingMode, .alwaysTemplate)
            return try XCTUnwrap(icon.image.pngData())
        }
        XCTAssertEqual(Set(images).count, icons.count)
    }
}
