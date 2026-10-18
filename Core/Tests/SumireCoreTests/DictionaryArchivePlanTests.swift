import XCTest
@testable import SumireCore

final class DictionaryArchivePlanTests: XCTestCase {
    func testSystemThirtyCategoriesAndBothEnglishFormats() throws {
        XCTAssertEqual(DictionaryArchivePlan.categoryIDs.count, 30)
        var names = ["backup/system/tango.dat.zip", "backup/system/yomi.dat", "backup/system/token.dat.zip"]
        for id in DictionaryArchivePlan.categoryIDs {
            names += ["tango", "yomi", "token"].map { "backup/categories/\(id)/\($0).dat.zip" }
        }
        names += ["english/reading.dat.zip", "english/word.dat", "english/token.dat.zip",
                  "english_reading/tango.dat.zip", "english_reading/yomi.dat.zip", "english_reading/token.dat"]
        let plan = try DictionaryArchivePlan(entryNames: names)
        XCTAssertEqual(plan.groups.count, 33)
        XCTAssertEqual(plan.validationCandidates.count, 33)
        XCTAssertEqual(plan.recognizedEntries, 99)
        XCTAssertEqual(plan.groups.first?.entries.map(\.container), [.nestedZIP, .rawData, .nestedZIP])
        XCTAssertEqual(plan.groups.first(where: { $0.group == .english })?.entries.map(\.key.role), [.reading, .word, .token])
    }
    func testLegacyAliasesCommonPairAndCase() throws {
        let plan = try DictionaryArchivePlan(entryNames: ["backup/TANGO.dat", "YOMI.DAT", "Token.dat.zip",
                                                         "backup/system/connectionId.dat.zip", "system/pos_table.dat"])
        XCTAssertEqual(plan.validationCandidates.map(\.group), [.system, .common])
        XCTAssertEqual(plan.groups.last?.entries.map(\.container), [.nestedZIP, .rawData])
        let missing = try DictionaryArchivePlan(entryNames: ["connectionId.dat"])
        XCTAssertEqual(missing.groups[0].missingRoles, [.posTable])
        XCTAssertTrue(missing.validationCandidates.isEmpty)
    }
    func testDuplicateRoleInvalidatesWholeGroupWithoutDroppingOtherCompleteGroups() throws {
        let plan = try DictionaryArchivePlan(entryNames: ["system/tango.dat", "system/yomi.dat", "system/token.dat",
            "old/yomi.dat.zip", "english_reading/tango.dat", "english_reading/yomi.dat", "english_reading/token.dat"])
        XCTAssertEqual(plan.duplicates.count, 1)
        XCTAssertEqual(plan.duplicates[0].key, .init(group: .system, role: .yomi))
        XCTAssertEqual(plan.duplicates[0].entryNames, ["system/yomi.dat", "old/yomi.dat.zip"])
        XCTAssertEqual(plan.groups[0].missingRoles, [])
        XCTAssertFalse(plan.groups[0].canValidate)
        XCTAssertEqual(plan.validationCandidates.map(\.group), [.englishReading])
        let absent = try DictionaryArchivePlan(entryNames: ["categories/person/tango.dat"])
        XCTAssertEqual(absent.groups[0].missingRoles, [.yomi, .token])
        XCTAssertTrue(absent.validationCandidates.isEmpty)
    }
    func testUnknownCategoriesNeverBecomeSystemDictionary() throws {
        for name in ["categories/new/yomi.dat", "prefix/CATEGORIES/unknown/token.dat.zip",
                     "categories/person/nested/yomi.dat", "categories/yomi.dat", "english/tango.dat"] {
            guard case .unknown = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
        let plan = try DictionaryArchivePlan(entryNames: ["categories/new/yomi.dat", "categories/person/yomi.dat"])
        XCTAssertEqual(plan.groups.map(\.group), [.category("person")])
    }
    func testUnsafeMetadataUnsupportedAndUnknownStayVisible() throws {
        for name in ["", "/yomi.dat", "../yomi.dat", "a/../yomi.dat", "a/./yomi.dat",
                     "a//yomi.dat", "a\\yomi.dat", "C:/yomi.dat", "a\0.dat", String(repeating: "x", count: 4097)] {
            guard case .unsafe = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
        for name in ["__MACOSX/yomi.dat", "backup/__MACOSX/system/yomi.dat", "folder/.DS_Store", "folder/._yomi.dat", "folder/"] {
            guard case .ignored = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
        for name in ["single_kanji/yomi_singleKanji.dat", "tango_emoji.dat", "token_emoticon.dat",
                     "symbol/yomi.dat", "reading_correction/yomi_reading_correction.dat", "token_kotowaza.dat",
                     "id.def", "english/qwerty_glide_index.dat"] {
            guard case .unsupported(let reason) = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
            XCTAssertFalse(reason.isEmpty)
        }
        let plan = try DictionaryArchivePlan(entryNames: ["readme.txt", "id.def", "__MACOSX/a", "../yomi.dat"])
        XCTAssertEqual(plan.entryResults.count, 4)
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertThrowsError(try DictionaryArchivePlan(entryNames: Array(repeating: "x", count: 4097)))
    }
    func testRepeatedIdenticalEntryIsAmbiguousEvenWithoutArchiveParser() throws {
        let plan = try DictionaryArchivePlan(entryNames: ["tango.dat", "yomi.dat", "token.dat", "token.dat"])
        XCTAssertEqual(plan.duplicates.first?.entryNames, ["token.dat", "token.dat"])
        XCTAssertTrue(plan.validationCandidates.isEmpty)
    }
}
