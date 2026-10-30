import XCTest
@testable import SumireCore

final class TextMacroCandidateSettingsTests: XCTestCase {
    func testDefaultEnabledAndPortableCandidateTogglePreservesDefinitions() throws {
        let domain = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertTrue(TextMacroCandidateSettings.isEnabled(defaults: defaults))
        var lexicon = PersonalLexicon()
        lexicon.textMacros = [.init(id: "11111111-1111-4111-8111-111111111111", name: "表示名", reading: "よみ", body: "本文", enabled: true)]
        var snapshot = KeyboardSettingsSnapshot()
        snapshot.values[TextMacroCandidateSettings.enabledKey] = .boolean(false)
        let contents = PersonalBackup.Contents(lexicon: lexicon, settings: snapshot)
        let restored = try PersonalBackup.decodeContents(PersonalBackup.encode(contents))
        XCTAssertEqual(restored, contents)
        try XCTUnwrap(restored.settings).restore(defaults: defaults)
        XCTAssertFalse(TextMacroCandidateSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(restored.lexicon.textMacros, lexicon.textMacros)
        XCTAssertEqual(AndroidTextMacroCandidatePolicy.candidates(in: restored.lexicon.textMacros, reading: "よみ", contextAllowed: false).map(\.id), lexicon.textMacros.map(\.id),
                       "Global UI visibility must not mutate the stored enabled definition or compiler policy")
    }
}
