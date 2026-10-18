import XCTest
@testable import SumireCore

final class DictionaryJavaArraysTests: XCTestCase {
    // Produced independently by Java ObjectOutputStream: short[], int[], long[],
    // char[], BitSet, then references to the same short[] and BitSet objects.
    private let fixture = Data(base64Encoded: "rO0ABXVyAAJbU++DLgblXbD6AgAAeHAAAAAE//8AAH//gAB1cgACW0lNumAmduqypQIAAHhwAAAAA/////9/////gAAAAHVyAAJbSnggBLUSsXWTAgAAeHAAAAAD//////////9//////////4AAAAAAAAAAdXIAAltDsCZmsOJdhKwCAAB4cAAAAAMwQv//AABzcgAQamF2YS51dGlsLkJpdFNldG79iH45NKshAwABWwAEYml0c3QAAltKeHB1cQB+AAQAAAACgAAAAAAAAAEAAAAAAAAAAXhxAH4AAXEAfgAK")!
    private let kinds: [DictionaryPrimitiveKind] = [.shorts,.ints,.longs,.characters,.longs,.shorts,.longs]
    func testPrimitiveWidthsSignedValuesCharactersBitSetsAndReferences() throws {
        let a = try DictionaryJavaArrays.read(fixture, kinds: kinds)
        XCTAssertEqual(a.map(\.count), [4,3,3,3,2,4,2])
        XCTAssertEqual(try (0..<4).map { try a[0].signed(at: $0) }, [-1,0,32767,-32768])
        XCTAssertEqual(try (0..<3).map { try a[1].signed(at: $0) }, [-1,Int64(Int32.max),Int64(Int32.min)])
        XCTAssertEqual(try (0..<3).map { try a[2].signed(at: $0) }, [-1,Int64.max,Int64.min])
        XCTAssertEqual(try a[3].unsigned(at: 0), 0x3042)
        XCTAssertEqual(try a[3].unsigned(at: 1), 0xffff)
        XCTAssertEqual(try a[3].unsigned(at: 2), 0)
        XCTAssertEqual(try a[4].unsigned(at: 0), 0x8000000000000001)
        XCTAssertEqual(try a[4].unsigned(at: 1), 1)
        XCTAssertEqual(try a[5].signed(at: 0), -1)
        XCTAssertEqual(try a[6].unsigned(at: 0), try a[4].unsigned(at: 0))
        XCTAssertThrowsError(try a[0].signed(at: -1))
        XCTAssertThrowsError(try a[0].unsigned(at: 4))
    }
    func testRejectsTruncationTrailingDataWrongKindsAndUnknownTags() {
        for length in 0..<fixture.count {
            XCTAssertThrowsError(try DictionaryJavaArrays.read(fixture.prefix(length), kinds: kinds))
        }
        XCTAssertThrowsError(try DictionaryJavaArrays.read(fixture + Data([0]), kinds: kinds))
        XCTAssertThrowsError(try DictionaryJavaArrays.read(fixture, kinds: [.ints]))
        for (offset, value): (Int, UInt8) in [(4,0x7e),(10,0),(23,0xff)] {
            var bad = fixture; bad[offset] = value
            XCTAssertThrowsError(try DictionaryJavaArrays.read(bad, kinds: kinds))
        }
        var badReference = fixture; badReference[badReference.count - 1] = 0xff
        XCTAssertThrowsError(try DictionaryJavaArrays.read(badReference, kinds: kinds))
    }
    func testRejectsRecursiveBitSetAndSerializedObjectsOtherThanBitSet() {
        let nested = Data(base64Encoded: "rO0ABXNyABBqYXZhLnV0aWwuQml0U2V0bv2Ifjk0qyEDAAFbAARiaXRzdAACW0p4cHNxAH4AAHVyAAJbSnggBLUSsXWTAgAAeHAAAAABAAAAAAAAAHt4eA==")!
        XCTAssertThrowsError(try DictionaryJavaArrays.read(nested, kinds: [.longs]))
        // BitSet descriptor's handles: descriptor 0, field type string 1,
        // pending BitSet object 2. Its bits field may not refer to object 2.
        let recursive = Data([0xac,0xed,0,5,0x73,0x72,0,16] + Array("java.util.BitSet".utf8) +
            [0x6e,0xfd,0x88,0x7e,0x39,0x34,0xab,0x21,3,0,1,0x5b,0,4] + Array("bits".utf8) +
            [0x74,0,2,0x5b,0x4a,0x78,0x70,0x71,0,0x7e,0,2,0x78])
        XCTAssertThrowsError(try DictionaryJavaArrays.read(recursive, kinds: [.longs]))
        var wrong = fixture; wrong[4] = 0x73 // TC_OBJECT cannot construct a primitive-array class.
        XCTAssertThrowsError(try DictionaryJavaArrays.read(wrong, kinds: kinds))
    }
    func testRealDictionaryStreamsWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_ASSETS"] else {
            throw XCTSkip("Set SUMIRE_REFERENCE_ASSETS to validate the real distribution")
        }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)!
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var streams = 0
        for case let url as URL in files where url.pathExtension == "zip" {
            let zip = try DictionaryZipArchive(url: url)
            for entry in zip.entries where !entry.isDirectory {
                let target = staging.appendingPathComponent(UUID().uuidString)
                try zip.extract(entry, to: target)
                let data = try Data(contentsOf: target, options: .mappedIfSafe)
                defer { try? FileManager.default.removeItem(at: target) }
                guard data.starts(with: [0xac, 0xed, 0, 5]) else { continue } // Raw connection matrix.
                let expected: [DictionaryPrimitiveKind]
                if url.lastPathComponent.hasPrefix("token") {
                    expected = url.deletingLastPathComponent().lastPathComponent == "english"
                        ? [.shorts,.ints,.longs] : [.shorts,.shorts,.ints,.longs]
                } else if url.lastPathComponent.hasPrefix("tango") {
                    expected = [.longs,.longs,.characters]
                } else { expected = [.longs,.longs,.characters,.ints] }
                let arrays = try DictionaryJavaArrays.read(data, kinds: expected)
                XCTAssertEqual(arrays.count, expected.count, url.path)
                XCTAssertTrue(arrays.allSatisfy { $0.count > 0 }, url.path)
                streams += 1
            }
        }
        let word = try Data(contentsOf: base.appendingPathComponent("english/word.dat"), options: .mappedIfSafe)
        XCTAssertEqual(try DictionaryJavaArrays.read(word, kinds: [.longs,.longs,.characters]).count, 3)
        XCTAssertEqual(streams, 98)
        print("Verified \(streams + 1) real Java primitive-array streams")
    }
}
