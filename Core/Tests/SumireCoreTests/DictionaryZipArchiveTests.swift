import XCTest
@testable import SumireCore

final class DictionaryZipArchiveTests: XCTestCase {
    // Independently known CRC/raw-DEFLATE fixture for UTF-8 "hello".
    private func archive(name: String = "system/yomi.dat", method: UInt16 = 8,
                         descriptor: Bool = false, crc: UInt32 = 0x3610a686,
                         expanded: UInt32 = 5, external: UInt32 = 0, extraPayload: [UInt8] = []) -> Data {
        var d = Data()
        func u16(_ n: UInt16) { d.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8)]) }
        func u32(_ n: UInt32) { u16(UInt16(n & 65535)); u16(UInt16(n >> 16)) }
        let payload: [UInt8] = (method == 0 ? Array("hello".utf8) : [0xcb,0x48,0xcd,0xc9,0xc9,0x07,0x00]) + extraPayload
        let filename = Data(name.utf8), flags: UInt16 = descriptor ? 8 : 0
        u32(0x04034b50); u16(20); u16(flags); u16(method); u32(0)
        u32(descriptor ? 0 : crc); u32(descriptor ? 0 : UInt32(payload.count)); u32(descriptor ? 0 : expanded)
        u16(UInt16(filename.count)); u16(0); d.append(filename); d.append(contentsOf: payload)
        if descriptor { u32(0x08074b50); u32(crc); u32(UInt32(payload.count)); u32(expanded) }
        let central = d.count
        u32(0x02014b50); u16(0x0314); u16(20); u16(flags); u16(method); u32(0)
        u32(crc); u32(UInt32(payload.count)); u32(expanded); u16(UInt16(filename.count))
        u16(0); u16(0); u16(0); u16(0); u32(external); u32(0); d.append(filename)
        let length = d.count - central
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(UInt32(length)); u32(UInt32(central)); u16(0)
        return d
    }
    private func withDestination(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("staging.dat"))
    }
    func testStoredDeflateAndDataDescriptors() throws {
        for method: UInt16 in [0, 8] {
            for descriptor in [false, true] {
                let zip = try DictionaryZipArchive(data: archive(method: method, descriptor: descriptor))
                XCTAssertEqual(zip.entries.count, 1)
                XCTAssertEqual(zip.entries[0].name, "system/yomi.dat")
                try withDestination { target in
                    try zip.extract(zip.entries[0], to: target)
                    XCTAssertEqual(try Data(contentsOf: target), Data("hello".utf8))
                    XCTAssertThrowsError(try zip.extract(zip.entries[0], to: target))
                    XCTAssertEqual(try Data(contentsOf: target), Data("hello".utf8))
                }
            }
        }
    }
    func testDeflatedEmptyDirectoryIsAcceptedButNeverExtractedAsFile() throws {
        // Python zipfile ZIP_DEFLATED directory entry, compressed size 2.
        let data = Data(base64Encoded: "UEsDBBQAAAAIAHMnUl0AAAAAAgAAAAAAAAAHAAAAc3lzdGVtLwMAUEsBAhQDFAAAAAgAcydSXQAAAAACAAAAAAAAAAcAAAAAAAAAAAAQAP1BAAAAAHN5c3RlbS9QSwUGAAAAAAEAAQA1AAAAJwAAAAAA")!
        let zip = try DictionaryZipArchive(data: data)
        XCTAssertTrue(zip.entries[0].isDirectory)
        try withDestination { target in
            XCTAssertThrowsError(try zip.extract(zip.entries[0], to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        var corrupt = data; corrupt[37] = 0xff // First byte of the directory's raw DEFLATE stream.
        XCTAssertThrowsError(try DictionaryZipArchive(data: corrupt))
    }
    func testChecksumAndExpandedSizeFailureRemoveOnlyStagingFile() throws {
        for data in [archive(crc: 0), archive(expanded: 4), archive(expanded: 6)] {
            let zip = try DictionaryZipArchive(data: data)
            try withDestination { target in
                XCTAssertThrowsError(try zip.extract(zip.entries[0], to: target))
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
    }
    func testRejectsUnsafeNamesAndSymlinks() {
        for name in ["../yomi.dat", "/yomi.dat", "a/../yomi.dat", "a/./yomi.dat", "a//yomi.dat", "C:/yomi.dat", "a\\yomi.dat", "a\0yomi.dat"] {
            XCTAssertThrowsError(try DictionaryZipArchive(data: archive(name: name)), name)
        }
        XCTAssertThrowsError(try DictionaryZipArchive(data: archive(external: 0xa1ff0000)))
    }
    func testRejectsEveryTruncatedPrefixAndCapacityOverflow() throws {
        let valid = archive()
        for length in 0..<valid.count { XCTAssertThrowsError(try DictionaryZipArchive(data: valid.prefix(length))) }
        var limits = DictionaryZipArchive.Limits(); limits.entryBytes = 4
        XCTAssertThrowsError(try DictionaryZipArchive(data: valid, limits: limits))
        limits = .init(); limits.totalBytes = 4
        XCTAssertThrowsError(try DictionaryZipArchive(data: valid, limits: limits))
        limits = .init(); limits.entries = 0
        XCTAssertThrowsError(try DictionaryZipArchive(data: valid, limits: limits))
        var bad = valid; bad[valid.count - 6] = 0xff
        XCTAssertThrowsError(try DictionaryZipArchive(data: bad))
    }
    func testDoesNotFollowOrRemoveExistingDestinationSymlink() throws {
        let zip = try DictionaryZipArchive(data: archive())
        try withDestination { target in
            let original = target.deletingLastPathComponent().appendingPathComponent("original")
            try Data("keep".utf8).write(to: original)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            XCTAssertThrowsError(try zip.extract(zip.entries[0], to: target))
            XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), original.path)
        }
    }
    func testRejectsEncryptionUnsupportedCompressionHeaderMismatchAndDuplicateEntries() throws {
        let valid = archive(), central = valid.count - 22 - 46 - "system/yomi.dat".utf8.count
        for (offset, value): (Int, UInt8) in [(central + 8, 1), (central + 10, 99), (6, 1), (14, 0)] {
            var bad = valid; bad[offset] = value
            XCTAssertThrowsError(try DictionaryZipArchive(data: bad))
        }
        let record = valid.subdata(in: central..<valid.count - 22)
        var duplicate = valid.prefix(valid.count - 22); duplicate.append(record)
        var end = valid.suffix(22); end[end.startIndex + 8] = 2; end[end.startIndex + 10] = 2
        let size = UInt32(record.count * 2)
        for i in 0..<4 { end[end.startIndex + 12 + i] = UInt8((size >> (8 * i)) & 255) }
        duplicate.append(end)
        XCTAssertThrowsError(try DictionaryZipArchive(data: duplicate))
    }
    func testRejectsTrailingCompressedBytesWithoutPublishingFile() throws {
        let zip = try DictionaryZipArchive(data: archive(extraPayload: [0, 1, 2]))
        try withDestination { target in
            XCTAssertThrowsError(try zip.extract(zip.entries[0], to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }
    func testReferenceAssetArchivesWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_ASSETS"] else {
            throw XCTSkip("Set SUMIRE_REFERENCE_ASSETS for the pinned distribution's real ZIP containers")
        }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
        var count = 0
        for case let url as URL in files where url.pathExtension == "zip" {
            let zip = try DictionaryZipArchive(url: url)
            for entry in zip.entries where !entry.isDirectory {
                try withDestination { target in
                    try zip.extract(entry, to: target)
                    XCTAssertEqual(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, entry.uncompressedBytes)
                }
            }
            count += 1
        }
        XCTAssertGreaterThan(count, 90)
        print("Verified \(count) reference ZIP containers")
    }
}
