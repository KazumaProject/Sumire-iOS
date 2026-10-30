import XCTest
@testable import SumireCore
@testable import Sumire

final class BunsetsuASCIIProviderTests: XCTestCase {
    private var roots: [URL] = []
    private var generation: UInt64 = 0
    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []
        super.tearDown()
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
    private func dictionary(reading: String, text: String, cost: Int16) -> Data {
        let units = Array(reading.utf16)
        precondition(!units.isEmpty && units.count < 30)
        var tree: UInt64 = 1
        for index in units.indices { tree |= UInt64(1) << (2 + index * 2) }
        let leaves = UInt64(1) << (units.count * 2)
        let bytes = Data(text.utf8)
        return file(kind: 1, dimension: 0, sections: [
            packed([tree]), packed([UInt16(32), 32] + units), packed([leaves]),
            packed([UInt32(1)]), packed([UInt32(0), 0, 1]), packed([UInt16(0)]),
            packed([cost]), packed([UInt32(0)]), packed([UInt32(0), UInt32(bytes.count)]), bytes
        ])
    }
    private func directory(english: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundled = try XCTUnwrap(ConversionService.bundledDictionary)
        for path in ["connection.sud", "system_ngram.dat", "system_ngram_unigram.dat", "mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat", "standalone.sud", "single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"] {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled.appendingPathComponent(path), to: target)
        }
        try dictionary(reading: "あ", text: "共有日本語固有", cost: -1_000).write(to: root.appendingPathComponent("system.sud"))
        if english { try dictionary(reading: "cat", text: "cat", cost: 100).write(to: root.appendingPathComponent("english.sud")) }
        return root
    }
    private func convert(_ value: ConversionService, _ reading: String) throws -> ConversionResponse {
        generation += 1
        let done = expectation(description: "real bunsetsu ASCII provider")
        var result: Result<ConversionResponse, Error>?
        value.convert(reading, generation: generation, editStart: 0, includeBunsetsu: true, bunsetsuSearch: true) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
    func testEnglishAndWidthCandidatesReachActualBunsetsuService() throws {
        let value = ConversionService(directory: try directory()); value.setEnglishReading(false)
        let response = try convert(value, "ca")
        XCTAssertEqual(response.candidates.first { $0.text == "cat" }?.score, 100)
        XCTAssertEqual(response.candidates.filter { $0.score == 30_000 && $0.presentationKind == .fullWidth }.map(\.text), ["ｃａ", "ＣＡ"])
        let wide = try convert(value, "ｃａ")
        XCTAssertEqual(wide.candidates.first { $0.text == "cat" }?.score, 100)
    }
    func testWordUnknownReadingKnownAndPartialPlanKeepOwnedTypedRanges() throws {
        let root = try directory(), value = ConversionService(directory: root)
        value.setEnglishReading(false)
        let first = try convert(value, "ca"), initialGeneration = generation
        let word = try XCTUnwrap(first.candidates.first { $0.text == "cat" })
        XCTAssertEqual(word.dictionaries, ["english"])
        XCTAssertNil(word.leftID); XCTAssertNil(word.rightID)
        XCTAssertEqual(word.range, NSRange(location: 0, length: 2))
        let snapshot = try XCTUnwrap(first.bunsetsuSnapshot)
        let owned = try XCTUnwrap(snapshot.candidates.first { $0.candidateID == word.id })
        XCTAssertNil(owned.tokenPath); XCTAssertNil(owned.leftID); XCTAssertNil(owned.rightID)
        var session = try BunsetsuConversionSession(rawInput: "caあ", conversionInput: "ca", tailText: "あ",
            wholeDisplayText: first.candidates[0].text, generation: initialGeneration,
            snapshot: snapshot, orderedDisplayCandidates: first.orderedDisplayIdentities)
        let token = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: generation + 1))
        let alternatives = try convert(value, "ca")
        let records = alternatives.candidates.enumerated().map { index, row in
            BunsetsuSessionCandidate(text: row.text, reference: .conversionResult(generation: generation, candidateID: row.id),
                score: row.score, candidateIndex: index, leftID: row.leftID, rightID: row.rightID,
                matchedReadingUTF16Length: row.range.length)
        }
        XCTAssertTrue(session.installCandidates(records, responseReading: "ca", responseGeneration: generation, for: token))
        let index = try XCTUnwrap(session.segments[0].candidateRecords.firstIndex { $0.text == "cat" })
        _ = session.selectFocusedCandidate(at: index)
        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.committedText, "cat"); XCTAssertEqual(plan.committedReading, "ca")
        XCTAssertEqual(plan.readingUTF16Length, 2); XCTAssertEqual(plan.nextComposingInput, "あ")
        XCTAssertNil(plan.learningFragments.first?.leftID); XCTAssertNil(plan.learningFragments.first?.rightID)
        try dictionary(reading: "あ", text: "ReadWord", cost: 400).write(to: root.appendingPathComponent("english_reading.sud"))
        value.setEnglishReading(true)
        let reading = try convert(value, "あ")
        // Fixed v1.7.277 connection.sud POS index zero has these actual endpoints.
        for text in ["ReadWord", "readword", "Readword", "READWORD"] {
            let row = try XCTUnwrap(reading.candidates.first { $0.text == text })
            XCTAssertEqual(row.leftID, 1920); XCTAssertEqual(row.rightID, 1927)
            let token = try XCTUnwrap(reading.bunsetsuSnapshot?.candidates.first { $0.candidateID == row.id }?.tokenPath?.first)
            XCTAssertEqual(token.readingRange, NSRange(location: 0, length: 1))
            XCTAssertEqual(token.leftID, 1920); XCTAssertEqual(token.rightID, 1927)
        }
        XCTAssertEqual(owned.identity.surface, "cat"); XCTAssertNil(owned.tokenPath)
        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(reading: "ca", requestGeneration: initialGeneration + 1,
            orderedDisplayCandidates: first.orderedDisplayIdentities))
    }

    func testNormalJapaneseReadingEndpointsAndWordUnknownSurviveActualCommit() throws {
        let root = try directory(), database = root.appendingPathComponent("metadata.sqlite")
        try dictionary(reading: "あ", text: "ReadWord", cost: 400).write(to: root.appendingPathComponent("english_reading.sud"))
        let value = ConversionService(directory: root); value.setLearning(url: database)
        func normal(_ input: String) throws -> ConversionResponse {
            generation += 1
            let done = expectation(description: "normal Japanese owned metadata")
            var result: Result<ConversionResponse, Error>?
            value.convert(input, generation: generation, editStart: 0, includeBunsetsu: true) { result = $0; done.fulfill() }
            wait(for: [done], timeout: 30)
            return try XCTUnwrap(result).get()
        }
        let wordResponse = try normal("ca")
        let wordIndex = try XCTUnwrap(wordResponse.candidates.firstIndex { $0.text == "cat" })
        let word = wordResponse.candidates[wordIndex]
        XCTAssertNil(word.leftID); XCTAssertNil(word.rightID); XCTAssertEqual(word.dictionaries, ["english"])
        let owned = try XCTUnwrap(wordResponse.bunsetsuSnapshot?.candidates.first { $0.candidateID == word.id })
        XCTAssertNil(owned.tokenPath)
        value.commitSelection(generation: generation, candidate: word, rank: wordIndex, input: "ca", remaining: "", learnFirst: true) { _ in }
        let fenceWord = expectation(description: "word persisted"); value.synchronizeLearning { fenceWord.fulfill() }
        wait(for: [fenceWord], timeout: 10)
        let savedWord = try XCTUnwrap(try LearningStore(url: database).snapshot().first { $0.text == "cat" })
        XCTAssertNil(savedWord.leftID); XCTAssertNil(savedWord.rightID)
        let known = try normal("あ")
        for text in ["ReadWord", "readword", "Readword", "READWORD"] {
            let row = try XCTUnwrap(known.candidates.first { $0.text == text })
            XCTAssertEqual(row.leftID, 1920); XCTAssertEqual(row.rightID, 1927)
            let path = try XCTUnwrap(known.bunsetsuSnapshot?.candidates.first { $0.candidateID == row.id }?.tokenPath)
            XCTAssertEqual(path.first?.leftID, 1920); XCTAssertEqual(path.last?.rightID, 1927)
        }
        let index = try XCTUnwrap(known.candidates.firstIndex { $0.text == "ReadWord" })
        value.commitSelection(generation: generation, candidate: known.candidates[index], rank: index,
            input: "あ", remaining: "", learnFirst: true) { _ in }
        let fenceKnown = expectation(description: "known persisted"); value.synchronizeLearning { fenceKnown.fulfill() }
        wait(for: [fenceKnown], timeout: 10)
        let row = try XCTUnwrap(try LearningStore(url: database).snapshot().first { $0.text == "ReadWord" })
        XCTAssertEqual(row.leftID, 1920); XCTAssertEqual(row.rightID, 1927)
        XCTAssertEqual(owned.identity.surface, "cat"); XCTAssertNil(owned.tokenPath)
        let generated = try normal("ab12")
        for row in generated.candidates.filter({ $0.score == 30_000 && $0.presentationKind == .fullWidth }) {
            XCTAssertNil(row.leftID); XCTAssertNil(row.rightID)
            XCTAssertNil(generated.bunsetsuSnapshot?.candidates.first { $0.candidateID == row.id }?.tokenPath)
        }
        XCTAssertEqual(generated.candidates.filter { $0.score == 30_000 && $0.presentationKind == .fullWidth }.map(\.text), ["ａｂ１２", "ＡＢ１２"])
    }
    func testGeneratedASCIIEligibilityDuplicatesAndNumericEarlyRoute() throws {
        let value = ConversionService(directory: try directory()); value.setEnglishReading(false)
        for (input, expected) in [("ab12", ["ａｂ１２", "ＡＢ１２"]), ("a+b", ["ａ＋ｂ", "Ａ＋Ｂ"]),
                                  ("a b", ["ａ　ｂ", "Ａ　Ｂ"]), ("+", ["＋"]), (" ", ["　"])] {
            let response = try convert(value, input)
            let rows = response.candidates.filter { $0.score == 30_000 && $0.presentationKind == .fullWidth }
            XCTAssertEqual(rows.map(\.text), expected)
            for row in rows {
                XCTAssertEqual(row.range, NSRange(location: 0, length: input.utf16.count))
                XCTAssertNil(row.leftID); XCTAssertNil(row.rightID)
            }
            if input == "+" || input == " " {
                let raw = try XCTUnwrap(response.bunsetsuSnapshot).candidates.filter { $0.score == 30_000 && $0.identity.surface == expected[0] }
                XCTAssertEqual(raw.count, 2, "Raw lower/upper duplicates precede display merging")
                XCTAssertTrue(raw.allSatisfy { $0.tokenPath == nil && $0.leftID == nil && $0.rightID == nil })
            }
        }
        let punctuation = try convert(value, "ａ＋ｂ")
        XCTAssertTrue(punctuation.candidates.contains { $0.text == "a＋b" })
        XCTAssertFalse(punctuation.candidates.contains { $0.text == "a+b" })
        for input in ["123", "１２３"] {
            let response = try convert(value, input)
            XCTAssertFalse(response.candidates.contains { $0.dictionaries.contains("english") })
            XCTAssertFalse(response.candidates.contains { $0.score == 30_000 && $0.presentationKind == .fullWidth })
            let numeric = try XCTUnwrap(response.candidates.first { $0.text == "百二十三" })
            XCTAssertEqual(numeric.leftID, 2040); XCTAssertEqual(numeric.rightID, 2040)
        }
    }
    func testJapaneseOnlySourceRecoversAfterEnglishFallback() throws {
        let japanese = try directory(english: false), english = try directory()
        try dictionary(reading: "あ", text: "JP専用", cost: -1_000).write(to: japanese.appendingPathComponent("system.sud"))
        let value = ConversionService(sources: [.init(directory: japanese), .init(directory: english)])
        value.setEnglishReading(false)
        XCTAssertTrue(try convert(value, "あ").candidates.contains { $0.text == "JP専用" })
        let fallback = try convert(value, "ca")
        XCTAssertEqual(fallback.candidates.first { $0.text == "cat" }?.score, 100)
        let snapshot = try XCTUnwrap(fallback.bunsetsuSnapshot)
        XCTAssertTrue(try convert(value, "あ").candidates.contains { $0.text == "JP専用" })
        XCTAssertEqual(snapshot.candidates.first { $0.identity.surface == "cat" }?.identity.readingUTF16Length, 2)
        XCTAssertNil(snapshot.candidates.first { $0.identity.surface == "cat" }?.tokenPath)
    }
}
