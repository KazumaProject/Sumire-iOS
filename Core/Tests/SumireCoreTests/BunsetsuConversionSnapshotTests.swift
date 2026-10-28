import XCTest
@testable import SumireCore

final class BunsetsuConversionSnapshotTests: XCTestCase {
    func testSnapshotRetainsNativeCandidateOrderPathsAndMappingPresence() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [[2], [3, 1, 3, 4, 0], [2]],
            primarySplitPositions: [1],
            candidates: [
                BunsetsuSnapshotCandidate(
                    nativeIndex: 0,
                    candidateID: 41,
                    score: 100,
                    identity: .init(surface: "AB", readingUTF16Length: 4),
                    tokenPath: [
                        BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "A"),
                        BunsetsuToken(readingRange: NSRange(location: 2, length: 2), text: "B")
                    ],
                    mappedSplitPositions: []
                ),
                BunsetsuSnapshotCandidate(
                    nativeIndex: 1,
                    candidateID: 42,
                    score: 90,
                    identity: .init(surface: "AC", readingUTF16Length: 4),
                    tokenPath: nil,
                    mappedSplitPositions: nil
                )
            ]
        )

        XCTAssertEqual(snapshot.candidates.map(\.nativeIndex), [0, 1])
        XCTAssertEqual(snapshot.candidates.map(\.candidateID), [41, 42])
        XCTAssertEqual(snapshot.candidates[0].tokenPath?.map(\.readingRange), [
            NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)
        ])
        XCTAssertEqual(snapshot.candidates[0].mappedSplitPositions, [])
        XCTAssertNil(snapshot.candidates[1].mappedSplitPositions)
    }

    func testExplicitEmptyMappingDoesNotFallBackToPrimaryPositions() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [[2]],
            primarySplitPositions: [2],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: .init(surface: "whole", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: [])
            ]
        )

        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [.init(surface: "whole", readingUTF16Length: 4)]),
            []
        )
    }

    func testOnlyFirstNativeCandidateCanUsePrimaryFallback() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [3, 1, 4, 0, -1],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 2,
                      identity: .init(surface: "prefix", readingUTF16Length: 3),
                      tokenPath: nil, mappedSplitPositions: nil),
                .init(nativeIndex: 1, candidateID: 2, score: 1,
                      identity: .init(surface: "second", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: nil),
                .init(nativeIndex: 2, candidateID: 3, score: 0,
                      identity: .init(surface: "third", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: [2])
            ]
        )

        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [
                .init(surface: "prefix", readingUTF16Length: 3),
                .init(surface: "second", readingUTF16Length: 4),
                .init(surface: "third", readingUTF16Length: 4)
            ]),
            [2]
        )
        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [
                .init(surface: "prefix", readingUTF16Length: 3),
                .init(surface: "second", readingUTF16Length: 4)
            ]),
            []
        )
    }

    func testFirstNativeFullReadingCandidateFallsBackToSanitizedPrimarySplit() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [3, 1, 3, 4, 0, -1],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: .init(surface: "whole", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: nil)
            ]
        )

        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [.init(surface: "whole", readingUTF16Length: 4)]),
            [1, 3]
        )
    }

    func testShuffledCandidatesUseLowestNativeIndexForDuplicateIdentity() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "whole", readingUTF16Length: 4)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [3],
            candidates: [
                .init(nativeIndex: 1, candidateID: 2, score: 1,
                      identity: identity, tokenPath: nil, mappedSplitPositions: [1]),
                .init(nativeIndex: 0, candidateID: 1, score: 2,
                      identity: identity, tokenPath: nil, mappedSplitPositions: [2])
            ]
        )

        XCTAssertEqual(snapshot.candidates.map(\.nativeIndex), [0, 1])
        XCTAssertEqual(snapshot.candidates.map(\.candidateID), [1, 2])
        XCTAssertEqual(try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [identity]), [2])
    }

    func testCandidateAfterMissingNativeIndexZeroCannotUsePrimaryFallback() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [2],
            candidates: [
                .init(nativeIndex: 1, candidateID: 2, score: 1,
                      identity: .init(surface: "second", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: nil)
            ]
        )

        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [
                .init(surface: "second", readingUTF16Length: 4)
            ]),
            []
        )
    }

    func testDuplicateNativeIndicesFailClosedForSplitResolution() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "whole", readingUTF16Length: 4)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [3],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 2,
                      identity: identity, tokenPath: nil, mappedSplitPositions: [1]),
                .init(nativeIndex: 0, candidateID: 2, score: 1,
                      identity: identity, tokenPath: nil, mappedSplitPositions: [2])
            ]
        )

        XCTAssertFalse(snapshot.hasValidNativeIndices)
        XCTAssertEqual(try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [identity]), [])
    }

    func testProjectedPatternsReuseOwnedPathsInNormalizedPatternOrder() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "ABCD", readingUTF16Length: 4)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [[3]],
            primarySplitPositions: [],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 2,
                      identity: identity, tokenPath: [
                          BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: "A"),
                          BunsetsuToken(readingRange: NSRange(location: 1, length: 1), text: "B"),
                          BunsetsuToken(readingRange: NSRange(location: 2, length: 1), text: "C"),
                          BunsetsuToken(readingRange: NSRange(location: 3, length: 1), text: "D")
                      ], mappedSplitPositions: [2])
            ]
        )

        let patterns = try snapshot.projectedSplitPatterns(
            reading: "abcd",
            requestGeneration: 1,
            orderedDisplayCandidates: [identity]
        )

        XCTAssertEqual(patterns.map(\.boundaries), [[2], [3]])
        XCTAssertEqual(patterns[0].sourceCandidate, "ABCD")
        XCTAssertEqual(patterns[0].segments.map(\.text), ["AB", "CD"])
        XCTAssertEqual(patterns[1].segments.map(\.text), ["ABC", "D"])
    }

    func testProjectedPatternsRejectDifferentReadingLength() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [],
            candidates: []
        )

        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(
            reading: "abc",
            requestGeneration: 1,
            orderedDisplayCandidates: []
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .readingLengthMismatch)
        }
    }

    func testProjectedPatternsRejectStaleGenerationEvenWhenReadingLengthMatches() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 10,
            reading: "abcd",
            splitPatterns: [[2]],
            primarySplitPositions: [],
            candidates: []
        )

        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(
            reading: "wxyz",
            requestGeneration: 11,
            orderedDisplayCandidates: []
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .generationMismatch)
        }
    }

    func testProjectedPatternsRejectDifferentReadingWithSameGenerationAndLength() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 10,
            reading: "abcd",
            splitPatterns: [[2]],
            primarySplitPositions: [],
            candidates: []
        )

        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(
            reading: "wxyz",
            requestGeneration: 10,
            orderedDisplayCandidates: []
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .readingIdentityMismatch)
        }
    }

    func testSplitResolutionAndNormalizationRejectDifferentReadingWithSameGenerationAndLength() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "whole", readingUTF16Length: 4)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 10,
            reading: "abcd",
            splitPatterns: [[2]],
            primarySplitPositions: [2],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: identity, tokenPath: nil, mappedSplitPositions: [2])
            ]
        )

        XCTAssertThrowsError(try snapshot.initialSplitPositions(
            reading: "wxyz",
            requestGeneration: 10,
            for: [identity]
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .readingIdentityMismatch)
        }
        XCTAssertThrowsError(try snapshot.normalizedSplitPatterns(
            reading: "wxyz",
            requestGeneration: 10,
            for: [identity]
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .readingIdentityMismatch)
        }
    }

    func testRequestReadingIdentityUsesExactUTF16InsteadOfCanonicalStringEquality() throws {
        let composed = "\u{00C5}"
        let canonicallyEquivalent = "\u{212B}"
        XCTAssertEqual(composed, canonicallyEquivalent)
        XCTAssertNotEqual(Array(composed.utf16), Array(canonicallyEquivalent.utf16))

        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: composed,
            splitPatterns: [[1]],
            primarySplitPositions: [],
            candidates: []
        )

        XCTAssertThrowsError(try snapshot.projectedSplitPatterns(
            reading: canonicallyEquivalent,
            requestGeneration: 1,
            orderedDisplayCandidates: []
        )) { error in
            XCTAssertEqual(error as? BunsetsuConversionSnapshotError, .readingIdentityMismatch)
        }
    }

    func testProjectedPatternsDropSplitInsideSurrogatePair() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "😀亜", readingUTF16Length: 3)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "😀あ",
            splitPatterns: [[1, 2]],
            primarySplitPositions: [],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: identity, tokenPath: [
                          BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "😀"),
                          BunsetsuToken(readingRange: NSRange(location: 2, length: 1), text: "亜")
                      ], mappedSplitPositions: [1])
            ]
        )

        let patterns = try snapshot.projectedSplitPatterns(
            reading: "😀あ",
            requestGeneration: 1,
            orderedDisplayCandidates: [identity]
        )

        XCTAssertEqual(patterns.map(\.boundaries), [[], [2]])
        XCTAssertEqual(patterns[0].segments.map(\.text), ["😀亜"])
        XCTAssertEqual(patterns[1].segments.map(\.text), ["😀", "亜"])
    }

    func testProjectedPatternsIgnorePathWithTokenBoundaryInsideSurrogatePair() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "AB", readingUTF16Length: 3)
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "😀あ",
            splitPatterns: [[2]],
            primarySplitPositions: [],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: identity, tokenPath: [
                          BunsetsuToken(readingRange: NSRange(location: 0, length: 1), text: "A"),
                          BunsetsuToken(readingRange: NSRange(location: 1, length: 2), text: "B")
                      ], mappedSplitPositions: [2])
            ]
        )

        let patterns = try snapshot.projectedSplitPatterns(
            reading: "😀あ",
            requestGeneration: 1,
            orderedDisplayCandidates: [identity]
        )

        XCTAssertNil(patterns[0].sourceCandidate)
        XCTAssertEqual(patterns[0].segments.map(\.reading), ["😀", "あ"])
        XCTAssertEqual(patterns[0].segments.map(\.text), ["😀", "あ"])
    }

    func testNormalizationPrependsInitialPatternAndPreservesDistinctEngineOrder() throws {
        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [[3, 1, 3, 4, 0], [2], [1, 3], []],
            primarySplitPositions: [],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: .init(surface: "whole", readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: nil)
            ]
        )

        XCTAssertEqual(
            try snapshot.normalizedSplitPatterns(reading: "abcd", requestGeneration: 1, for: [.init(surface: "whole", readingUTF16Length: 4)]),
            [[], [1, 3], [2]]
        )
    }

    func testCandidateIdentityUsesExactUTF16InsteadOfCanonicalStringEquality() throws {
        let composed = "\u{00C5}"
        let canonicallyEquivalent = "\u{212B}"
        XCTAssertEqual(composed, canonicallyEquivalent)
        XCTAssertNotEqual(Array(composed.utf16), Array(canonicallyEquivalent.utf16))

        let snapshot = BunsetsuConversionSnapshot(
            requestGeneration: 1,
            reading: "abcd",
            splitPatterns: [],
            primarySplitPositions: [2],
            candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 1,
                      identity: .init(surface: composed, readingUTF16Length: 4),
                      tokenPath: nil, mappedSplitPositions: [1])
            ]
        )

        XCTAssertEqual(
            try snapshot.initialSplitPositions(reading: "abcd", requestGeneration: 1, for: [
                .init(surface: canonicallyEquivalent, readingUTF16Length: 4)
            ]),
            []
        )
    }
    func testEveryPublicSplitAPIRequiresTheOriginalReadingAndGeneration() throws {
        let identity = BunsetsuCandidateDisplayIdentity(surface: "顔亜", readingUTF16Length: 3)
        let snapshot = BunsetsuConversionSnapshot(requestGeneration: 7, reading: "😀あ",
            splitPatterns: [[1], [2]], primarySplitPositions: [2], candidates: [
                .init(nativeIndex: 0, candidateID: 1, score: 0, identity: identity,
                      tokenPath: [BunsetsuToken(readingRange: NSRange(location: 0, length: 2), text: "顔"),
                                  BunsetsuToken(readingRange: NSRange(location: 2, length: 1), text: "亜")],
                      mappedSplitPositions: [2])
            ])
        let invalidRequests: [(String, UInt64, BunsetsuConversionSnapshotError)] = [
            ("😀あ", 8, .generationMismatch),
            ("あ😀", 7, .readingIdentityMismatch),
            ("あ", 7, .readingLengthMismatch)
        ]
        for (reading, generation, expected) in invalidRequests {
            XCTAssertThrowsError(try snapshot.initialSplitPositions(reading: reading, requestGeneration: generation, for: [identity])) {
                XCTAssertEqual($0 as? BunsetsuConversionSnapshotError, expected)
            }
            XCTAssertThrowsError(try snapshot.normalizedSplitPatterns(reading: reading, requestGeneration: generation, for: [identity])) {
                XCTAssertEqual($0 as? BunsetsuConversionSnapshotError, expected)
            }
            XCTAssertThrowsError(try snapshot.projectedSplitPatterns(reading: reading, requestGeneration: generation, orderedDisplayCandidates: [identity])) {
                XCTAssertEqual($0 as? BunsetsuConversionSnapshotError, expected)
            }
        }
        let projected = try snapshot.projectedSplitPatterns(reading: "😀あ", requestGeneration: 7, orderedDisplayCandidates: [identity])
        XCTAssertEqual(projected.map(\.boundaries), [[2], []])
        XCTAssertTrue(projected.allSatisfy { !$0.boundaries.contains(1) }, "Never split the UTF-16 surrogate pair")
    }
}
