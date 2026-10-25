import XCTest
@testable import SumireCore

final class PersonalDictionaryTextImportTests: XCTestCase {
    func testGoogleFormatParsesTabSeparatedRowsAndPOSHints() {
        let text = """
        とうきょう\t東京\t地名
        はしる\t走る\t動詞
        はやい\t速い\t形容詞
        とても\t迚も\t副詞
        です\tです\t助動詞
        """

        let preview = PersonalImportPreview.parseText(text, format: .googleJapaneseInput)

        XCTAssertEqual(preview.entries.map(\.reading), ["とうきょう", "はしる", "はやい", "とても", "です"])
        XCTAssertEqual(preview.entries.map(\.posIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(preview.entries.map(\.posScore), Array(repeating: 5000, count: 5))
        XCTAssertEqual(preview.rejected, 0)
        XCTAssertEqual(preview.duplicates, 0)
        XCTAssertEqual(preview.duplicatePolicy, .keepFirst)
    }

    func testMicrosoftFormatSwapsReadingAndWordColumns() {
        let preview = PersonalImportPreview.parseText(
            "東京\tとうきょう\t地名\n走る\tはしる\t動詞\nただし\t但し\t接続詞",
            format: .microsoftIME
        )

        XCTAssertEqual(preview.entries.map(\.word), ["東京", "走る", "但し"])
        XCTAssertEqual(preview.entries.map(\.reading), ["とうきょう", "はしる", "ただし"])
        XCTAssertEqual(preview.entries.map(\.posIndex), [0, 1, 7])
    }

    func testSelectedFormatWinsWhenBothFirstColumnsLookLikeReadings() {
        let google = PersonalImportPreview.parseText("よみ\tことば\t助詞", format: .googleJapaneseInput)
        let microsoft = PersonalImportPreview.parseText("ことば\tよみ\t助詞", format: .microsoftIME)

        XCTAssertEqual(google.entries.single?.reading, "よみ")
        XCTAssertEqual(google.entries.single?.word, "ことば")
        XCTAssertEqual(microsoft.entries.single?.reading, "よみ")
        XCTAssertEqual(microsoft.entries.single?.word, "ことば")
        XCTAssertEqual(google.entries.single?.posIndex, 5)
        XCTAssertEqual(microsoft.entries.single?.posIndex, 5)
    }

    func testCSVQuotesHeadersCommentsNormalizationAndAndroidFirstDuplicatePolicy() {
        let text = """
        # Google Japanese Input export
        よみ,単語,品詞
        "トウキョウ","東京,首都",地名
        "トウキョウ","東京,首都",助詞
        はしる,走る,動詞
        not-kana,対象外,名詞
        // comment
        ; comment
        """

        let preview = PersonalImportPreview.parseText(text, format: .automatic)

        XCTAssertEqual(preview.entries.map(\.reading), ["とうきょう", "はしる"])
        XCTAssertEqual(preview.entries.map(\.word), ["東京,首都", "走る"])
        XCTAssertEqual(preview.entries.map(\.posIndex), [0, 1])
        XCTAssertEqual(preview.duplicates, 1)
        XCTAssertEqual(preview.rejected, 1)
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertEqual(preview.duplicatePolicy, .keepFirst)
    }

    func testPOSHintsPreferSpecificAndroidCategoriesAndFallbackToNoun() {
        XCTAssertEqual(PersonalImportPreview.resolvePosIndex("auxiliary verb"), 4)
        XCTAssertEqual(PersonalImportPreview.resolvePosIndex("形容動詞"), 2)
        XCTAssertEqual(PersonalImportPreview.resolvePosIndex("未対応品詞"), 0)
        XCTAssertEqual(PersonalImportPreview.resolvePosIndex(nil), 0)
    }

    func testTextImportRejectsOverLimitFieldsAndExcessiveColumnCounts() {
        let oversizedWord = PersonalImportPreview.parseText("あ\t" + String(repeating: "x", count: 65_537))
        XCTAssertEqual(oversizedWord.entries.count, 0)
        XCTAssertEqual(oversizedWord.rejected, 1)

        let excessiveColumns = PersonalImportPreview.parseText(Array(repeating: "", count: 257).joined(separator: ","))
        XCTAssertEqual(excessiveColumns.entries.count, 0)
        XCTAssertEqual(excessiveColumns.rejected, 1)
    }

    func testTextImportStopsAtLineLimitAndReportsUnprocessedRemainder() {
        let preview = PersonalImportPreview.parseText(String(repeating: "\n", count: 100_001))

        XCTAssertTrue(preview.wasTruncated)
        XCTAssertEqual(preview.entries.count, 0)
        XCTAssertEqual(preview.rejected, 0)
    }

    func testTextImportCannotBeAppliedToTemplates() throws {
        let preview = PersonalImportPreview.parseText("とうきょう\t東京\t地名")

        XCTAssertThrowsError(try preview.applying(to: PersonalLexicon(), template: true))
        XCTAssertNoThrow(try preview.applying(to: PersonalLexicon(), template: false))
    }

    func testApplyingImportPreservesExistingRowsAndPreflightsLexiconLimit() throws {
        var existing = PersonalLexicon()
        existing.words = [
            PersonalWord(word: "東京", reading: "とうきょう", posIndex: 0, posScore: 1000),
            PersonalWord(word: "既存語", reading: "きそんご")
        ]
        let preview = PersonalImportPreview.parseText("とうきょう\t東京\t助詞\nおおさか\t大阪\t地名")
        let application = try preview.applying(to: existing, template: false)

        XCTAssertEqual(application.addedEntries, 1)
        XCTAssertEqual(application.existingDuplicates, 1)
        XCTAssertEqual(application.lexicon.words[0], existing.words[0])
        XCTAssertEqual(application.lexicon.words[1], existing.words[1])
        XCTAssertEqual(application.lexicon.words[2].word, "大阪")

        var full = PersonalLexicon()
        full.words = (0..<100_000).map { index in
            PersonalWord(word: "word-\(index)", reading: "reading-\(index)")
        }
        let oneMore = PersonalImportPreview(entries: [PersonalWord(word: "追加", reading: "あ")],
                                            rejected: 0, errors: [], duplicates: 0)
        XCTAssertThrowsError(try oneMore.applying(to: full, template: false))
    }

    func testTextDecodingHandlesUTF8BOMUTF16AndShiftJIS() throws {
        let text = "とうきょう\t東京\t地名"

        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        XCTAssertEqual(try PersonalImportPreview.parseText(utf8).entries.single?.reading, "とうきょう")

        let utf16LEPayload = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let utf16LE = Data([0xFF, 0xFE]) + utf16LEPayload
        XCTAssertEqual(try PersonalImportPreview.parseText(utf16LE).entries.single?.word, "東京")

        let utf16BEPayload = try XCTUnwrap(text.data(using: .utf16BigEndian))
        let utf16BE = Data([0xFE, 0xFF]) + utf16BEPayload
        XCTAssertEqual(try PersonalImportPreview.parseText(utf16BE).entries.single?.reading, "とうきょう")

        let shiftJIS = try XCTUnwrap(text.data(using: .shiftJIS))
        XCTAssertEqual(try PersonalImportPreview.parseText(shiftJIS).entries.single?.word, "東京")
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
