import Foundation
import XCTest
@testable import SumireCore

final class SumireDictionaryBinaryWriterTests: XCTestCase {
    private func readLE(_ bytes: Data, at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { value, index in
            value | UInt64(bytes[offset + index]) << (index * 8)
        }
    }

    func testWritesAlignedStandaloneContainerWithExpectedCRCAndExactEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("standalone.sud")

        try SumireDictionaryBinaryWriter.write(kind: .standalone,
            sections: [Data("123456789".utf8), Data()], to: output)

        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(String(data: bytes.prefix(8), encoding: .ascii), "SUMIRE01")
        XCTAssertEqual(readLE(bytes, at: 8, width: 4), 1)
        XCTAssertEqual(readLE(bytes, at: 12, width: 4), 3)
        XCTAssertEqual(readLE(bytes, at: 16, width: 4), 2)
        XCTAssertEqual(readLE(bytes, at: 20, width: 4), 0)

        let firstOffset = Int(readLE(bytes, at: 24, width: 8))
        let firstLength = Int(readLE(bytes, at: 32, width: 8))
        XCTAssertEqual(firstOffset, 72)
        XCTAssertEqual(firstOffset % 8, 0)
        XCTAssertEqual(firstLength, 9)
        XCTAssertEqual(readLE(bytes, at: 40, width: 4), 0xcbf4_3926)
        XCTAssertEqual(Data(bytes[firstOffset..<(firstOffset + firstLength)]), Data("123456789".utf8))

        let secondDescriptor = 24 + 24
        let secondOffset = Int(readLE(bytes, at: secondDescriptor, width: 8))
        XCTAssertEqual(secondOffset, 88)
        XCTAssertEqual(secondOffset % 8, 0)
        XCTAssertEqual(readLE(bytes, at: secondDescriptor + 8, width: 8), 0)
        XCTAssertEqual(readLE(bytes, at: secondDescriptor + 16, width: 4), 0)
        XCTAssertEqual(bytes.count, secondOffset)
    }

    func testRejectsWrongSectionCountBeforeCreatingDestination() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SumireDictionaryBinaryWriter.write(kind: .standalone, sections: [Data()], to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExclusiveCreateFailurePreservesExistingDestination() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("keep existing dictionary".utf8)
        try original.write(to: output)
        XCTAssertThrowsError(try SumireDictionaryBinaryWriter.write(kind: .standalone,
            sections: [Data(), Data()], to: output))
        XCTAssertEqual(try Data(contentsOf: output), original)
        try FileManager.default.removeItem(at: output)
    }
}
