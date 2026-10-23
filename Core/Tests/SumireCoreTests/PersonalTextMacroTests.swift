import Foundation
import XCTest
@testable import SumireCore

final class PersonalTextMacroTests: XCTestCase {
    func testPersonalLexiconReadsOlderSnapshotsWithoutMacroField() throws {
        let legacy = #"{"formatVersion":1,"words":[],"templates":[]}"#
        let decoded = try JSONDecoder().decode(PersonalLexicon.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.textMacros, [])

        var lexicon = decoded
        lexicon.textMacros = [PersonalTextMacro(name: "mail", reading: "めーる", body: "Hello{cursor}")]
        let roundTrip = try JSONDecoder().decode(PersonalLexicon.self, from: JSONEncoder().encode(lexicon))
        XCTAssertEqual(roundTrip, lexicon)
    }

    func testAndroidBackupRoundTripsExactFieldsAndStagesNameBasedMerge() throws {
        let existing = PersonalTextMacro(name: "Mail", body: "old")
        let source = [
            PersonalTextMacro(name: "MAIL", reading: "めーる", body: "new{cursor}", enabled: false),
            PersonalTextMacro(name: "Signature", body: "Sumire")
        ]
        let encoded = try AndroidTextMacroBackup.encode(source)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        let rows = try XCTUnwrap(envelope["macros"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), Set(["name", "reading", "body", "enabled"]))
        XCTAssertTrue(rows[1]["reading"] is NSNull)

        let preview = try AndroidTextMacroBackup.decode(encoded, existing: [existing])
        XCTAssertEqual(preview.added, 1)
        XCTAssertEqual(preview.overwritten, 1)
        XCTAssertEqual(preview.entries.map(\.name), ["MAIL", "Signature"])
        XCTAssertEqual(preview.entries[0].body, "new{cursor}")
        XCTAssertFalse(preview.entries[0].enabled)
    }

    func testAndroidBackupRequiresAllFieldsAllowsNullReadingAndRejectsInvalidShape() throws {
        let missingReading = #"{"version":1,"macros":[{"name":"mail","body":"Hi","enabled":true}]}"#
        XCTAssertThrowsError(try AndroidTextMacroBackup.decode(Data(missingReading.utf8)))

        for source in [
            #"{"version":2,"macros":[]}"#,
            #"{"version":1,"extra":false,"macros":[]}"#,
            #"{"version":1,"macros":[{"name":"x","reading":false,"body":"Hi","enabled":true}]}"#,
            #"{"version":1,"macros":[{"name":"x","reading":null,"body":"{unknown}","enabled":true}]}"#,
            #"{"version":1,"macros":[{"name":"x","reading":null,"body":"Hi","enabled":1}]}"#,
            #"{"version":1,"macros":[{"name":"x","reading":null,"body":"Hi","enabled":true},{"name":"X","reading":null,"body":"There","enabled":false}]}"#
        ] {
            XCTAssertThrowsError(try AndroidTextMacroBackup.decode(Data(source.utf8)), source)
        }
    }

    func testAndroidImportPreservesNamesAndNonblankReadingsAndMapsBlankReadingToNull() throws {
        let source = #"{"version":1,"macros":[{"name":"  mail  ","reading":" あ ","body":"Hi","enabled":true},{"name":"note","reading":" \n ","body":"There","enabled":false}]}"#
        let preview = try AndroidTextMacroBackup.decode(Data(source.utf8))

        XCTAssertEqual(preview.entries.map(\.name), ["  mail  ", "note"])
        XCTAssertEqual(preview.entries[0].reading, " あ ")
        XCTAssertNil(preview.entries[1].reading)

        let roundTrip = try AndroidTextMacroBackup.decode(AndroidTextMacroBackup.encode(preview.entries))
        XCTAssertEqual(roundTrip.entries.map(\.name), preview.entries.map(\.name))
        XCTAssertEqual(roundTrip.entries.map(\.reading), preview.entries.map(\.reading))
        XCTAssertEqual(roundTrip.entries.map(\.body), preview.entries.map(\.body))
        XCTAssertEqual(roundTrip.entries.map(\.enabled), preview.entries.map(\.enabled))
    }

    func testAndroidBackupRejectsWhitespaceOnlyNames() throws {
        let source = #"{"version":1,"macros":[{"name":" \n ","reading":null,"body":"Hi","enabled":true}]}"#
        XCTAssertThrowsError(try AndroidTextMacroBackup.decode(Data(source.utf8)))
    }

    func testAndroidImportMergePreservesWhitespaceAndUsesCaseInsensitiveExactNames() throws {
        let source = #"{"version":1,"macros":[{"name":" mail ","reading":" あ ","body":"padded","enabled":true},{"name":"MAIL","reading":"plain","body":"replacement","enabled":false}]}"#
        let preview = try AndroidTextMacroBackup.decode(Data(source.utf8))
        let existing = PersonalTextMacro(name: "mail", reading: "old", body: "original")

        let merged = try AndroidTextMacroBackup.merge(preview, into: [existing])

        XCTAssertEqual(merged.map(\.name), ["MAIL", " mail "])
        XCTAssertEqual(merged[0].id, existing.id)
        XCTAssertEqual(merged[0].reading, "plain")
        XCTAssertEqual(merged[0].body, "replacement")
        XCTAssertEqual(merged[1].reading, " あ ")
        XCTAssertEqual(merged[1].body, "padded")
    }

    func testAndroidImportPreviewUsesUnicodeCaseFoldButApplyUsesSqliteNoCase() throws {
        let source = #"{"version":1,"macros":[{"name":"ä","reading":null,"body":"imported","enabled":true}]}"#
        let existing = PersonalTextMacro(name: "Ä", body: "existing")
        let preview = try AndroidTextMacroBackup.decode(Data(source.utf8), existing: [existing])

        // Android's preview lowercases with Locale.ROOT, but applyImport uses
        // TextMacroDao.getByName with SQLite NOCASE (ASCII-only folding).
        XCTAssertEqual(preview.added, 0)
        XCTAssertEqual(preview.overwritten, 1)
        let merged = try AndroidTextMacroBackup.merge(preview, into: [existing])
        XCTAssertEqual(merged.map(\.name), ["Ä", "ä"])

        var lexicon = PersonalLexicon()
        lexicon.textMacros = merged
        XCTAssertNoThrow(try lexicon.validate())
    }

    func testAndroidSqliteNoCaseStopsAtEmbeddedNull() throws {
        let existing = PersonalTextMacro(name: "a\u{0}x", body: "existing")
        let source = #"{"version":1,"macros":[{"name":"A\u0000y","reading":null,"body":"replacement","enabled":true}]}"#
        let preview = try AndroidTextMacroBackup.decode(Data(source.utf8), existing: [existing])

        XCTAssertEqual(AndroidTextMacroNameComparison.sqliteNoCaseKey(existing.name), [0x61])
        XCTAssertEqual(AndroidTextMacroNameComparison.sqliteNoCaseKey("A\u{0}y"), [0x61])
        // Android's Locale.ROOT preview count sees the suffix after NUL,
        // whereas SQLite lookup used during apply stops at NUL.
        XCTAssertEqual(preview.added, 1)
        XCTAssertEqual(preview.overwritten, 0)

        let merged = try AndroidTextMacroBackup.merge(preview, into: [existing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existing.id)
        XCTAssertEqual(merged[0].name, "A\u{0}y")
        XCTAssertEqual(merged[0].body, "replacement")
    }

    func testAndroidNameComparisonDoesNotUseCanonicalUnicodeEquivalence() throws {
        let precomposed = "é"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertNotEqual(
            AndroidTextMacroNameComparison.sqliteNoCaseKey(precomposed),
            AndroidTextMacroNameComparison.sqliteNoCaseKey(decomposed)
        )
        XCTAssertNotEqual(
            AndroidTextMacroNameComparison.androidRootLowercaseKey(precomposed),
            AndroidTextMacroNameComparison.androidRootLowercaseKey(decomposed)
        )

        let existing = PersonalTextMacro(name: precomposed, body: "existing")
        let source = #"{"version":1,"macros":[{"name":"e\u0301","reading":null,"body":"replacement","enabled":true}]}"#
        let preview = try AndroidTextMacroBackup.decode(Data(source.utf8), existing: [existing])
        XCTAssertEqual(preview.added, 1)
        XCTAssertEqual(preview.overwritten, 0)

        let merged = try AndroidTextMacroBackup.merge(preview, into: [existing])
        XCTAssertEqual(merged.count, 2)
        var lexicon = PersonalLexicon()
        lexicon.textMacros = merged
        XCTAssertNoThrow(try lexicon.validate())

        let duplicateSource = #"{"version":1,"macros":[{"name":"é","reading":null,"body":"one","enabled":true},{"name":"e\u0301","reading":null,"body":"two","enabled":true}]}"#
        XCTAssertNoThrow(try AndroidTextMacroBackup.decode(Data(duplicateSource.utf8)))
    }

    func testLexiconRejectsDuplicateMacroNamesAndInvalidDefinitions() {
        var lexicon = PersonalLexicon()
        lexicon.textMacros = [
            PersonalTextMacro(name: "mail", body: "Hi"),
            PersonalTextMacro(name: "MAIL", body: "There")
        ]
        XCTAssertThrowsError(try lexicon.validate())

        lexicon.textMacros = [PersonalTextMacro(name: "mail", reading: String(repeating: "あ", count: 65), body: "Hi")]
        XCTAssertThrowsError(try lexicon.validate())
        lexicon.textMacros = [PersonalTextMacro(name: "mail", body: "{unknown}")]
        XCTAssertThrowsError(try lexicon.validate())
    }

    func testPersonalLexiconStorePersistsMacrosForReadOnlyExtensionLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        var lexicon = PersonalLexicon()
        lexicon.textMacros = [PersonalTextMacro(name: "signature", reading: "しょめい", body: "Sumire{newline}")]
        let store = PersonalLexiconStore(directory: directory)
        try store.save(lexicon)
        XCTAssertEqual(try PersonalLexiconStore(directory: directory).load().lexicon.textMacros, lexicon.textMacros)
    }
}
