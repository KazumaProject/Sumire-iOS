import XCTest
import SumireCore
@testable import Sumire

final class JapaneseASCIIProviderIntegrationTests: XCTestCase {
    private func convert(_ service: ConversionService, _ reading: String, generation: UInt64, bunsetsu: Bool = false) throws -> ConversionResponse {
        let done = expectation(description: "production Japanese provider")
        var response: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, bunsetsuSearch: bunsetsu) { response = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(response).get()
    }
    func testPinnedEnglishAndNumericProvidersReachActualService() throws {
        let service = ConversionService(categoryMask: 0)
        let english = try convert(service, "ab", generation: 1)
        XCTAssertTrue(english.candidates.contains { $0.dictionaries.contains("english") })
        let number = try convert(service, "1", generation: 2)
        XCTAssertTrue(number.candidates.contains { $0.text == "一" && $0.score == 2000 })
        XCTAssertTrue(number.candidates.contains { $0.text == "①" && $0.score == 8500 })
    }
    func testLoadQualifierMatchesPinnedASCIIAndFullWidthEntryConditions() {
        for input in ["a", "Ab", "ABC", "ａｂ", "ＡＢ", "＋", "　", "ａ＋ｂ"] {
            XCTAssertTrue(NativeDictionaryEngineOpener.requiresJapaneseEnglishWords(input), input)
        }
        for input in ["", "a1", "a+b", "a b", "あ", "é", "aあ", "123", "１２３", "😀"] {
            XCTAssertFalse(NativeDictionaryEngineOpener.requiresJapaneseEnglishWords(input), input)
        }
    }
    func testEnglishProviderPreservesTypedRangeAndDoesNotDuplicatePersonal() throws {
        let service = ConversionService(categoryMask: 0)
        let normal = try convert(service, "ab", generation: 1)
        let wide = try convert(service, "ａｂ", generation: 2)
        func provider(_ response: ConversionResponse) -> [ConversionCandidate] { response.candidates.filter { $0.dictionaries.contains("english") } }
        XCTAssertFalse(provider(normal).isEmpty)
        XCTAssertEqual(Set(provider(normal).map(\.text)), Set(provider(wide).map(\.text)))
        XCTAssertTrue(provider(normal).allSatisfy { $0.range == NSRange(location: 0, length: 2) })
        XCTAssertTrue(provider(wide).allSatisfy { $0.range == NSRange(location: 0, length: 2) })
        XCTAssertTrue(normal.complete); XCTAssertTrue(wide.complete)
        let punctuation = try convert(service, "ａ＋ｂ", generation: 3)
        XCTAssertTrue(provider(punctuation).contains { $0.text == "a＋b" })
        XCTAssertFalse(provider(punctuation).contains { $0.text == "a+b" })
        XCTAssertTrue(provider(try convert(service, "a1", generation: 4)).isEmpty)
        XCTAssertTrue(provider(try convert(service, "ab", generation: 5, bunsetsu: true)).isEmpty)
        var personal = PersonalLexicon()
        personal.words = [PersonalWord(word: "UniquePersonal", reading: "ab", posScore: -10000)]
        service.setPersonal(personal)
        XCTAssertEqual(try convert(service, "ab", generation: 6).candidates.filter { $0.text == "UniquePersonal" }.count, 1)
    }
    func testNumericAndNormalizedSymbolsKeepOriginalUTF16Bounds() throws {
        let service = ConversionService(categoryMask: 0)
        for (index, reading) in ["1", "１２", "9223372036854775808", "+", "＋", "＋＋", "あ😀1"].enumerated() {
            let response = try convert(service, reading, generation: UInt64(index + 1))
            XCTAssertFalse(response.candidates.isEmpty)
            for candidate in response.candidates {
                XCTAssertNotNil(Range(candidate.range, in: reading))
                XCTAssertLessThanOrEqual(NSMaxRange(candidate.range), reading.utf16.count)
            }
        }
    }

    func testKotlinWhitespaceBoundaryInputsRemainOwnedAndUTF16Safe() throws {
        let service = ConversionService(categoryMask: 0)
        for (index, reading) in ["\u{00a0}", "\u{2007}", "\u{202f}"].enumerated() {
            XCTAssertFalse(NativeDictionaryEngineOpener.requiresJapaneseEnglishWords(reading))
            let response = try convert(service, reading, generation: UInt64(index + 1))
            XCTAssertFalse(response.candidates.isEmpty)
            XCTAssertTrue(response.candidates.allSatisfy { Range($0.range, in: reading) != nil && NSMaxRange($0.range) <= reading.utf16.count })
        }
    }
    private func packed<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data()
        for value in values { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        return data
    }
    private func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~value
    }
    private func file(kind: UInt32, dimension: UInt32, sections: [Data]) -> Data {
        var directory = Data(), body = Data(), offset = 24 + 24 * sections.count
        for section in sections {
            let padding = (8 - offset % 8) % 8
            body.append(Data(repeating: 0, count: padding)); offset += padding
            directory.append(packed([UInt64(offset), UInt64(section.count)]))
            directory.append(packed([crc(section), UInt32(0)]))
            body.append(section); offset += section.count
        }
        return Data("SUMIRE01".utf8) + packed([UInt32(1), kind, UInt32(sections.count), dimension]) + directory + body
    }
    private func dictionary(_ text: String, cost: Int16 = 0) -> Data {
        let textBytes = Data(text.utf8)
        return file(kind: 1, dimension: 0, sections: [
            packed([UInt64(5)]), packed([UInt16(32), 32, 0x3042]), packed([UInt64(4)]),
            packed([UInt32(1)]), packed([UInt32(0), 0, 1]), packed([UInt16(0)]),
            packed([cost]), packed([UInt32(0)]), packed([UInt32(0), UInt32(textBytes.count)]), textBytes
        ])
    }

    func testEnglishFallbackDoesNotPermanentlyRejectJapaneseOnlyStoredGeneration() throws {
        let bundle = try XCTUnwrap(ConversionService.bundledDictionary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let matrix = file(kind: 2, dimension: 1, sections: [
            packed([UInt16(0)]), packed([UInt16(0)]), packed([Int16(0)]), packed([UInt64(0)]),
            Data(), packed([UInt32(0), 0]), packed([UInt16(0)])
        ])
        try matrix.write(to: base.appendingPathComponent("connection.sud"))
        try dictionary("共有世代固有", cost: -1000).write(to: base.appendingPathComponent("system.sud"))
        try Data("v1.7.277\n".utf8).write(to: base.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let stored = try DictionaryGenerationStore(directory: root.appendingPathComponent("store"))
            .publish(importedFiles: [:], from: base, supportFallback: base)
        let service = ConversionService(sources: [.init(generation: stored), .init(directory: bundle)])
        service.setCategoryIDs([]); service.setEnglishReading(false)
        XCTAssertTrue(try convert(service, "あ", generation: 1).candidates.contains { $0.text == "共有世代固有" })
        XCTAssertTrue(try convert(service, "ab", generation: 2).candidates.contains { $0.dictionaries.contains("english") })
        XCTAssertTrue(try convert(service, "あ", generation: 3).candidates.contains { $0.text == "共有世代固有" },
                      "An optional English-file failure must not blacklist a generation that still serves Japanese input")
    }

}
