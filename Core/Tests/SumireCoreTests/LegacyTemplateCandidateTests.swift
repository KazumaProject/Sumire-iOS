import XCTest
@testable import SumireCore

final class LegacyTemplateCandidateTests: XCTestCase {
    private func row(_ id: Int, score: Int? = nil) -> PersonalWord {
        var result = PersonalWord(word: "本文\(id)", reading: "よみ", posScore: score ?? id * 100)
        result.id = Int64(id); return result
    }
    func testLatestEightSelectedBeforeStableScoreAndNoPrefixExpansion() throws {
        let rows = (1...9).map { row($0) }
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: rows, reading: "よみ").map(\.id), (2...9).map { Int64($0) })
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: (1...9).map { row($0, score: 300) }, reading: "よみ").map(\.id), (2...9).reversed().map { Int64($0) })
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: rows, reading: "よ"), [])
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: rows, reading: "よみあ"), [])
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: rows, reading: "よみ", enabled: false), [])
        var composed = row(1), decomposed = row(2)
        composed.reading = "が"; decomposed.reading = "か\u{3099}"
        XCTAssertEqual(try LegacyTemplateCandidatePolicy.candidates(in: [composed,decomposed], reading: "か\u{3099}").map(\.id), [2])
    }
    func testPortableNilIDsKeepStableSourceTieWithoutInventingIDs() throws {
        var first = row(1, score: 300), second = row(2, score: 300)
        first.id = nil; second.id = nil
        let result = try LegacyTemplateCandidatePolicy.candidates(in: [first,row(3, score: 300),second], reading: "よみ")
        XCTAssertEqual(result.map(\.word), ["本文3", "本文1", "本文2"])
        XCTAssertEqual(result.map(\.id), [3,nil,nil])
    }
    func testDefaultEnabledAndPortableSettingRoundTrip() throws {
        let domain = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertTrue(LegacyTemplateSettings.isEnabled(defaults: defaults))
        var snapshot = KeyboardSettingsSnapshot()
        snapshot.values[LegacyTemplateSettings.enabledKey] = .boolean(false)
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), settings: snapshot)
        XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(contents)), contents)
        try snapshot.restore(defaults: defaults)
        XCTAssertFalse(LegacyTemplateSettings.isEnabled(defaults: defaults))
    }
}
