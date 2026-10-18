import Foundation
import CryptoKit
import XCTest
@testable import SumireCore

final class DictionarySourceValidationTests: XCTestCase {
    private struct PinnedAndroidAssets: Decodable {
        let sourceRevision: String
        let assetSHA256: [String: String]
    }

    private struct ReferenceNativeManifest: Decodable {
        let sourceRevision: String
        let assetSHA256: [String: String]
        let outputSHA256: [String: String]

        enum CodingKeys: String, CodingKey {
            case sourceRevision = "source_revision"
            case assetSHA256 = "asset_sha256"
            case outputSHA256 = "output_sha256"
        }
    }

    private struct SerializedArray {
        let kind: DictionaryPrimitiveKind
        let values: [UInt64]
    }

    private func append(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in (0..<width).reversed() {
            data.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
        }
    }

    private func verifyPinnedAssets(_ hashes: [String: String], under root: URL) throws {
        for (relativePath, expectedHash) in hashes {
            let asset = root.appendingPathComponent(relativePath, isDirectory: false)
            let bytes = try Data(contentsOf: asset, options: .mappedIfSafe)
            let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else {
                throw PersonalDataError("固定Android辞書資産のSHA-256が一致しません: \(relativePath)")
            }
        }
    }

    /// Small ObjectOutputStream-compatible fixture writer. Each descriptor is
    /// independent so the fixture stays readable and easy to mutate.
    private func stream(_ arrays: [SerializedArray]) -> Data {
        var data = Data([0xac, 0xed, 0, 5])
        let descriptors: [DictionaryPrimitiveKind: (String, UInt64)] = [
            .shorts: ("[S", 0xef832e06e55db0fa),
            .ints: ("[I", 0x4dba602676eab2a5),
            .longs: ("[J", 0x782004b512b17593),
            .characters: ("[C", 0xb02666b0e25d84ac)
        ]
        for array in arrays {
            let (name, uid) = descriptors[array.kind]!
            data.append(0x75) // TC_ARRAY
            data.append(0x72) // TC_CLASSDESC
            let nameBytes = Array(name.utf8)
            append(UInt64(nameBytes.count), width: 2, to: &data)
            data.append(contentsOf: nameBytes)
            append(uid, width: 8, to: &data)
            data.append(contentsOf: [2, 0, 0, 0x78, 0x70]) // flags, fields, endblock, null superclass
            append(UInt64(array.values.count), width: 4, to: &data)
            let width = array.kind == .characters ? 2 : array.kind.rawValue
            for value in array.values { append(value, width: width, to: &data) }
        }
        return data
    }

    private func parse(_ arrays: [SerializedArray]) throws -> [DictionaryPrimitiveArray] {
        try DictionaryJavaArrays.read(stream(arrays), kinds: arrays.map(\.kind))
    }

    private func trie(label: UInt16 = 0x3042, leafBits: [UInt64] = [0b100], labels: [UInt64]? = nil,
                      termIDs: [UInt64] = [1]) throws -> [DictionaryPrimitiveArray] {
        try parse([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: leafBits),
            .init(kind: .characters, values: labels ?? [0, 0x20, UInt64(label)]),
            .init(kind: .ints, values: termIDs)
        ])
    }

    private func surfaceTrie(label: UInt16 = 0x611) throws -> [DictionaryPrimitiveArray] {
        try parse([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, UInt64(label)])
        ])
    }

    private func japaneseTokens(nodes: [UInt64] = [2], postings: [UInt64] = [0b10],
                                pos: [UInt64]? = nil, costs: [UInt64]? = nil) throws -> [DictionaryPrimitiveArray] {
        try parse([
            .init(kind: .shorts, values: pos ?? Array(repeating: 0, count: nodes.count)),
            .init(kind: .shorts, values: costs ?? Array(repeating: 100, count: nodes.count)),
            .init(kind: .ints, values: nodes),
            .init(kind: .longs, values: postings)
        ])
    }

    private func englishTokens(nodes: [UInt64] = [2], postings: [UInt64] = [0b10]) throws -> [DictionaryPrimitiveArray] {
        try parse([
            .init(kind: .shorts, values: Array(repeating: 100, count: nodes.count)),
            .init(kind: .ints, values: nodes),
            .init(kind: .longs, values: postings)
        ])
    }

    func testValidJapaneseSourceExposesCheckedArraysAndIndexes() throws {
        let value = try DictionarySourceValidation.validate(
            reading: trie(), surface: surfaceTrie(), tokens: japaneseTokens(), posTableCount: 1
        )

        XCTAssertFalse(value.isEnglish)
        XCTAssertEqual(value.tokenCount, 1)
        XCTAssertEqual(value.unreferencedTokenCount, 0)
        XCTAssertEqual(value.surfaceParents, [0, 0, 1])
        XCTAssertEqual(value.postingOffsets, [0, 0, 1])
        XCTAssertEqual(try value.nativeSurfaceReference(at: 0), 2)
    }

    func testConnectionSourceConversionPreservesDefaultsAndExactExceptions() throws {
        let posTable = try parse([
            .init(kind: .shorts, values: [0, 1, 2]),
            .init(kind: .shorts, values: [2, 1, 0])
        ])
        let matrixValues: [Int16] = [5, 5, 1, 3, 4, 3, 7, -8, 9]
        var matrix = Data()
        for value in matrixValues {
            append(UInt64(bitPattern: Int64(value)), width: 2, to: &matrix)
        }

        let source = try ConnectionSourceValidation.validate(posTable: posTable, matrix: matrix)
        let sections = try SumireConnectionSourceConverter.sections(for: source)
        XCTAssertEqual(sections.count, 7)
        XCTAssertEqual(sections[0], Data([0, 0, 1, 0, 2, 0]))
        XCTAssertEqual(sections[1], Data([2, 0, 1, 0, 0, 0]))
        XCTAssertEqual(sections[2], Data([5, 0, 3, 0, 7, 0]))
        XCTAssertEqual(sections[3], Data([4, 0, 0, 0, 0, 0, 0, 0,
                                          2, 0, 0, 0, 0, 0, 0, 0,
                                          6, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(sections[4], Data([1, 0, 4, 0, 0xf8, 0xff, 9, 0]))
        XCTAssertEqual(sections[5], Data([0, 0, 0, 0, 1, 0, 0, 0,
                                          2, 0, 0, 0, 4, 0, 0, 0]))
        XCTAssertEqual(sections[6], Data(repeating: 0, count: 6))
    }

    func testConnectionSourceValidationRejectsBadShapeAndPOSReferences() throws {
        let posTable = try parse([
            .init(kind: .shorts, values: [0, 1, 2]),
            .init(kind: .shorts, values: [2, 1, 0])
        ])
        XCTAssertThrowsError(try ConnectionSourceValidation.validate(posTable: posTable, matrix: Data([0, 1])))

        let invalidPOS = try parse([
            .init(kind: .shorts, values: [0, 1, 3]),
            .init(kind: .shorts, values: [2, 1, 0])
        ])
        XCTAssertThrowsError(try ConnectionSourceValidation.validate(
            posTable: invalidPOS, matrix: Data(repeating: 0, count: 18)
        ))
    }

    func testEnglishSentinelConversionAndUnreferencedTokensAreLegal() throws {
        let englishReading = try trie(label: 0x61)
        let englishSurface = try surfaceTrie(label: 0x41)
        let oneReferencedGroup = try englishTokens(nodes: [2, 2], postings: [0b1010])
        let english = try DictionarySourceValidation.validate(
            reading: englishReading, surface: englishSurface, tokens: oneReferencedGroup,
            isEnglish: true, posTableCount: 0
        )
        XCTAssertEqual(english.tokenCount, 2)
        XCTAssertEqual(english.unreferencedTokenCount, 1)

        let sentinel = try englishTokens(nodes: [UInt64(bitPattern: -1)])
        let sentinelSource = try DictionarySourceValidation.validate(
            reading: englishReading, surface: englishSurface, tokens: sentinel,
            isEnglish: true, posTableCount: 0
        )
        XCTAssertEqual(try sentinelSource.nativeSurfaceReference(at: 0), -2)
    }

    func testJapaneseSurfaceSentinelsRemainDistinct() throws {
        for reference in [UInt64(bitPattern: -1), UInt64(bitPattern: -2)] {
            let value = try DictionarySourceValidation.validate(
                reading: trie(), surface: surfaceTrie(), tokens: japaneseTokens(nodes: [reference]), posTableCount: 1
            )
            XCTAssertEqual(try value.nativeSurfaceReference(at: 0), Int64(bitPattern: reference))
        }
    }

    func testSurfaceTokenMayReferenceAnInternalTrieNode() throws {
        let reading = try trie()
        let tokens = try japaneseTokens(nodes: [2])
        let internalSurfaceNode = try parse([
            .init(kind: .longs, values: [0b10101]),
            .init(kind: .longs, values: [0b10000]),
            .init(kind: .characters, values: [0, 0x20, 0x61, 0x62])
        ])
        XCTAssertNoThrow(try DictionarySourceValidation.validate(
            reading: reading, surface: internalSurfaceNode, tokens: tokens, posTableCount: 1
        ))
    }

    func testPinnedAssetHashVerificationRejectsChangedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: false)
        try Data("changed source asset".utf8).write(to: system.appendingPathComponent("yomi.dat.zip"))

        XCTAssertThrowsError(try verifyPinnedAssets(
            ["system/yomi.dat.zip": String(repeating: "0", count: 64)], under: root
        ))
    }

    func testRepeatedSiblingLabelsRemainRepresentable() throws {
        let reading = try trie()
        let tokens = try japaneseTokens(nodes: [2])
        let repeatedSiblings = try parse([
            .init(kind: .longs, values: [0b1101]),
            .init(kind: .longs, values: [0b1100]),
            .init(kind: .characters, values: [0, 0x20, 0x61, 0x61])
        ])
        XCTAssertNoThrow(try DictionarySourceValidation.validate(
            reading: reading, surface: repeatedSiblings, tokens: tokens, posTableCount: 1
        ))
    }

    func testStructuralValidationDoesNotRequirePairedUTF16Surrogates() throws {
        let reading = try trie()
        let tokens = try japaneseTokens(nodes: [2])
        let unpairedSurrogate = try parse([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0xd83d])
        ])
        XCTAssertNoThrow(try DictionarySourceValidation.validate(
            reading: reading, surface: unpairedSurrogate, tokens: tokens, posTableCount: 1
        ))
    }

    func testJapaneseConversionCreatesNativeSectionsAndDeduplicatesSurfaceText() throws {
        let reading = try trie()
        let repeatedSiblings = try parse([
            .init(kind: .longs, values: [0b1101]),
            .init(kind: .longs, values: [0b1100]),
            .init(kind: .characters, values: [0, 0x20, 0x61, 0x61])
        ])
        let tokens = try japaneseTokens(nodes: [2, 3], postings: [0b110])
        let source = try DictionarySourceValidation.validate(
            reading: reading, surface: repeatedSiblings, tokens: tokens, posTableCount: 1
        )

        let sections = try SumireDictionarySourceConverter.sections(for: source)

        XCTAssertEqual(sections.count, 10)
        XCTAssertEqual(Array(sections[0]), [5, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(sections[1]), [0, 0, 0x20, 0, 0x42, 0x30])
        XCTAssertEqual(Array(sections[2]), [4, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(sections[3]), [1, 0, 0, 0])
        XCTAssertEqual(Array(sections[4]), [0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0])
        XCTAssertEqual(Array(sections[5]), [0, 0, 0, 0])
        XCTAssertEqual(Array(sections[6]), [100, 0, 100, 0])
        XCTAssertEqual(Array(sections[7]), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(sections[8]), [0, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(Array(sections[9]), [0x61])
    }

    func testEnglishConversionUsesZeroPOSAndPreservesEnglishSentinel() throws {
        let source = try DictionarySourceValidation.validate(
            reading: trie(label: 0x61),
            surface: surfaceTrie(label: 0x41),
            tokens: englishTokens(nodes: [2, UInt64(bitPattern: -1)], postings: [0b110]),
            isEnglish: true,
            posTableCount: 0
        )

        let sections = try SumireDictionarySourceConverter.sections(for: source)

        XCTAssertEqual(Array(sections[5]), [0, 0, 0, 0])
        XCTAssertEqual(Array(sections[6]), [100, 0, 100, 0])
        XCTAssertEqual(Array(sections[7]), [0, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff])
        XCTAssertEqual(Array(sections[8]), [0, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(Array(sections[9]), [0x41])
    }

    func testConversionRejectsUnpairedUTF16InsteadOfReplacingIt() throws {
        let invalidSurface = try parse([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0xd83d])
        ])
        let source = try DictionarySourceValidation.validate(
            reading: trie(), surface: invalidSurface, tokens: japaneseTokens(), posTableCount: 1
        )

        XCTAssertThrowsError(try SumireDictionarySourceConverter.sections(for: source))
    }

    func testRejectsMalformedColumnsTriesPostingsAndReferences() throws {
        let reading = try trie()
        let surface = try surfaceTrie()
        let tokens = try japaneseTokens()

        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: Array(tokens.dropLast()), posTableCount: 1
        ))

        let shortTokenColumn = try japaneseTokens(nodes: [2, 2])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: shortTokenColumn, posTableCount: 1
        ))

        let wrongPostingCount = try japaneseTokens(postings: [0])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: wrongPostingCount, posTableCount: 1
        ))

        let invalidTerm = try trie(termIDs: [0])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: invalidTerm, surface: surface, tokens: tokens, posTableCount: 1
        ))

        let invalidPOS = try japaneseTokens(pos: [1])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: invalidPOS, posTableCount: 1
        ))

        let invalidSurfaceNode = try japaneseTokens(nodes: [3])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: invalidSurfaceNode, posTableCount: 1
        ))

        let nonTreeLeaves = try trie(leafBits: [0b110])
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: nonTreeLeaves, surface: surface, tokens: tokens, posTableCount: 1
        ))

        var limits = DictionarySourceValidation.Limits()
        limits.nodes = 1
        XCTAssertThrowsError(try DictionarySourceValidation.validate(
            reading: reading, surface: surface, tokens: tokens, posTableCount: 1, limits: limits
        ))
    }

    func testRealSourceSetsWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_ASSETS"] else {
            throw XCTSkip("Set SUMIRE_REFERENCE_ASSETS to validate the pinned Android distribution")
        }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let pinnedURL = try XCTUnwrap(Bundle.module.url(forResource: "PinnedAndroidDictionaryAssets", withExtension: "json"))
        let pinned = try JSONDecoder().decode(PinnedAndroidAssets.self, from: Data(contentsOf: pinnedURL))
        XCTAssertEqual(pinned.sourceRevision, "df1f38315bf56d860d32919a3eaed6a75499e91e")
        XCTAssertEqual(pinned.assetSHA256.count, 101)
        try verifyPinnedAssets(pinned.assetSHA256, under: base)
        let referenceDirectory = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_NATIVE_DICTIONARIES"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var referenceManifest: ReferenceNativeManifest?
        if let referenceDirectory {
            let manifestURL = referenceDirectory.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(ReferenceNativeManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.sourceRevision, pinned.sourceRevision)
            XCTAssertEqual(manifest.assetSHA256, pinned.assetSHA256)
            referenceManifest = manifest
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let assetFiles = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]))
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false }
        let entryNames = assetFiles.map { String($0.path.dropFirst(base.path.count + 1)) }
        let archivePlan = try DictionaryArchivePlan(entryNames: entryNames)
        XCTAssertEqual(archivePlan.validationCandidates.count, 34)

        func payload(at relativePath: String) throws -> Data {
            let url = base.appendingPathComponent(relativePath)
            if url.pathExtension != "zip" { return try Data(contentsOf: url, options: .mappedIfSafe) }
            let archive = try DictionaryZipArchive(url: url)
            let entry = try XCTUnwrap(archive.entries.first { !$0.isDirectory && !$0.name.hasPrefix("__MACOSX/") })
            let target = staging.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: target) }
            try archive.extract(entry, to: target)
            return try Data(contentsOf: target, options: .mappedIfSafe)
        }
        func decode(_ relativePath: String, kinds: [DictionaryPrimitiveKind]) throws -> [DictionaryPrimitiveArray] {
            do { return try DictionaryJavaArrays.read(payload(at: relativePath), kinds: kinds) }
            catch { throw PersonalDataError("\(relativePath): \(error.localizedDescription)") }
        }

        let posTable = try decode("pos_table.dat", kinds: [.shorts, .shorts])
        XCTAssertEqual(posTable[0].count, posTable[1].count)
        XCTAssertGreaterThan(posTable[0].count, 0)
        let connection = try ConnectionSourceValidation.validate(
            posTable: posTable, matrix: payload(at: "connectionId.dat.zip")
        )
        if let referenceManifest {
            let output = staging.appendingPathComponent("connection.sud")
            try SumireConnectionSourceConverter.write(connection, to: output)
            let expected = try XCTUnwrap(referenceManifest.outputSHA256["connection.sud"])
            let actual = SHA256.hash(data: try Data(contentsOf: output, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, expected, "Native binary differs for connection")
        }
        let posCount = posTable[0].count
        var validatedSets = 0

        let roots = DictionaryArchivePlan.categoryIDs.map { "categories/\($0)" } + ["system", "english_reading"]
        for root in roots {
            let reading = try decode("\(root)/yomi.dat.zip", kinds: [.longs, .longs, .characters, .ints])
            let surface = try decode("\(root)/tango.dat.zip", kinds: [.longs, .longs, .characters])
            let tokens = try decode("\(root)/token.dat.zip", kinds: [.shorts, .shorts, .ints, .longs])
            let result = try DictionarySourceValidation.validate(reading: reading, surface: surface, tokens: tokens,
                                                                 posTableCount: posCount)
            XCTAssertGreaterThan(result.tokenCount, 0, root)
            if let referenceManifest {
                let name = try XCTUnwrap(root.split(separator: "/").last.map(String.init))
                let output = staging.appendingPathComponent(name + ".sud")
                try SumireDictionarySourceConverter.write(result, to: output)
                let expected = try XCTUnwrap(referenceManifest.outputSHA256[name + ".sud"], name)
                let actual = SHA256.hash(data: try Data(contentsOf: output, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(actual, expected, "Native binary differs for \(name)")
            }
            validatedSets += 1
        }

        let englishReading = try decode("english/reading.dat.zip", kinds: [.longs, .longs, .characters, .ints])
        let englishSurface = try decode("english/word.dat", kinds: [.longs, .longs, .characters])
        let englishTokens = try decode("english/token.dat.zip", kinds: [.shorts, .ints, .longs])
        let english = try DictionarySourceValidation.validate(reading: englishReading, surface: englishSurface,
                                                               tokens: englishTokens, isEnglish: true, posTableCount: 0)
        XCTAssertEqual(english.tokenCount, 102_050)
        XCTAssertEqual(english.unreferencedTokenCount, 946)
        XCTAssertEqual(englishReading[3].count, 101_104)
        if let referenceManifest {
            let output = staging.appendingPathComponent("english.sud")
            try SumireDictionarySourceConverter.write(english, to: output)
            let expected = try XCTUnwrap(referenceManifest.outputSHA256["english.sud"])
            let actual = SHA256.hash(data: try Data(contentsOf: output, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, expected, "Native binary differs for english")
        }
        validatedSets += 1

        XCTAssertEqual(validatedSets, 33)
        XCTAssertEqual(validatedSets + 1, 34, "The remaining native binary is common connection data")
        if referenceManifest != nil {
            print("Converted all 33 dictionary groups and the connection matrix byte-for-byte to the pinned native binaries")
        }
        print("Validated \(validatedSets) trie/token source sets and the common POS table against pinned Android asset hashes from df1f38315bf56d860d32919a3eaed6a75499e91e")
    }
}
