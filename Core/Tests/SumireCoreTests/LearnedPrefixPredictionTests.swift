import XCTest
@testable import SumireCore

final class LearnedPrefixPredictionTests: XCTestCase {
    func testSettingsDefaultsBoundsUTF16AndPortableBackup() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(LearnedPredictionSettings.load(defaults: defaults), .init())
        XCTAssertFalse(LearnedPredictionSettings().allows(reading: "あいうえお"))
        let bounded = LearnedPredictionSettings(enabled: true, minimumInputLength: 0, candidateLimit: 99)
        XCTAssertEqual(bounded.minimumInputLength, 1); XCTAssertEqual(bounded.candidateLimit, 8)
        XCTAssertTrue(LearnedPredictionSettings(enabled: true).allows(reading: "😀あい"))
        XCTAssertFalse(LearnedPredictionSettings(enabled: true).allows(reading: "😀あ"))
        var snapshot = KeyboardSettingsSnapshot()
        snapshot.values = [LearnedPredictionSettings.enabledKey: .boolean(true),
            LearnedPredictionSettings.minimumInputLengthKey: .number(2),
            LearnedPredictionSettings.candidateLimitKey: .number(7)]
        let contents = PersonalBackup.Contents(lexicon: PersonalLexicon(), settings: snapshot)
        XCTAssertEqual(try PersonalBackup.decodeContents(PersonalBackup.encode(contents)), contents)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(LearnedPredictionSettings.load(defaults: defaults), .init(enabled: true, minimumInputLength: 2, candidateLimit: 7))
        snapshot.values[LearnedPredictionSettings.candidateLimitKey] = .number(9)
        XCTAssertThrowsError(try snapshot.validate())
    }
    func testPrefixSQLSelectsExactBeforeLimitThenAndroidOrderingAndLiteralPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LearningStore(url: root.appendingPathComponent("learning.sqlite"))
        try store.upsertLearningEntries([
            .init(input: "あいうえ", output: "完全", score: 9000, leftID: nil, rightID: nil, lastUsedAt: 1, isPhrase: false),
            .init(input: "あいうえお", output: "古い", score: 100, leftID: 12, rightID: 13, lastUsedAt: 1, isPhrase: false),
            .init(input: "あいうえか", output: "新しい", score: 100, leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false),
            .init(input: "あいうえかき", output: "長い", score: 100, leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false),
            .init(input: "あいうえき", output: "後挿入", score: 100, leftID: nil, rightID: nil, lastUsedAt: 2, isPhrase: false)
        ])
        XCTAssertEqual(try store.predictiveCandidates(readingPrefix: "あいうえ", limit: 4).map(\.text), ["完全", "後挿入", "新しい", "長い"])
        XCTAssertEqual(try store.predictiveCandidates(readingPrefix: "あいうえ", limit: 1).map(\.text), ["完全"])
        XCTAssertEqual(try store.candidates(reading: "あいうえ").map(\.text), ["完全"])
        try store.record(reading: "a%_x", text: "記号読み")
        try store.record(reading: "abcx", text: "別")
        XCTAssertEqual(try store.predictiveCandidates(readingPrefix: "a%_").map(\.text), ["記号読み"])
        try store.record(reading: "😀あ", text: "絵文字読み")
        XCTAssertEqual(try store.predictiveCandidates(readingPrefix: "😀").map(\.text), ["絵文字読み"])
        XCTAssertEqual(try store.predictiveCandidates(readingPrefix: ""), [])
        XCTAssertThrowsError(try store.predictiveCandidates(readingPrefix: "あ", limit: 9))
        XCTAssertThrowsError(try store.predictiveCandidates(readingPrefix: "あ\0"))
        XCTAssertEqual(try LearningStore(url: root.appendingPathComponent("learning.sqlite")).predictiveCandidates(readingPrefix: "あいうえ", limit: 1).first?.text, "完全")
    }
}
