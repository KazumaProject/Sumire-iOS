import XCTest
@testable import SumireCore

final class ConversionLearningSessionTests: XCTestCase {
    func testSeparatedConversionBuildsSegmentAndPhraseRecords() {
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

    func testOrdinaryPrefixCommitsLearnTogetherWhenTheRemainderCompletes() {
        var session = ConversionLearningSession()
        XCTAssertTrue(session.append(
            fragment("とうきょう", "東京", score: 12_000, index: 1, left: 11, right: 12),
            from: "とうきょうに", remainingInput: "に"
        ))
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.append(
            fragment("に", "二", score: 9_000, index: 2, left: 21, right: 22),
            from: "に", remainingInput: ""
        ))

        let entries = session.finish(learnFirstCandidate: false, timestamp: 123)

        XCTAssertFalse(session.isActive)
        XCTAssertTrue(entries.contains {
            $0.input == "とうきょうに" && $0.output == "東京二" &&
                $0.leftID == 11 && $0.rightID == 22 && $0.isPhrase
        })
        XCTAssertTrue(entries.contains { $0.input == "とうきょう" && $0.output == "東京" && !$0.isPhrase })
        XCTAssertTrue(entries.contains { $0.input == "に" && $0.output == "二" && !$0.isPhrase })
    }

    func testEditedRemainderCanBeRejectedBeforeRecordingAnotherFragment() {
        var session = ConversionLearningSession()
        XCTAssertTrue(session.append(
            fragment("とうきょう", "東京", score: 12_000, index: 1),
            from: "とうきょうに", remainingInput: "に"
        ))
        XCTAssertFalse(session.extendExpectedRemainder(to: "ほか"))
        session.cancel()
        XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 123).isEmpty)
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

    func testCancellationDropsIncompleteCompositionAndExactUnicodeKeysStayDistinct() {
        let composed = "が"
        let decomposed = "か\u{3099}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))

        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: "がい")
        session.record(fragment(composed, "我", score: 10_000, index: 1))
        session.record(fragment(decomposed, "我", score: 10_000, index: 1))
        let entries = session.finish(learnFirstCandidate: false, timestamp: 4)
        XCTAssertEqual(entries.filter { $0.output == "我" }.map { Data($0.input.utf8) }, [
            Data(composed.utf8), Data(decomposed.utf8)
        ])

        session.beginIfNeeded(reading: "あ")
        session.record(fragment("あ", "亜", score: 3_000, index: 1))
        session.cancel()
        XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 5).isEmpty)
    }

    func testPhraseFlagUsesAndroidCodeUnitEqualityForCanonicalKanaVariants() {
        let originalReading = "か\u{3099}"
        let committedReading = "が"
        XCTAssertEqual(originalReading, committedReading)
        XCTAssertFalse(originalReading.utf16.elementsEqual(committedReading.utf16))

        var session = ConversionLearningSession()
        session.beginIfNeeded(reading: originalReading)
        session.record(fragment(committedReading, "我", score: 3_000, index: 1))

        let entries = session.finish(learnFirstCandidate: false, timestamp: 9)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].isPhrase)
        XCTAssertEqual(entries[1].input, originalReading)
        XCTAssertTrue(entries[1].isPhrase)
    }

    func testNonFirstRankAndExplicitRankZeroAreEligibleWithoutPreference() {
        for (index, explicit, expected) in [(Int32(0), false, false), (0, true, true), (1, false, true), (-1, false, true)] {
            var session = ConversionLearningSession()
            session.beginIfNeeded(reading: "あ")
            session.record(fragment("あ", "亜", score: 3_000, index: index, explicitlySelected: explicit))
            XCTAssertEqual(!session.finish(learnFirstCandidate: false, timestamp: 1).isEmpty, expected)
        }
    }

    func testStaleAndCanonicallyEquivalentRemaindersCancelBeforeRecording() {
        for actual in ["う", "が"] {
            var session = ConversionLearningSession()
            XCTAssertTrue(session.append(fragment("あ", "亜", score: 3_000, index: 1),
                                         from: "あか\u{3099}", remainingInput: "か\u{3099}"))
            XCTAssertFalse(session.append(fragment(actual, "語", score: 3_000, index: 1),
                                          from: actual, remainingInput: ""))
            XCTAssertFalse(session.isActive)
            XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 1).isEmpty)
        }
    }

    func testAppendedAndRomajiRewrittenRemainderPreservesOriginalSession() {
        var session = ConversionLearningSession()
        XCTAssertTrue(session.append(fragment("あ", "亜", score: 3_000, index: 1), from: "あk", remainingInput: "k"))
        XCTAssertTrue(session.extendExpectedRemainder(to: "ka"))
        XCTAssertTrue(session.adoptAppendedRemainder("か"))
        XCTAssertTrue(session.append(fragment("か", "蚊", score: 3_000, index: 1), from: "か", remainingInput: ""))
        let entries = session.finish(learnFirstCandidate: false, timestamp: 2)
        XCTAssertTrue(entries.contains { $0.input == "あk" && $0.output == "亜蚊" && $0.isPhrase })
        XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 3).isEmpty)
    }

    func testEmptyFragmentsAndInvalidAppendCannotLeakPriorSession() {
        var session = ConversionLearningSession()
        session.record(fragment("あ", "亜", score: 3_000, index: 1))
        XCTAssertFalse(session.isActive)
        session.beginIfNeeded(reading: "あ")
        session.record(fragment("", "亜", score: 3_000, index: 1))
        session.record(fragment("あ", "", score: 3_000, index: 1))
        XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 1).isEmpty)
        XCTAssertTrue(session.append(fragment("あ", "亜", score: 3_000, index: 1), from: "あい", remainingInput: "い"))
        XCTAssertFalse(session.append([], from: "い", remainingInput: ""))
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.finish(learnFirstCandidate: true, timestamp: 2).isEmpty)
    }

    func testAndroidScoreArithmeticClampsAndTruncates() {
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: Int32.min, candidateIndex: Int32.min), 0)
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: Int32.max, candidateIndex: Int32.max), 0)
        XCTAssertEqual(LearningScorePolicy.initial(candidateScore: 3_000, candidateIndex: -1), 3_000)
        XCTAssertEqual(LearningScorePolicy.phrase([]), 3_000)
        XCTAssertEqual(LearningScorePolicy.phrase([1, 2]), 1)
        XCTAssertEqual(LearningScorePolicy.reinforce(existingScore: 3_000, incomingScore: 2_000), 500)
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

