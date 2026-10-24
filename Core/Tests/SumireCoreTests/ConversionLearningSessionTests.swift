import XCTest
@testable import SumireCore

final class ConversionLearningSessionTests: XCTestCase {
    func testSeparatedConversionLearnsSegmentsPrefixesAndCompletePhrase() {
        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: "しうんすみか")
        session.record(fragment("しうん", "紫雲", score: 40_000, index: 2, left: 11, right: 12))
        session.record(fragment("すみ", "清", score: 30_000, index: 1, left: 21, right: 22))
        session.record(fragment("か", "夏", score: 20_000, index: 3, left: 31, right: 32))

        let entries = session.finish(learnFirstCandidate: false, timestamp: 123)

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(entries.filter { !$0.isPhrase }.map(\.input), ["しうん", "すみ", "か"])
        XCTAssertEqual(entries.first, LearningSessionEntry(
            input: "しうん", output: "紫雲", score: 39_000, leftID: 11, rightID: 12,
            lastUsedAt: 123, isPhrase: false
        ))
        XCTAssertTrue(entries.contains {
            $0.input == "しうんすみ" && $0.output == "紫雲清" && $0.score == 34_250 &&
            $0.leftID == 11 && $0.rightID == 22 && $0.isPhrase
        })
        XCTAssertTrue(entries.contains {
            $0.input == "しうんすみか" && $0.output == "紫雲清夏" && $0.isPhrase
        })
        XCTAssertEqual(entries.filter { $0.input == "しうんすみか" && $0.output == "紫雲清夏" }.count, 1)
    }

    func testPartialPredictionRetainsOriginalReadingForCompletedEntry() {
        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: "しうんすみか")
        session.record(fragment("しうん", "紫雲", score: 40_000, index: 1))
        session.record(fragment("すみ", "清", score: 30_000, index: 2))

        let entries = session.finish(learnFirstCandidate: false, timestamp: 456)

        XCTAssertTrue(entries.contains { $0.input == "しうんすみ" && $0.output == "紫雲清" && $0.isPhrase })
        XCTAssertTrue(entries.contains {
            $0.input == "しうんすみか" && $0.output == "紫雲清" && $0.isPhrase
        })
    }

    func testFirstCandidatePreferenceAndExplicitSelection() {
        func finish(learnFirstCandidate: Bool, explicitlySelected: Bool = false) -> [LearningSessionEntry] {
            var session = ConversionLearningSession()
            session.beginIfNeeded(reading: "あ")
            session.record(fragment("あ", "亜", score: 3_000, index: 0, explicitlySelected: explicitlySelected))
            return session.finish(learnFirstCandidate: learnFirstCandidate, timestamp: 1)
        }

        XCTAssertTrue(finish(learnFirstCandidate: false).isEmpty)
        XCTAssertEqual(finish(learnFirstCandidate: true).map(\.output), ["亜"])
        XCTAssertEqual(finish(learnFirstCandidate: false, explicitlySelected: true).map(\.output), ["亜"])
    }

    func testBeginKeepsOriginalReadingAndCancelClearsFragments() {
        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: "あいう")
        session.beginIfNeeded(reading: "い")
        session.record(fragment("あ", "亜", score: 3_000, index: 1))
        session.cancel()
        session.beginIfNeeded(reading: "い")
        session.record(fragment("い", "意", score: 3_000, index: 1))

        XCTAssertEqual(session.finish(learnFirstCandidate: false, timestamp: 2).map(\.input), ["い"])
    }

    func testIgnoresFragmentsWithoutActiveReadingOrText() {
        var session = ConversionLearningSession()
        session.record(fragment("あ", "亜", score: 3_000, index: 1))
        session.beginIfNeeded(reading: "あ")
        session.record(fragment("", "空読み", score: 3_000, index: 1))
        session.record(fragment("あ", "", score: 3_000, index: 1))
        XCTAssertTrue(session.finish(learnFirstCandidate: false, timestamp: 3).isEmpty)
    }

    func testDeduplicationUsesExactUnicodeSpellingLikeKotlinStringKeys() {
        let composed = "が"
        let decomposed = "か\u{3099}"
        XCTAssertEqual(composed, decomposed, "Swift String comparison is canonically equivalent")
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))

        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: "がい")
        session.record(fragment(composed, "我", score: 10_000, index: 1))
        session.record(fragment(decomposed, "我", score: 10_000, index: 1))

        let entries = session.finish(learnFirstCandidate: false, timestamp: 4)
        XCTAssertEqual(entries.filter { $0.output == "我" }.map { Data($0.input.utf8) }, [
            Data(composed.utf8), Data(decomposed.utf8)
        ])
    }

    func testLearningScoreArithmeticMatchesAndroidBoundaries() {
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: 40_000, candidateIndex: 2), 39_000)
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: 40_000, candidateIndex: -2), 40_000)
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: Int32.min, candidateIndex: Int32.max), 0)
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: Int32.max, candidateIndex: 0), Int32.max)
        XCTAssertEqual(LearningScorePolicy.phrase([39_000, 29_000]), 34_000)
        XCTAssertEqual(LearningScorePolicy.phrase([]), 3_000)
        XCTAssertEqual(LearningScorePolicy.reinforce(existingScore: 8_000, incomingScore: 6_000), 4_500)
        XCTAssertEqual(LearningScorePolicy.reinforce(existingScore: 1_000, incomingScore: 6_000), 0)
    }

    private func fragment(
        _ reading: String,
        _ output: String,
        score: Int32,
        index: Int32,
        left: Int16? = nil,
        right: Int16? = nil,
        explicitlySelected: Bool = false
    ) -> LearningFragment {
        LearningFragment(
            reading: reading,
            output: output,
            candidateScore: score,
            candidateIndex: index,
            leftID: left,
            rightID: right,
            explicitlySelected: explicitlySelected
        )
    }
}
