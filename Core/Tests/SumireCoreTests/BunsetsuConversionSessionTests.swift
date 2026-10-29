import XCTest
@testable import SumireCore

final class BunsetsuConversionSessionTests: XCTestCase {
    private let reading = "あ😀い"
    private var nextConversionRequestGeneration: UInt64 = 1_000

    func testSplitPatternFocusTieMatchesAndroidDescendingNegativeDistanceComparator() throws {
        let input = "abcdef"
        var session = try BunsetsuConversionSession(
            rawInput: input, conversionInput: input, wholeDisplayText: input,
            generation: 1, splitPatterns: [
                try BunsetsuSplitPattern(reading: input, boundaries: [1, 5]),
                try BunsetsuSplitPattern(reading: input, boundaries: [3])
            ])
        XCTAssertTrue(session.moveFocus(by: 1)) // [1, 5)
        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        // Both [0, 3) and [3, 6) overlap by 2. Android's maxWith(compareBy
        // overlap.thenByDescending(-distance)) selects the larger distance.
        XCTAssertEqual(session.focusedSegmentIndex, 1)
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 3, length: 3))
    }

    func testOwnedSnapshotSessionConnectsUTF16SplitsFreshLoadsAndPrefixCommit() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "亜顔伊", readingUTF16Length: 4)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 7, reading: "あ😀い", splitPatterns: [[], [2]],
            primarySplitPositions: [1, 3], candidates: [
                .init(nativeIndex: 0, candidateID: 9, score: 1, identity: identity,
                      tokenPath: [
                          .init(readingRange: NSRange(location: 0, length: 1), text: "亜"),
                          .init(readingRange: NSRange(location: 1, length: 2), text: "顔"),
                          .init(readingRange: NSRange(location: 3, length: 1), text: "伊")
                      ], mappedSplitPositions: [1, 3])
            ])
        var session = try BunsetsuConversionSession(
            rawInput: "あ😀いz", conversionInput: "あ😀い", tailText: "z",
            wholeDisplayText: "亜顔伊", generation: 7, snapshot: snapshot,
            orderedDisplayCandidates: [identity])
        XCTAssertEqual(session.splitPatterns.map(\.boundaries), [[1, 3], []])
        XCTAssertEqual(session.commitText, "亜顔伊")
        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 1, length: 2))
        let old = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: 40))
        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertFalse(session.installCandidates([], responseReading: "😀", responseGeneration: 40, for: old))
        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertTrue(session.moveFocus(by: 1))
        let wrong = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: 41))
        XCTAssertFalse(session.installCandidates([], responseReading: "あ", responseGeneration: 41, for: wrong))
        let current = try XCTUnwrap(session.beginLoadingFocusedCandidates(conversionRequestGeneration: 42))
        XCTAssertTrue(session.installCandidates([
            .init(text: "笑顔", reference: .conversionResult(generation: 42, candidateID: 8))
        ], responseReading: "😀", responseGeneration: 42, for: current))
        XCTAssertTrue(session.selectFocusedCandidate(at: 1))
        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.committedText, "亜笑顔")
        XCTAssertEqual(plan.committedReading, "あ😀")
        XCTAssertEqual(plan.readingUTF16Length, 3)
        XCTAssertEqual(plan.remainingConversionInput, "い")
        XCTAssertEqual(plan.nextComposingInput, "いz")
        XCTAssertEqual(plan.nextTailText, "z")
        XCTAssertEqual(plan.learningReading, "あ😀いz")
        XCTAssertEqual(plan.selectedCandidates.last?.reference.candidateID, 8)
    }

    func testOwnedSnapshotSessionRejectsStaleGenerationAndSameLengthDifferentReading() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 7, reading: "あ😀い", splitPatterns: [],
            primarySplitPositions: [], candidates: [])
        for (input, generation, expected) in [
            ("あ😀い", UInt64(8), BunsetsuConversionSnapshotError.generationMismatch),
            ("い😀あ", UInt64(7), .readingIdentityMismatch)
        ] {
            XCTAssertThrowsError(try BunsetsuConversionSession(
                rawInput: input, conversionInput: input, wholeDisplayText: input,
                generation: generation, snapshot: snapshot, orderedDisplayCandidates: [])) {
                XCTAssertEqual($0 as? BunsetsuConversionSnapshotError, expected)
            }
        }
    }

    func testFocusClampsAtBothEndsAndUsesUTF16ReadingRanges() throws {
        var session = try makeSession()

        XCTAssertFalse(session.moveFocus(by: -1))
        XCTAssertEqual(session.focusedSegmentIndex, 0)
        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 1, length: 3))
        XCTAssertFalse(session.moveFocus(by: 1))
        XCTAssertEqual(session.focusedSegmentIndex, 1)

        XCTAssertTrue(session.moveFocus(by: Int.min))
        XCTAssertEqual(session.focusedSegmentIndex, 0)
        XCTAssertTrue(session.moveFocus(by: Int.max))
        XCTAssertEqual(session.focusedSegmentIndex, 1)
    }

    func testSplitPatternCyclingWrapsAndTransfersFocusByReadingOverlap() throws {
        var session = try makeSession()
        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 1, length: 3))

        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertEqual(session.activeSplitPatternIndex, 1)
        // The old [1, 4) range overlaps [0, 3) by two UTF-16 units and
        // [3, 4) by one, so focus moves to the first segment of pattern 2.
        XCTAssertEqual(session.focusedSegmentIndex, 0)
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 0, length: 3))

        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertEqual(session.activeSplitPatternIndex, 0)
        XCTAssertEqual(session.focusedSegmentIndex, 1)

        XCTAssertTrue(session.cycleSplitPattern(by: -1))
        XCTAssertEqual(session.activeSplitPatternIndex, 1)
        XCTAssertFalse(session.cycleSplitPattern(by: 2))
    }

    func testSplittingWholeReadingFocusesFirstSegmentLikeAndroid() throws {
        let surfaces = ["亜", "絵", "衣"]
        let wholePattern = try makePattern(boundaries: [], surfaces: surfaces)
        let splitPattern = try makePattern(boundaries: [1], surfaces: surfaces)
        var session = try makeSession(patterns: [wholePattern, splitPattern])

        XCTAssertEqual(session.segments.count, 1)
        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertEqual(session.activeSplitPatternIndex, 1)
        XCTAssertEqual(session.focusedSegmentIndex, 0)
        XCTAssertEqual(session.focusedReadingRange, NSRange(location: 0, length: 1))
    }

    func testUnprojectableSegmentsKeepReadingUntilLocalCandidatesLoad() throws {
        let conversionInput = "あいうえ"
        let pattern = try BunsetsuSplitPattern(
            reading: conversionInput,
            boundaries: [1, 2],
            candidatePaths: [BunsetsuCandidatePath(
                reading: conversionInput,
                candidate: "亜衣",
                tokens: [
                    BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "亜"),
                    BunsetsuToken(readingRange: NSRange(location: 2, length: 2), text: "衣")
                ]
            )]
        )
        var session = try BunsetsuConversionSession(
            rawInput: conversionInput,
            conversionInput: conversionInput,
            wholeDisplayText: "全体候補",
            generation: 7,
            splitPatterns: [pattern]
        )

        XCTAssertEqual(session.segments.map(\.displayText), ["あ", "い", "衣"])
        XCTAssertEqual(session.segments.map(\.hasConvertedDisplay), [false, false, true])
        XCTAssertEqual(session.candidatePreparationSegmentIndices, [0, 1])
        XCTAssertEqual(session.focusedCandidateBarTexts, ["あ"])

        let firstLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["阿", "亜"], in: &session, for: firstLoad))
        XCTAssertEqual(session.segments[0].displayText, "阿")
        XCTAssertEqual(session.segments[0].candidates, ["阿", "亜"])
        XCTAssertEqual(session.segments.map(\.hasConvertedDisplay), [true, false, true])
        XCTAssertEqual(session.candidatePreparationSegmentIndices, [0, 1])

        let emptyLoad = try XCTUnwrap(beginSegmentLoad(in: &session, at: 1))
        XCTAssertTrue(installCandidateTexts([], in: &session, for: emptyLoad))
        XCTAssertEqual(session.focusedSegmentIndex, 0)
        XCTAssertEqual(session.segments[1].displayText, "い")
        XCTAssertEqual(session.segments[1].candidates, ["い"])
        XCTAssertEqual(session.segments.map(\.hasConvertedDisplay), [true, true, true])
        XCTAssertEqual(session.candidatePreparationSegmentIndices, [0])
    }

    func testMissingWholePathCreatesReadingSegmentsAndPreservesEmptyLocalFallback() throws {
        let conversionInput = "あいうえ"
        let pattern = try BunsetsuSplitPattern(
            reading: conversionInput,
            boundaries: [1, 3],
            candidatePaths: []
        )
        var session = try BunsetsuConversionSession(
            rawInput: conversionInput,
            conversionInput: conversionInput,
            wholeDisplayText: "",
            generation: 9,
            splitPatterns: [pattern]
        )

        XCTAssertNil(pattern.sourceCandidate)
        XCTAssertEqual(session.segments.map(\.reading), ["あ", "いう", "え"])
        XCTAssertEqual(session.segments.map(\.displayText), ["あ", "いう", "え"])
        XCTAssertTrue(session.segments.allSatisfy { !$0.hasConvertedDisplay })
        XCTAssertEqual(session.candidatePreparationSegmentIndices, [0, 1, 2])
        XCTAssertEqual(session.focusedCandidateBarTexts, ["あ"])
        XCTAssertNil(session.leadingSegmentCommitPlan())
        XCTAssertNil(session.focusedPrefixCommitPlan())

        let focusedLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["阿"], in: &session, for: focusedLoad))
        XCTAssertEqual(session.segments[0].displayText, "阿")
        XCTAssertEqual(session.segments[0].candidates, ["阿"])
        XCTAssertNotNil(session.leadingSegmentCommitPlan())
        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertNil(session.focusedPrefixCommitPlan(), "A reading-only segment cannot be committed before local candidates load")

        let emptyLocalLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts([], in: &session, for: emptyLocalLoad))
        XCTAssertEqual(session.segments[1].displayText, "いう")
        XCTAssertEqual(session.segments[1].candidates, ["いう"])
        XCTAssertTrue(session.segments[1].hasConvertedDisplay)
        XCTAssertNotNil(session.focusedPrefixCommitPlan())
        XCTAssertEqual(session.candidatePreparationSegmentIndices, [1, 2])
    }

    func testSessionRetainsUTF16SplitInsideCombiningGrapheme() throws {
        let decomposedReading = "か\u{3099}き"
        let pattern = try BunsetsuSplitPattern(
            reading: decomposedReading,
            boundaries: [1],
            candidatePaths: []
        )
        let session = try BunsetsuConversionSession(
            rawInput: decomposedReading,
            conversionInput: decomposedReading,
            wholeDisplayText: decomposedReading,
            generation: 11,
            splitPatterns: [pattern]
        )

        XCTAssertEqual(pattern.boundaries, [1])
        XCTAssertEqual(session.segments.map(\.reading), ["か", "\u{3099}き"])
        XCTAssertEqual(session.segments.map(\.reading).joined(), decomposedReading)
        XCTAssertEqual(session.commitText, decomposedReading)
        XCTAssertEqual(session.cancellationInput, decomposedReading)
    }

    func testSplitPatternFactoryProjectsOneBoundaryCompatibleCandidatePath() throws {
        let conversionInput = "あいうえ"
        let firstCandidatePath = BunsetsuCandidatePath(
            reading: conversionInput,
            candidate: "明後日",
            tokens: [BunsetsuToken(readingRange: NSRange(location: 0, length: 4), text: "明後日")]
        )
        let compatibleCandidatePath = BunsetsuCandidatePath(
            reading: conversionInput,
            candidate: "明日",
            tokens: [
                BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "明"),
                BunsetsuToken(readingRange: NSRange(location: 2, length: 2), text: "日")
            ]
        )

        let pattern = try BunsetsuSplitPattern(
            reading: conversionInput,
            boundaries: [2],
            candidatePaths: [firstCandidatePath, compatibleCandidatePath]
        )

        XCTAssertEqual(pattern.sourceCandidate, "明日")
        XCTAssertEqual(pattern.segments.map(\.text), ["明", "日"])
        XCTAssertTrue(pattern.segments.allSatisfy(\.hasConvertedDisplay))
    }

    func testSplitPatternNormalizesPositionsLikeAndroidBeforeProjection() throws {
        let pattern = try BunsetsuSplitPattern(
            reading: "あいうえ",
            boundaries: [3, 1, 1, -1, 99],
            candidatePaths: []
        )

        XCTAssertEqual(pattern.boundaries, [1, 3])
        XCTAssertEqual(pattern.segments.map(\.reading), ["あ", "いう", "え"])
        XCTAssertTrue(pattern.segments.allSatisfy { !$0.hasConvertedDisplay })
    }

    func testEligibleWholeCandidateIsUsedOnlyForSingleIntervalPatterns() throws {
        let conversionInput = "あいうえ"
        let unsplit = try BunsetsuSplitPattern(reading: conversionInput, boundaries: [])
        let split = try BunsetsuSplitPattern(reading: conversionInput, boundaries: [2])
        var session = try BunsetsuConversionSession(
            rawInput: conversionInput,
            conversionInput: conversionInput,
            wholeDisplayText: "一括候補",
            generation: 10,
            splitPatterns: [unsplit, split],
            eligibleWholeCandidateDisplayText: "一括候補"
        )

        XCTAssertEqual(session.commitText, "一括候補")
        XCTAssertEqual(session.displayText, "一括候補")
        XCTAssertTrue(session.segments[0].hasConvertedDisplay)

        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertEqual(session.commitText, conversionInput)
        XCTAssertEqual(session.segments.map(\.displayText), ["あい", "うえ"])
        XCTAssertTrue(session.segments.allSatisfy { !$0.hasConvertedDisplay })

        XCTAssertTrue(session.cycleSplitPattern(by: -1))
        XCTAssertEqual(session.commitText, "一括候補")
        XCTAssertTrue(session.segments[0].hasConvertedDisplay)
    }

    func testWholeResultStaysFirstAndCommitTailAndCancellationArePreserved() throws {
        let session = try makeSession(tail: "x", wholeDisplay: "全体候補")

        XCTAssertEqual(session.focusedCandidateBarTexts, ["亜"])
        XCTAssertEqual(session.commitText, "亜絵衣")
        XCTAssertEqual(session.displayText, "亜絵衣x")
        XCTAssertEqual(session.cancellationInput, reading + "x")
    }

    func testLeadingSegmentCommitPlanPreservesRemainderTailAndLearningReading() throws {
        let session = try makeSession(tail: "z", wholeDisplay: "全体候補")

        let plan = try XCTUnwrap(session.leadingSegmentCommitPlan())
        XCTAssertEqual(plan.text, "亜")
        XCTAssertEqual(plan.committedReading, "あ")
        XCTAssertEqual(plan.readingUTF16Length, 1)
        XCTAssertEqual(plan.remainingConversionInput, "😀い")
        XCTAssertEqual(plan.remainingRawInput, "😀いz")
        XCTAssertEqual(plan.learningReading, "あ😀いz")
        XCTAssertTrue(plan.learningSessionContinues)
    }

    func testLeadingSegmentCommitPlanUsesWholeCandidateForUnsplitPattern() throws {
        let pattern = try makePattern(boundaries: [], surfaces: ["亜", "絵", "衣"])
        let session = try makeSession(
            patterns: [pattern],
            eligibleWholeDisplay: "一括候補"
        )

        let plan = try XCTUnwrap(session.leadingSegmentCommitPlan())
        XCTAssertEqual(plan.text, "一括候補")
        XCTAssertEqual(plan.committedReading, reading)
        XCTAssertEqual(plan.readingUTF16Length, reading.utf16.count)
        XCTAssertEqual(plan.remainingConversionInput, "")
        XCTAssertEqual(plan.remainingRawInput, "")
        XCTAssertEqual(plan.learningReading, reading)
        XCTAssertFalse(plan.learningSessionContinues)
    }

    func testLeadingSegmentCommitPlanRejectsAFocusedNonleadingSegment() throws {
        var session = try makeSession()
        XCTAssertTrue(session.moveFocus(by: 1))

        XCTAssertNil(session.leadingSegmentCommitPlan())
    }

    func testTypedCandidatesRetainRequestReferenceAndLearningIdentityWithExactUnicodeOrdering() throws {
        let reading = "あ"
        let composed = "é"
        let decomposed = "e\u{301}"
        let pattern = try BunsetsuSplitPattern(
            reading: reading,
            boundaries: [],
            candidatePaths: [BunsetsuCandidatePath(
                reading: reading,
                candidate: composed,
                tokens: [BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: composed)]
            )]
        )
        var session = try BunsetsuConversionSession(
            rawInput: reading,
            conversionInput: reading,
            wholeDisplayText: composed,
            generation: 88,
            splitPatterns: [pattern]
        )
        let token = try XCTUnwrap(beginFocusedLoad(in: &session, conversionRequestGeneration: 90))
        let localCandidates = [
            BunsetsuSessionCandidate(
                text: decomposed,
                reference: .conversionResult(generation: 90, candidateID: 901),
                score: 700,
                leftID: 11,
                rightID: 12
            ),
            BunsetsuSessionCandidate(
                text: composed,
                reference: .conversionResult(generation: 90, candidateID: 902),
                score: 900,
                leftID: 13,
                rightID: 14
            )
        ]

        XCTAssertTrue(session.installCandidates(
            localCandidates,
            responseReading: reading,
            responseGeneration: 90,
            for: token
        ))
        let records = try XCTUnwrap(session.focusedSegment?.candidateRecords)
        XCTAssertEqual(records.map { Array($0.text.utf16) }, [Array(composed.utf16), Array(decomposed.utf16)])
        XCTAssertEqual(records.map(\.candidateIndex), [0, 1])
        XCTAssertEqual(records.map(\.reference.candidateID), [902, 901])

        XCTAssertFalse(session.selectFocusedCandidate(at: 2))
        XCTAssertTrue(session.selectFocusedCandidate(at: 1))
        XCTAssertFalse(session.selectFocusedCandidate(at: 1))
        let plan = try XCTUnwrap(session.leadingSegmentCommitPlan())
        XCTAssertEqual(plan.selectedCandidate.reference.conversionGeneration, 90)
        XCTAssertEqual(plan.selectedCandidate.reference.candidateID, 901)
        XCTAssertEqual(plan.learningFragment.reading, reading)
        XCTAssertEqual(plan.learningFragment.output, decomposed)
        XCTAssertEqual(plan.learningFragment.candidateScore, 700)
        XCTAssertEqual(plan.learningFragment.candidateIndex, 1)
        XCTAssertEqual(plan.learningFragment.leftID, 11)
        XCTAssertEqual(plan.learningFragment.rightID, 12)
    }

    func testCandidateLoadRejectsReusedSessionTokensAndMismatchedResponseIdentity() throws {
        var firstSession = try makeSession()
        let staleToken = try XCTUnwrap(beginFocusedLoad(in: &firstSession))

        var replacementSession = try makeSession()
        let currentToken = try XCTUnwrap(beginFocusedLoad(in: &replacementSession))
        XCTAssertEqual(staleToken.sessionGeneration, currentToken.sessionGeneration)
        XCTAssertNotEqual(staleToken.sessionID, currentToken.sessionID)
        XCTAssertFalse(replacementSession.installCandidates(
            [BunsetsuSessionCandidate(
                text: "古い候補",
                reference: .conversionResult(generation: currentToken.conversionRequestGeneration, candidateID: 701)
            )],
            responseReading: reading,
            responseGeneration: currentToken.conversionRequestGeneration,
            for: staleToken
        ))
        XCTAssertTrue(replacementSession.segments[0].isLoadingCandidates)
        XCTAssertTrue(replacementSession.installCandidates(
            [BunsetsuSessionCandidate(
                text: "新しい候補",
                reference: .conversionResult(generation: currentToken.conversionRequestGeneration, candidateID: 702)
            )],
            responseReading: currentToken.segmentReading,
            responseGeneration: currentToken.conversionRequestGeneration,
            for: currentToken
        ))

        let decomposed = "か\u{3099}"
        let composed = "が"
        XCTAssertEqual(decomposed, composed)
        let pattern = try BunsetsuSplitPattern(reading: decomposed, boundaries: [])
        var responseSession = try BunsetsuConversionSession(
            rawInput: decomposed,
            conversionInput: decomposed,
            wholeDisplayText: decomposed,
            generation: 93,
            splitPatterns: [pattern]
        )
        let readingToken = try XCTUnwrap(beginFocusedLoad(in: &responseSession, conversionRequestGeneration: 94))
        let candidate = BunsetsuSessionCandidate(
            text: "仮名",
            reference: .conversionResult(generation: 94, candidateID: 940)
        )
        XCTAssertFalse(responseSession.installCandidates(
            [candidate],
            responseReading: composed,
            responseGeneration: 94,
            for: readingToken
        ))
        XCTAssertFalse(responseSession.segments[0].isLoadingCandidates)

        let retryToken = try XCTUnwrap(beginFocusedLoad(in: &responseSession, conversionRequestGeneration: 95))
        XCTAssertFalse(responseSession.installCandidates(
            [candidate],
            responseReading: decomposed,
            responseGeneration: 95,
            for: retryToken
        ))
        XCTAssertFalse(responseSession.segments[0].isLoadingCandidates)

        let emptyRetryToken = try XCTUnwrap(beginFocusedLoad(
            in: &responseSession,
            conversionRequestGeneration: 96
        ))
        XCTAssertFalse(responseSession.installCandidates(
            [],
            responseReading: decomposed,
            responseGeneration: 97,
            for: emptyRetryToken
        ))
        XCTAssertFalse(responseSession.segments[0].isLoadingCandidates)
    }

    func testLearnedPredictionReferenceRetainsStoredReadingButLearningUsesEachSegmentReading() throws {
        var session = try makeSession()
        let token = try XCTUnwrap(beginFocusedLoad(in: &session, conversionRequestGeneration: 96))
        let candidate = BunsetsuSessionCandidate(
            text: "学習候補",
            reference: .learnedPrediction(generation: 96, candidateID: 960, reading: "学習読み"),
            score: 650,
            leftID: 31,
            rightID: 32
        )

        XCTAssertTrue(session.installCandidates(
            [candidate],
            responseReading: "あ",
            responseGeneration: 96,
            for: token
        ))
        XCTAssertTrue(session.cycleFocusedCandidate(by: 1))
        let plan = try XCTUnwrap(session.leadingSegmentCommitPlan())
        XCTAssertEqual(plan.selectedCandidate.reference.candidateID, 960)
        XCTAssertEqual(plan.selectedCandidate.reference.learnedPredictionReading, "学習読み")
        XCTAssertEqual(plan.selectedCandidate.reference.conversionGeneration, 96)
        XCTAssertEqual(plan.learningFragment.reading, "あ")
        let focusedFirst = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(focusedFirst.learningFragments.map(\.reading), ["あ"])
        XCTAssertEqual(focusedFirst.selectedCandidates.first?.reference.learnedPredictionReading, "学習読み")
        XCTAssertEqual(plan.learningFragment.output, "学習候補")
        XCTAssertEqual(plan.learningFragment.leftID, 31)
        XCTAssertEqual(plan.learningFragment.rightID, 32)

        XCTAssertTrue(session.moveFocus(by: 1))
        let next = try XCTUnwrap(beginFocusedLoad(in: &session, conversionRequestGeneration: 97))
        XCTAssertTrue(session.installCandidates([
            .init(text: "後続", reference: .learnedPrediction(
                generation: 97, candidateID: 970, reading: "別の保存読み"))
        ], responseReading: "😀い", responseGeneration: 97, for: next))
        XCTAssertTrue(session.cycleFocusedCandidate(by: 1))
        let prefix = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(prefix.learningFragments.map(\.reading), ["あ", "😀い"])
        XCTAssertEqual(prefix.learningFragments.map(\.output), ["学習候補", "後続"])
        XCTAssertEqual(prefix.selectedCandidates.map(\.reference.candidateID), [960, 970])
        XCTAssertEqual(prefix.selectedCandidates.map(\.reference.conversionGeneration), [96, 97])
        XCTAssertEqual(prefix.selectedCandidates.map(\.reference.learnedPredictionReading), ["学習読み", "別の保存読み"])
    }

    func testFocusedPrefixCommitPlanMatchesAndroidCommitThroughFocusAndRetainsLearningContext() throws {
        let conversionInput = "あいうえ"
        let pattern = try BunsetsuSplitPattern(reading: conversionInput, boundaries: [1, 2, 3])
        var session = try BunsetsuConversionSession(
            rawInput: conversionInput + "z",
            conversionInput: conversionInput,
            tailText: "z",
            wholeDisplayText: "全体候補",
            generation: 92,
            splitPatterns: [pattern]
        )
        let outputs = ["亜", "伊", "宇"]
        for (index, output) in outputs.enumerated() {
            let token = try XCTUnwrap(beginSegmentLoad(
                in: &session,
                at: index,
                conversionRequestGeneration: UInt64(100 + index)
            ))
            let candidate = BunsetsuSessionCandidate(
                text: output,
                reference: .conversionResult(generation: UInt64(100 + index), candidateID: UInt64(200 + index)),
                score: Int64(800 + index),
                leftID: Int16(10 + index),
                rightID: Int16(20 + index),
                explicitlySelected: index == 1
            )
            XCTAssertTrue(session.installCandidates(
                [candidate],
                responseReading: session.segments[index].reading,
                responseGeneration: UInt64(100 + index),
                for: token
            ))
        }
        XCTAssertTrue(session.moveFocus(by: 2))

        let plan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(plan.committedText, "亜伊宇")
        XCTAssertEqual(plan.committedReading, "あいう")
        XCTAssertEqual(plan.readingUTF16Length, 3)
        XCTAssertEqual(plan.remainingConversionInput, "え")
        XCTAssertEqual(plan.nextComposingInput, "えz")
        XCTAssertEqual(plan.nextTailText, "z")
        XCTAssertEqual(plan.learningReading, "あいうえz")
        XCTAssertTrue(plan.learningSessionContinues)
        XCTAssertEqual(plan.selectedCandidates.map(\.reference.candidateID), [200, 201, 202])
        XCTAssertEqual(plan.learningFragments.map(\.reading), ["あ", "い", "う"])
        XCTAssertEqual(plan.learningFragments.map(\.output), outputs)
        XCTAssertEqual(plan.learningFragments.map(\.candidateIndex), [0, 0, 0])
        XCTAssertEqual(plan.learningFragments.map(\.explicitlySelected), [false, true, false])
    }

    func testLeadingSegmentCommitPlanPreservesScalarInteriorSplitRemainder() throws {
        let decomposed = "か\u{3099}き"
        let pattern = try BunsetsuSplitPattern(reading: decomposed, boundaries: [1])
        var session = try BunsetsuConversionSession(
            rawInput: decomposed,
            conversionInput: decomposed,
            wholeDisplayText: decomposed,
            generation: 12,
            splitPatterns: [pattern]
        )

        XCTAssertNil(session.leadingSegmentCommitPlan())
        let token = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts([], in: &session, for: token))
        let plan = try XCTUnwrap(session.leadingSegmentCommitPlan())
        XCTAssertEqual(plan.text, "か")
        XCTAssertEqual(plan.committedReading, "か")
        XCTAssertEqual(plan.readingUTF16Length, 1)
        XCTAssertEqual(plan.remainingConversionInput, "\u{3099}き")
        XCTAssertEqual(plan.remainingRawInput, "\u{3099}き")
        XCTAssertTrue(plan.learningSessionContinues)
    }

    func testFocusedCandidatesLoadDeduplicateAndCycleWithWrap() throws {
        var session = try makeSession()

        XCTAssertFalse(session.cycleFocusedCandidate(by: 1))
        let token = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(session.segments[0].isLoadingCandidates)
        XCTAssertNil(beginFocusedLoad(in: &session))

        XCTAssertTrue(installCandidateTexts(["", "亜", "阿", "阿"], in: &session, for: token))
        XCTAssertEqual(session.segments[0].candidates, ["亜", "阿"])
        XCTAssertTrue(session.segments[0].candidatesLoaded)
        XCTAssertFalse(session.segments[0].isLoadingCandidates)
        XCTAssertEqual(session.focusedCandidateBarTexts, ["亜", "阿"])

        XCTAssertTrue(session.cycleFocusedCandidate(by: -1))
        XCTAssertEqual(session.segments[0].displayText, "阿")
        XCTAssertTrue(session.cycleFocusedCandidate(by: 1))
        XCTAssertEqual(session.segments[0].displayText, "亜")
        XCTAssertFalse(installCandidateTexts(["stale"], in: &session, for: token))
    }

    func testCandidateBarFallbackCannotBeSelectedBeforeLocalCandidatesLoad() throws {
        var session = try makeSession()
        XCTAssertFalse(try XCTUnwrap(session.focusedSegment).candidatesLoaded)
        let fallbackItem = try XCTUnwrap(session.focusedCandidateBarItems.first)
        XCTAssertEqual(fallbackItem.text, "亜")
        let initialRevision = session.revision

        XCTAssertEqual(session.selectFocusedCandidateBarItem(fallbackItem), .stale)
        XCTAssertEqual(session.revision, initialRevision)
        XCTAssertEqual(session.focusedSegment?.displayText, "亜")
        XCTAssertFalse(try XCTUnwrap(session.focusedSegment).candidatesLoaded)

        let load = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["亜", "阿"], in: &session, for: load))
        XCTAssertEqual(session.selectFocusedCandidateBarItem(fallbackItem), .stale)
    }

    func testLocalCandidateLoadPreservesZenzOverrideAndSelectionIsBlockedBeforeLoad() throws {
        var session = try makeSession()
        let zenzToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 3_100))
        let result = BunsetsuSessionCandidate(
            text: "禅候補",
            reference: .zenzLiveResult(generation: 3_100, candidateID: 310),
            commitText: "禅候補",
            matchedReadingUTF16Length: 1
        )
        XCTAssertTrue(session.installZenzLiveResult(
            result,
            responseReading: "あ",
            responseGeneration: 3_100,
            for: zenzToken
        ))
        let resultItem = try XCTUnwrap(session.focusedCandidateBarItems.first)
        XCTAssertEqual(session.selectFocusedCandidateBarItem(resultItem), .zenzResultSelected)
        XCTAssertFalse(try XCTUnwrap(session.focusedSegment).candidatesLoaded)

        XCTAssertFalse(session.selectFocusedCandidate(at: 0))
        XCTAssertEqual(session.focusedSegment?.displayText, "禅候補")

        let localLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["亜", "阿"], in: &session, for: localLoad))
        XCTAssertTrue(try XCTUnwrap(session.focusedSegment).candidatesLoaded)
        XCTAssertEqual(session.focusedSegment?.candidates, ["亜", "阿"])
        XCTAssertEqual(session.focusedSegment?.displayText, "禅候補")
        XCTAssertEqual(session.focusedCandidateBarTexts, ["禅候補", "亜", "阿"])
        XCTAssertEqual(
            session.focusedSegment?.selectedCandidate?.reference,
            .zenzLiveResult(generation: 3_100, candidateID: 310)
        )
    }

    func testSessionInputAndPatternIdentityUseExactUTF16CodeUnits() throws {
        let composed = "\u{00C5}"
        let canonicallyEquivalent = "\u{212B}"
        XCTAssertEqual(composed, canonicallyEquivalent)
        XCTAssertNotEqual(Array(composed.utf16), Array(canonicallyEquivalent.utf16))

        let patternForCanonicalSpelling = try BunsetsuSplitPattern(
            reading: canonicallyEquivalent,
            boundaries: [],
            candidatePaths: []
        )
        XCTAssertThrowsError(try BunsetsuConversionSession(
            rawInput: composed,
            conversionInput: canonicallyEquivalent,
            wholeDisplayText: "表示",
            generation: 1,
            splitPatterns: [patternForCanonicalSpelling]
        )) { error in
            XCTAssertEqual(
                error as? BunsetsuConversionSessionError,
                .rawInputDoesNotMatchConversionAndTail
            )
        }

        let patternForComposedSpelling = try BunsetsuSplitPattern(
            reading: canonicallyEquivalent,
            boundaries: [],
            candidatePaths: []
        )
        XCTAssertThrowsError(try BunsetsuConversionSession(
            rawInput: composed,
            conversionInput: composed,
            wholeDisplayText: "表示",
            generation: 2,
            splitPatterns: [patternForComposedSpelling]
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSessionError, .invalidPattern)
        }
    }

    func testCandidateBarSeparatesZenzSelectionFromLocalPrefixCommit() throws {
        var session = try makeSession(tail: "尾", wholeDisplay: "全体候補")
        XCTAssertEqual(session.focusedCandidateBarTexts, ["亜"])

        let localLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["亜", "阿"], in: &session, for: localLoad))
        XCTAssertTrue(session.selectFocusedCandidate(at: 1))
        XCTAssertEqual(session.focusedSegment?.displayText, "阿")

        let zenzToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 700))
        var items = session.focusedCandidateBarItems
        XCTAssertEqual(items.map(\.text), ["...", "亜", "阿"])
        XCTAssertEqual(items.first?.content, .zenzLoading)
        XCTAssertEqual(session.selectFocusedCandidateBarItem(items[0]), .loadingSlotConsumed)

        let result = BunsetsuSessionCandidate(
            text: "禅候補",
            reference: .zenzLiveResult(generation: 700, candidateID: 70),
            score: 740,
            leftID: 31,
            rightID: 32,
            commitText: "zenz-commit",
            matchedReadingUTF16Length: 1
        )
        XCTAssertTrue(session.installZenzLiveResult(
            result,
            responseReading: "あ",
            responseGeneration: 700,
            for: zenzToken
        ))

        items = session.focusedCandidateBarItems
        XCTAssertEqual(items.map(\.text), ["禅候補", "亜", "阿"])
        XCTAssertEqual(session.selectFocusedCandidateBarItem(items[0]), .zenzResultSelected)
        XCTAssertEqual(session.focusedSegment?.displayText, "禅候補")
        XCTAssertEqual(session.commitText, "禅候補絵衣")

        let prefixPlan = try XCTUnwrap(session.focusedPrefixCommitPlan())
        XCTAssertEqual(prefixPlan.selectedCandidates[0].reference, .zenzLiveResult(generation: 700, candidateID: 70))
        XCTAssertEqual(prefixPlan.selectedCandidates[0].candidateIndex, 1)
        XCTAssertTrue(prefixPlan.selectedCandidates[0].explicitlySelected)
        XCTAssertEqual(prefixPlan.learningFragments[0].output, "禅候補")
        XCTAssertEqual(prefixPlan.learningFragments[0].candidateScore, 740)
        XCTAssertEqual(prefixPlan.learningFragments[0].candidateIndex, 1)
        XCTAssertTrue(prefixPlan.learningFragments[0].explicitlySelected)

        let localItem = try XCTUnwrap(session.focusedCandidateBarItems.first {
            if case .segmentCandidate(index: 1, candidate: _) = $0.content { return true }
            return false
        })
        guard case let .segmentCandidateSelected(commitPlan) = session.selectFocusedCandidateBarItem(localItem) else {
            return XCTFail("Selecting a local row should produce its prefix commit plan")
        }
        let localPlan = try XCTUnwrap(commitPlan)
        XCTAssertEqual(localPlan.committedText, "阿")
        XCTAssertEqual(localPlan.nextComposingInput, "😀い尾")
        XCTAssertNil(session.focusedSegment?.displayOverrideCandidate)
        XCTAssertEqual(session.focusedSegment?.displayText, "阿")
        XCTAssertEqual(session.selectFocusedCandidateBarItem(localItem), .stale)
    }

    func testZenzDuplicateRemovalUsesCommitTextReadingLengthAndRemovesOnlyFirst() throws {
        var session = try makeSession()
        let localLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        let localGeneration = localLoad.conversionRequestGeneration
        let localCandidates = [
            BunsetsuSessionCandidate(
                text: "亜", reference: .conversionResult(generation: localGeneration, candidateID: 1),
                commitText: "same-commit", matchedReadingUTF16Length: 1
            ),
            BunsetsuSessionCandidate(
                text: "阿", reference: .conversionResult(generation: localGeneration, candidateID: 2),
                commitText: "same-commit", matchedReadingUTF16Length: 1
            ),
            BunsetsuSessionCandidate(
                text: "伊", reference: .conversionResult(generation: localGeneration, candidateID: 3),
                commitText: "same-commit", matchedReadingUTF16Length: 2
            )
        ]
        XCTAssertTrue(session.installCandidates(
            localCandidates,
            responseReading: "あ",
            responseGeneration: localGeneration,
            for: localLoad
        ))
        XCTAssertEqual(session.focusedCandidateBarTexts, ["亜", "阿", "伊"])

        let zenzToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 802))
        let result = BunsetsuSessionCandidate(
            text: "禅",
            reference: .zenzLiveResult(generation: 802, candidateID: 80),
            commitText: "same-commit",
            matchedReadingUTF16Length: 1
        )
        XCTAssertTrue(session.installZenzLiveResult(
            result,
            responseReading: "あ",
            responseGeneration: 802,
            for: zenzToken
        ))
        XCTAssertEqual(session.focusedCandidateBarTexts, ["禅", "阿", "伊"])
        XCTAssertEqual(session.focusedCandidateBarItems.compactMap { item -> Int? in
            guard case let .segmentCandidate(index, _) = item.content else { return nil }
            return index
        }, [1, 2])
    }

    func testZenzTargetIgnoresLaterSegmentChangesButRejectsChangedLeftContext() throws {
        let pattern = try makePattern(boundaries: [1, 3], surfaces: ["亜", "絵", "衣"])
        var session = try makeSession(patterns: [pattern])

        let firstLoad = try XCTUnwrap(beginSegmentLoad(in: &session, at: 0))
        let firstGeneration = firstLoad.conversionRequestGeneration
        let firstCandidates = [
            BunsetsuSessionCandidate(text: "亜", reference: .conversionResult(generation: firstGeneration, candidateID: 1)),
            BunsetsuSessionCandidate(text: "阿", reference: .conversionResult(generation: firstGeneration, candidateID: 2))
        ]
        XCTAssertTrue(session.installCandidates(
            firstCandidates,
            responseReading: "あ",
            responseGeneration: firstGeneration,
            for: firstLoad
        ))
        XCTAssertTrue(session.moveFocus(by: 1))
        let originalTarget = try XCTUnwrap(session.focusedZenzSlotTarget)
        XCTAssertEqual(originalTarget.leftContext, "亜")
        let zenzToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 902))

        let laterLoad = try XCTUnwrap(beginSegmentLoad(in: &session, at: 2))
        XCTAssertTrue(installCandidateTexts(["衣後"], in: &session, for: laterLoad))
        let result = BunsetsuSessionCandidate(
            text: "変換",
            reference: .zenzLiveResult(generation: 902, candidateID: 90),
            matchedReadingUTF16Length: 2
        )
        XCTAssertTrue(session.installZenzLiveResult(
            result,
            responseReading: "😀",
            responseGeneration: 902,
            for: zenzToken
        ), "A later-segment update does not change Android's target context")

        let staleToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 903))
        XCTAssertTrue(session.moveFocus(by: -1))
        XCTAssertTrue(session.selectFocusedCandidate(at: 1))
        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertNotEqual(session.focusedZenzSlotTarget, staleToken.target)
        XCTAssertEqual(session.focusedCandidateBarTexts, ["絵"], "A Zenz row for the old left context must be hidden")
        XCTAssertFalse(session.installZenzLiveResult(
            BunsetsuSessionCandidate(
                text: "古い変換",
                reference: .zenzLiveResult(generation: 903, candidateID: 91),
                matchedReadingUTF16Length: 2
            ),
            responseReading: "😀",
            responseGeneration: 903,
            for: staleToken
        ))
        XCTAssertNil(session.zenzLiveSlotState)
    }

    func testZenzCompletionCannotClearAReplacementRequestAndLocalLoaderRejectsZenzRows() throws {
        var session = try makeSession()
        let oldToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 951))
        let currentToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 952))

        XCTAssertFalse(session.finishZenzSlotWithoutResult(for: oldToken))
        XCTAssertEqual(session.zenzLiveSlotState, .loading(token: currentToken))
        XCTAssertEqual(session.focusedCandidateBarTexts, ["...", "亜"])
        XCTAssertTrue(session.finishZenzSlotWithoutResult(for: currentToken))
        XCTAssertNil(session.zenzLiveSlotState)
        XCTAssertEqual(session.focusedCandidateBarTexts, ["亜"])

        let localToken = try XCTUnwrap(beginFocusedLoad(in: &session))
        let zenzAsLocalCandidate = BunsetsuSessionCandidate(
            text: "wrong-source",
            reference: .zenzLiveResult(generation: localToken.conversionRequestGeneration, candidateID: 99)
        )
        XCTAssertFalse(session.installCandidates(
            [zenzAsLocalCandidate],
            responseReading: localToken.segmentReading,
            responseGeneration: localToken.conversionRequestGeneration,
            for: localToken
        ))
        XCTAssertFalse(session.segments[0].isLoadingCandidates)
    }

    func testZenzResultRejectsAndroidUnsafeDisplayAndCommitTextBeforeBarExposure() throws {
        let unsafeOutputs = ["末\u{EE03}まつ", "末\nまつ", "末\u{FFFD}まつ"]

        for (index, unsafeText) in unsafeOutputs.enumerated() {
            var session = try makeSession()
            let generation = UInt64(960 + index)
            let token = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: generation))
            let unsafeDisplay = BunsetsuSessionCandidate(
                text: unsafeText,
                reference: .zenzLiveResult(generation: generation, candidateID: UInt64(960 + index)),
                matchedReadingUTF16Length: 1
            )

            XCTAssertFalse(session.installZenzLiveResult(
                unsafeDisplay,
                responseReading: "あ",
                responseGeneration: generation,
                for: token
            ), "Android-unsafe display text must be rejected: U+\(unsafeText.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ",U+"))")
            XCTAssertNil(session.zenzLiveSlotState)
            XCTAssertEqual(session.focusedCandidateBarItems.map(\.text), ["亜"])

            var commitSession = try makeSession()
            let commitToken = try XCTUnwrap(commitSession.beginLoadingFocusedZenzSlot(requestGeneration: generation))
            let unsafeCommit = BunsetsuSessionCandidate(
                text: "安全な表示",
                reference: .zenzLiveResult(generation: generation, candidateID: UInt64(970 + index)),
                commitText: unsafeText,
                matchedReadingUTF16Length: 1
            )
            XCTAssertFalse(commitSession.installZenzLiveResult(
                unsafeCommit,
                responseReading: "あ",
                responseGeneration: generation,
                for: commitToken
            ), "Android-unsafe commit text must be rejected")
            XCTAssertNil(commitSession.zenzLiveSlotState)
            XCTAssertEqual(commitSession.focusedCandidateBarItems.map(\.text), ["亜"])
        }
    }

    func testCyclingClearsZenzOverrideEvenWhenOnlyOneLocalCandidateExists() throws {
        var session = try makeSession()
        let localLoad = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["亜"], in: &session, for: localLoad))
        let zenzToken = try XCTUnwrap(session.beginLoadingFocusedZenzSlot(requestGeneration: 981))
        XCTAssertTrue(session.installZenzLiveResult(
            BunsetsuSessionCandidate(
                text: "禅候補",
                reference: .zenzLiveResult(generation: 981, candidateID: 98),
                matchedReadingUTF16Length: 1
            ),
            responseReading: "あ",
            responseGeneration: 981,
            for: zenzToken
        ))
        let zenzItem = try XCTUnwrap(session.focusedCandidateBarItems.first)
        XCTAssertEqual(session.selectFocusedCandidateBarItem(zenzItem), .zenzResultSelected)
        XCTAssertEqual(session.focusedSegment?.displayText, "禅候補")
        XCTAssertTrue(session.cycleFocusedCandidate(by: 1))
        XCTAssertNil(session.focusedSegment?.displayOverrideCandidate)
        XCTAssertEqual(session.focusedSegment?.displayText, "亜")
    }

    func testLeavingLoadingSegmentCancelsItsRetryStateAndRejectsOldReply() throws {
        var session = try makeSession()
        let staleToken = try XCTUnwrap(beginFocusedLoad(in: &session))

        XCTAssertTrue(session.moveFocus(by: 1))
        XCTAssertFalse(session.segments[0].isLoadingCandidates)
        XCTAssertFalse(installCandidateTexts(["古い候補"], in: &session, for: staleToken))

        XCTAssertTrue(session.moveFocus(by: -1))
        let retryToken = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertNotEqual(staleToken, retryToken)
        XCTAssertTrue(installCandidateTexts(["新しい候補"], in: &session, for: retryToken))
        XCTAssertEqual(session.segments[0].candidates, ["亜", "新しい候補"])
    }

    func testMovingFocusCancelsANonfocusedPreparationLoad() throws {
        var session = try makeSession()
        XCTAssertTrue(session.moveFocus(by: 1))
        let staleToken = try XCTUnwrap(beginSegmentLoad(in: &session, at: 0))
        XCTAssertTrue(session.segments[0].isLoadingCandidates)
        XCTAssertNil(beginSegmentLoad(in: &session, at: 1))

        XCTAssertTrue(session.moveFocus(by: -1))
        XCTAssertFalse(session.segments[0].isLoadingCandidates)
        XCTAssertFalse(installCandidateTexts(["古い候補"], in: &session, for: staleToken))

        let retryToken = try XCTUnwrap(beginFocusedLoad(in: &session))
        XCTAssertTrue(installCandidateTexts(["新しい候補"], in: &session, for: retryToken))
        XCTAssertEqual(session.segments[0].displayText, "亜")
        XCTAssertEqual(session.segments[0].candidates, ["亜", "新しい候補"])
    }

    func testSplitPatternChangeInvalidatesPendingCandidateLoad() throws {
        var session = try makeSession()
        let staleToken = try XCTUnwrap(beginFocusedLoad(in: &session))

        XCTAssertTrue(session.cycleSplitPattern(by: 1))
        XCTAssertFalse(installCandidateTexts(["古い候補"], in: &session, for: staleToken))
        XCTAssertFalse(session.segments[0].isLoadingCandidates)
        XCTAssertEqual(session.segments.map(\.displayText), ["亜絵", "衣"])
    }

    func testDuplicateSplitBoundaryPatternsAreKeptOnlyOnce() throws {
        let pattern = try makePattern(boundaries: [1], surfaces: ["亜", "絵", "衣"])
        var session = try makeSession(patterns: [pattern, pattern])

        XCTAssertEqual(session.splitPatterns.count, 1)
        XCTAssertFalse(session.cycleSplitPattern(by: 1))
    }

    func testRejectsEmptyOrInconsistentSessionInputAndMissingPatterns() throws {
        let pattern = try makePattern(boundaries: [1], surfaces: ["亜", "絵", "衣"])

        XCTAssertThrowsError(try BunsetsuConversionSession(
            rawInput: "", conversionInput: "", wholeDisplayText: "", generation: 1,
            splitPatterns: [pattern]
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSessionError, .emptyConversionInput)
        }
        XCTAssertThrowsError(try BunsetsuConversionSession(
            rawInput: "別", conversionInput: reading, wholeDisplayText: "全体候補", generation: 1,
            splitPatterns: [pattern]
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSessionError, .rawInputDoesNotMatchConversionAndTail)
        }
        XCTAssertThrowsError(try BunsetsuConversionSession(
            rawInput: reading, conversionInput: reading, wholeDisplayText: "全体候補", generation: 1,
            splitPatterns: []
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSessionError, .noSplitPatterns)
        }
    }

    private func installCandidateTexts(
        _ texts: [String],
        in session: inout BunsetsuConversionSession,
        for token: BunsetsuConversionSession.CandidateLoadToken
    ) -> Bool {
        let generation = token.conversionRequestGeneration
        let candidates = texts.enumerated().map { index, text in
            BunsetsuSessionCandidate(
                text: text,
                reference: .conversionResult(generation: generation, candidateID: UInt64(index + 1)),
                matchedReadingUTF16Length: nil
            )
        }
        return session.installCandidates(
            candidates,
            responseReading: token.segmentReading,
            responseGeneration: generation,
            for: token
        )
    }

    private func beginFocusedLoad(
        in session: inout BunsetsuConversionSession,
        conversionRequestGeneration: UInt64? = nil
    ) -> BunsetsuConversionSession.CandidateLoadToken? {
        session.beginLoadingFocusedCandidates(
            conversionRequestGeneration: nextRequestGeneration(conversionRequestGeneration)
        )
    }

    private func beginSegmentLoad(
        in session: inout BunsetsuConversionSession,
        at segmentIndex: Int,
        conversionRequestGeneration: UInt64? = nil
    ) -> BunsetsuConversionSession.CandidateLoadToken? {
        session.beginLoadingCandidates(
            forSegmentAt: segmentIndex,
            conversionRequestGeneration: nextRequestGeneration(conversionRequestGeneration)
        )
    }

    private func nextRequestGeneration(_ explicitValue: UInt64?) -> UInt64 {
        if let explicitValue { return explicitValue }
        nextConversionRequestGeneration &+= 1
        return nextConversionRequestGeneration
    }

    private func makeSession(
        tail: String = "",
        wholeDisplay: String = "全体候補",
        patterns: [BunsetsuSplitPattern]? = nil,
        eligibleWholeDisplay: String? = nil
    ) throws -> BunsetsuConversionSession {
        try BunsetsuConversionSession(
            rawInput: reading + tail,
            conversionInput: reading,
            tailText: tail,
            wholeDisplayText: wholeDisplay,
            generation: 42,
            splitPatterns: patterns ?? [
                makePattern(boundaries: [1], surfaces: ["亜", "絵", "衣"]),
                makePattern(boundaries: [3], surfaces: ["亜", "絵", "衣"])
            ],
            eligibleWholeCandidateDisplayText: eligibleWholeDisplay
        )
    }

    private func makePattern(
        boundaries: [Int],
        surfaces: [String]
    ) throws -> BunsetsuSplitPattern {
        let readings = Array(reading)
        guard readings.count == surfaces.count else {
            throw BunsetsuProjectionError.invalidPath
        }
        var offset = 0
        let tokens = zip(readings, surfaces).map { character, surface in
            defer { offset += String(character).utf16.count }
            return BunsetsuToken(
                readingRange: NSRange(location: offset, length: String(character).utf16.count),
                text: surface
            )
        }
        let sourceCandidate = surfaces.joined()
        return try BunsetsuSplitPattern(
            reading: reading,
            boundaries: boundaries,
            candidatePaths: [BunsetsuCandidatePath(
                reading: reading,
                candidate: sourceCandidate,
                tokens: tokens
            )]
        )
    }
}
