import XCTest
import CryptoKit
@testable import SumireCore

final class DictionarySourceArchiveConverterTests: XCTestCase {
    private enum Kind {
        case shorts, ints, longs, characters
        var name: String { switch self { case .shorts: "[S"; case .ints: "[I"; case .longs: "[J"; case .characters: "[C" } }
        var uid: UInt64 {
            switch self {
            case .shorts: 0xef832e06e55db0fa
            case .ints: 0x4dba602676eab2a5
            case .longs: 0x782004b512b17593
            case .characters: 0xb02666b0e25d84ac
            }
        }
        var width: Int { switch self { case .shorts, .characters: 2; case .ints: 4; case .longs: 8 } }
    }
    private struct ArrayValue { let kind: Kind; let values: [UInt64] }

    private func appendBE(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    private func appendLE(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    private func javaStream(_ arrays: [ArrayValue]) -> Data {
        var data = Data([0xac, 0xed, 0, 5])
        for array in arrays {
            data.append(contentsOf: [0x75, 0x72])
            appendBE(UInt64(array.kind.name.utf8.count), width: 2, to: &data)
            data.append(contentsOf: array.kind.name.utf8)
            appendBE(array.kind.uid, width: 8, to: &data)
            data.append(contentsOf: [2, 0, 0, 0x78, 0x70])
            appendBE(UInt64(array.values.count), width: 4, to: &data)
            for value in array.values { appendBE(value, width: array.kind.width, to: &data) }
        }
        return data
    }
    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~value
    }
    private func storedZIP(_ files: [(String, Data)]) -> Data {
        struct Central { let name: Data; let crc, size, offset: UInt32 }
        var data = Data(), central: [Central] = []
        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32, to data: inout Data) {
            append16(UInt16(truncatingIfNeeded: value), to: &data)
            append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        }
        for (name, payload) in files {
            let nameData = Data(name.utf8), size = UInt32(payload.count), checksum = crc32(payload)
            let offset = UInt32(data.count)
            append32(0x0403_4b50, to: &data); append16(20, to: &data); append16(0, to: &data)
            append16(0, to: &data); append16(0, to: &data); append16(0, to: &data)
            append32(checksum, to: &data); append32(size, to: &data); append32(size, to: &data)
            append16(UInt16(nameData.count), to: &data); append16(0, to: &data)
            data.append(nameData); data.append(payload)
            central.append(Central(name: nameData, crc: checksum, size: size, offset: offset))
        }
        let centralOffset = UInt32(data.count)
        for entry in central {
            append32(0x0201_4b50, to: &data); append16(20, to: &data); append16(20, to: &data)
            append16(0, to: &data); append16(0, to: &data); append16(0, to: &data); append16(0, to: &data)
            append32(entry.crc, to: &data); append32(entry.size, to: &data); append32(entry.size, to: &data)
            append16(UInt16(entry.name.count), to: &data); append16(0, to: &data); append16(0, to: &data)
            append16(0, to: &data); append16(0, to: &data); append32(0, to: &data); append32(entry.offset, to: &data)
            data.append(entry.name)
        }
        let centralSize = UInt32(data.count) - centralOffset
        append32(0x0605_4b50, to: &data); append16(0, to: &data); append16(0, to: &data)
        append16(UInt16(central.count), to: &data); append16(UInt16(central.count), to: &data)
        append32(centralSize, to: &data); append32(centralOffset, to: &data); append16(0, to: &data)
        return data
    }

    private func sourceFiles(includeMacMetadata: Bool = true, ambiguousInnerZIP: Bool = false,
                             corruptSystemTokens: Bool = false) -> [(String, Data)] {
        let reading = javaStream([
            .init(kind: .longs, values: [0b101]), .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x3042]), .init(kind: .ints, values: [1])
        ])
        let surface = javaStream([
            .init(kind: .longs, values: [0b101]), .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x611])
        ])
        let tokens = javaStream([
            .init(kind: .shorts, values: [0]), .init(kind: .shorts, values: [100]),
            .init(kind: .ints, values: [2]), .init(kind: .longs, values: [0b10])
        ])
        let pos = javaStream([
            .init(kind: .shorts, values: [0]), .init(kind: .shorts, values: [1])
        ])
        var matrix = Data()
        for value: UInt16 in [0, 1, 2, 3] { appendBE(UInt64(value), width: 2, to: &matrix) }

        func inner(_ name: String, _ data: Data, ambiguous: Bool = false) -> Data {
            var entries = [(name, data)]
            if includeMacMetadata { entries.append(("__MACOSX/._\(name)", Data([1, 2, 3]))) }
            if ambiguous { entries.append(("unexpected.bin", Data([9]))) }
            return storedZIP(entries)
        }
        return [
            ("connectionId.dat.zip", inner("connectionId.dat", matrix)),
            ("pos_table.dat", pos),
            ("system/yomi.dat.zip", inner("yomi.dat", reading)),
            ("system/tango.dat.zip", inner("tango.dat", surface)),
            ("system/token.dat.zip", inner("token.dat", corruptSystemTokens ? Data([0]) : tokens,
                                               ambiguous: ambiguousInnerZIP))
        ]
    }

    func testConvertsNestedAndroidArchivesAndReportsMetadataAndUnknownEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("dictionary.zip")
        try storedZIP(sourceFiles() + [("readme.txt", Data("notice".utf8))]).write(to: archiveURL)
        let output = root.appendingPathComponent("converted", isDirectory: true)

        let report = try DictionarySourceArchiveConverter.convert(archiveAt: archiveURL, into: output)

        XCTAssertEqual(report.convertedFiles, ["connection.sud", "system.sud"])
        XCTAssertTrue(report.skippedGroups.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.contains("readme.txt") })
        XCTAssertTrue(report.diagnostics.contains { $0.contains("__MACOSX") })
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(names, ["connection.sud", "system.sud"])
        for name in names {
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            XCTAssertEqual(String(data: data.prefix(8), encoding: .ascii), "SUMIRE01")
        }
    }

    func testRejectsAmbiguousNestedZIPAndRemovesPartialOutput() throws {
        for files in [sourceFiles(ambiguousInnerZIP: true), sourceFiles(corruptSystemTokens: true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let archiveURL = root.appendingPathComponent("dictionary.zip")
            try storedZIP(files).write(to: archiveURL)
            let output = root.appendingPathComponent("converted", isDirectory: true)

            XCTAssertThrowsError(try DictionarySourceArchiveConverter.convert(archiveAt: archiveURL, into: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testJapaneseGroupsWithoutCommonPOSAndConnectionAreNotConverted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("dictionary.zip")
        try storedZIP(Array(sourceFiles().dropFirst(2))).write(to: archiveURL)
        let output = root.appendingPathComponent("converted", isDirectory: true)

        XCTAssertThrowsError(try DictionarySourceArchiveConverter.convert(archiveAt: archiveURL, into: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRealSourceArchiveWhenConfigured() throws {
        struct Manifest: Decodable {
            let sourceRevision: String
            let outputSHA256: [String: String]
            enum CodingKeys: String, CodingKey {
                case sourceRevision = "source_revision"
                case outputSHA256 = "output_sha256"
            }
        }
        guard let archivePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_SOURCE_ZIP"],
              let nativePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_NATIVE_DICTIONARIES"] else {
            throw XCTSkip("Set SUMIRE_REFERENCE_SOURCE_ZIP and SUMIRE_REFERENCE_NATIVE_DICTIONARIES for an end-to-end source ZIP check")
        }
        let manifestURL = URL(fileURLWithPath: nativePath, isDirectory: true).appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.sourceRevision, "df1f38315bf56d860d32919a3eaed6a75499e91e")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("converted", isDirectory: true)

        let report = try DictionarySourceArchiveConverter.convert(
            archiveAt: URL(fileURLWithPath: archivePath), into: output
        )

        XCTAssertEqual(report.convertedFiles.count, 34)
        XCTAssertTrue(report.skippedGroups.isEmpty)
        for name in report.convertedFiles {
            let data = try Data(contentsOf: output.appendingPathComponent(name), options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, manifest.outputSHA256[name], "Native binary differs for \(name)")
        }
        print("Converted real Android source ZIP to all 34 pinned native files byte-for-byte")
    }
}
