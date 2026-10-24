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
    func testAndroidReadingCorrectionAliasesMapToOneJapaneseDictionaryGroup() throws {
        let plan = try DictionaryArchivePlan(entryNames: [
            "reading_correction/tango_reading_correction.dat",
            "backup/reading_correction/yomi_reading_correction.dat",
            "token_reading_correction.dat"
        ])
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(group.group, .readingCorrection)
        XCTAssertEqual(group.group.id, "reading_correction")
        XCTAssertEqual(Set(group.entries.map(\.key.role)), Set([.tango, .yomi, .token]))
        XCTAssertTrue(group.entries.allSatisfy { $0.container == .rawData })
        XCTAssertTrue(group.canValidate)

        for name in ["reading_correction/tango.dat", "reading_correction/tango_reading_correction.dat.zip"] {
            guard case .unknown = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
    }
    func testAndroidAuxiliaryDictionaryAliasesMapToEngineDictionaryGroups() throws {
        let names = [
            "single_kanji/tango_singleKanji.dat", "single_kanji/yomi_singleKanji.dat.zip", "single_kanji/token_singleKanji.dat",
            "emoji/tango_emoji.dat", "emoji/yomi_emoji.dat", "emoji/token_emoji.dat.zip",
            "emoticon/tango_emoticon.dat.zip", "emoticon/yomi_emoticon.dat", "emoticon/token_emoticon.dat",
            "symbol/tango_symbol.dat", "symbol/yomi_symbol.dat.zip", "symbol/token_symbol.dat"
        ]
        let plan = try DictionaryArchivePlan(entryNames: names)
        XCTAssertEqual(plan.groups.map(\.group), [.auxiliary("single_kanji"), .auxiliary("emoji"),
                                                    .auxiliary("emoticon"), .auxiliary("symbol")])
        XCTAssertEqual(plan.groups.map(\.group.id), ["single_kanji", "emoji", "emoticon", "symbol"])
        XCTAssertTrue(plan.groups.allSatisfy { $0.canValidate })
        XCTAssertTrue(plan.groups.allSatisfy { Set($0.entries.map(\.key.role)) == Set([.tango, .yomi, .token]) })
        XCTAssertEqual(plan.groups.flatMap(\.entries).filter { $0.container == .nestedZIP }.count, 4)

        let flat = try DictionaryArchivePlan(entryNames: ["tango_singleKanji.dat", "yomi_singleKanji.dat", "token_singleKanji.dat"])
        XCTAssertEqual(flat.groups.map(\.group), [.auxiliary("single_kanji")])
        guard case .mapped(let nestedAlias) = DictionaryArchivePlan.resolve("unrelated/prefix/emoji/tango_emoji.dat") else {
            return XCTFail("nested Android filename alias was not mapped")
        }
        XCTAssertEqual(nestedAlias.key.group, .auxiliary("emoji"))
        for name in ["emoji/readme.dat", "emoticon/tango_other.dat"] {
            guard case .unknown = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
    }
    func testAndroidKotowazaDictionaryMapsItsThreeRawRoles() throws {
        let names = ["kotowaza/tango_kotowaza.dat", "kotowaza/yomi_kotowaza.dat",
                     "kotowaza/token_kotowaza.dat"]
        let plan = try DictionaryArchivePlan(entryNames: names)
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(group.group, .proverb)
        XCTAssertEqual(group.group.id, "kotowaza")
        XCTAssertEqual(Set(group.entries.map(\.key.role)), Set([.tango, .yomi, .token]))
        XCTAssertTrue(group.canValidate)
        XCTAssertTrue(group.entries.allSatisfy { $0.container == .rawData })

        let flat = try DictionaryArchivePlan(entryNames: ["tango_kotowaza.dat", "yomi_kotowaza.dat",
                                                          "token_kotowaza.dat"])
        XCTAssertEqual(flat.validationCandidates.map(\.group), [.proverb])
        guard case .mapped(let legacySystemAlias) = DictionaryArchivePlan.resolve("kotowaza/tango.dat") else {
            return XCTFail("Android's generic tango.dat fallback was not preserved")
        }
        XCTAssertEqual(legacySystemAlias.key.group, .system)
        for name in ["kotowaza/readme.txt", "kotowaza/tango_kotowaza.dat.zip"] {
            guard case .unknown = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
        }
        for name in ["kotowaza/nested/yomi_kotowaza.dat", "backup/export/kotowaza/token_kotowaza.dat",
                     "unrelated/prefix/tango_kotowaza.dat"] {
            guard case .mapped(let entry) = DictionaryArchivePlan.resolve(name) else { return XCTFail(name) }
            XCTAssertEqual(entry.key.group, .proverb)
        }
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
                     "categories/person/nested/yomi.dat", "categories/yomi.dat", "english/tango.dat",
                     "symbol/yomi.dat"] {
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
        for name in ["id.def", "english/qwerty_glide_index.dat"] {
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
