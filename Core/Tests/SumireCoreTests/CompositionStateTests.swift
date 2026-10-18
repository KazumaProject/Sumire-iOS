import XCTest
@testable import SumireCore
final class CompositionStateTests: XCTestCase {
    func testHostUTF16CaretRejectsSplitGraphemesAndPreservesGeneration() {
        var state = CompositionState()
        XCTAssertFalse(state.moveCursor(toUTF16: 0))
        state.append("か\u{3099}👩‍💻い")
        let previous = state.generation
        for offset in [-1, 1, 3, 4, 5, 6, 9] {
            XCTAssertFalse(state.moveCursor(toUTF16: offset))
            XCTAssertEqual(state.generation, previous)
            XCTAssertEqual(state.cursor, 3)
        }
        XCTAssertTrue(state.moveCursor(toUTF16: 2))
        XCTAssertEqual(state.cursor, 1)
        XCTAssertGreaterThan(state.generation, previous)
        state.append("あ")
        XCTAssertEqual(state.reading, "か\u{3099}あ👩‍💻い")
    }
    func testHostSelectionRequiresUnchangedMarkedReadingAndCaret() {
        var state = CompositionState()
        state.append("あい")
        let generation = state.generation
        for (marked, range) in [("愛", NSRange(location: 1, length: 0)),
                                ("あいう", NSRange(location: 1, length: 0)),
                                ("あい", NSRange(location: 0, length: 2)),
                                ("あい", NSRange(location: 3, length: 0))] {
            XCTAssertFalse(state.synchronizeCursor(markedText: marked, selection: range))
            XCTAssertEqual(state.generation, generation)
            XCTAssertEqual(state.cursor, 2)
        }
        XCTAssertTrue(state.synchronizeCursor(markedText: "あい", selection: NSRange(location: 1, length: 0)))
        XCTAssertFalse(state.accepts(generation))
        state.deleteBackward()
        XCTAssertEqual(state.reading, "い")
        var decomposed = CompositionState()
        decomposed.append("か\u{3099}")
        XCTAssertFalse(decomposed.synchronizeCursor(markedText: "が", selection: NSRange(location: 1, length: 0)))
    }
    func testCursorEditsRemainComposingAndRespectGraphemes() {
        var state = CompositionState()
        state.append("あ👩‍💻い")
        let old = state.generation
        XCTAssertTrue(state.moveCursor(by: -1))
        XCTAssertEqual(state.phase, .editing)
        XCTAssertEqual(state.cursorUTF16, "あ👩‍💻".utf16.count)
        XCTAssertFalse(state.accepts(old))
        state.append("か")
        XCTAssertEqual(state.reading, "あ👩‍💻かい")
        XCTAssertTrue(state.deleteBackward())
        XCTAssertTrue(state.deleteBackward())
        XCTAssertEqual(state.reading, "あい")
        XCTAssertTrue(state.moveCursor(by: -1))
        XCTAssertEqual(state.cursorUTF16, 0)
        XCTAssertTrue(state.deleteBackward())
        XCTAssertEqual(state.reading, "あい")
        state.append("え")
        XCTAssertEqual(state.reading, "えあい")
        XCTAssertEqual(state.commit(), "えあい")
        XCTAssertEqual(state.cursorUTF16, 0)
    }

    func testRomajiInsertionAtComposingCursorPreservesSuffix() throws {
        var state = CompositionState()
        let converter = try RomajiConverter.standard()
        state.append("あい")
        state.moveCursor(by: -1)
        state.appendRomaji("k", using: converter)
        state.appendRomaji("a", using: converter)
        XCTAssertEqual(state.reading, "あかい")
        XCTAssertEqual(state.cursorUTF16, 2)
        state.replaceLast("が")
        XCTAssertEqual(state.reading, "あがい")
    }

    func testPartialCommitRetainsReadingAndRejectsOldResults() {
        var state = CompositionState()
        state.append("とうきょうにいく")
        let generation = state.generation
        XCTAssertEqual(state.commitPrefix("東京", readingUTF16Length: 5), "東京")
        XCTAssertEqual(state.reading, "にいく")
        XCTAssertEqual(state.phase, .editing)
        XCTAssertFalse(state.accepts(generation))
        XCTAssertEqual(state.commitPrefix("に行く", readingUTF16Length: 3), "に行く")
        XCTAssertEqual(state.reading, "")
        XCTAssertEqual(state.phase, .committed)
    }

    func testPartialCommitRejectsBrokenGraphemesWithoutMutation() {
        for prefix in ["か\u{3099}", "👨‍👩‍👧‍👦", "😀"] {
            var state = CompositionState()
            state.append(prefix + "あと")
            let generation = state.generation
            for length in [0, -1, 1, 999] {
                XCTAssertNil(state.commitPrefix("変", readingUTF16Length: length))
                XCTAssertEqual(state.reading, prefix + "あと")
                XCTAssertEqual(state.generation, generation)
            }
            XCTAssertEqual(state.commitPrefix("変", readingUTF16Length: prefix.utf16.count), "変")
            XCTAssertEqual(state.reading, "あと")
        }
    }

    func testLateResultsCannotReplaceEditedOrCommittedInput() {
        var state = CompositionState()
        state.append("にほん")
        let old = state.generation
        state.append("ご")
        XCTAssertFalse(state.accepts(old))
        XCTAssertEqual(state.reading, "にほんご")
        let current = state.generation
        state.select()
        XCTAssertTrue(state.accepts(current))
        XCTAssertEqual(state.commit("日本語"), "日本語")
        XCTAssertFalse(state.accepts(current))
        XCTAssertEqual(state.phase, .committed)
        state.append("あ")
        state.invalidate()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.reading, "")
    }
    func testRomajiEditingAndFlush() throws {
        let converter = try RomajiConverter.standard()
        var state = CompositionState()
        for key in "nihongo" { state.appendRomaji(String(key), using: converter) }
        XCTAssertEqual(state.reading, "にほんご")
        let old = state.generation
        XCTAssertTrue(state.deleteBackward())
        XCTAssertEqual(state.reading, "にほん")
        XCTAssertFalse(state.accepts(old))
        state.appendRomaji("n", using: converter)
        XCTAssertEqual(state.reading, "にほんn")
        XCTAssertTrue(state.flushRomaji(using: converter))
        XCTAssertEqual(state.commit(), "にほんん")
        for key in "gakkou" { state.appendRomaji(String(key), using: converter) }
        XCTAssertEqual(state.commit(), "がっこう")
    }

    func testDeletionPreservesExtendedGraphemesAndReadingFallback() {
        var state = CompositionState()
        state.append("か\u{3099}👩‍💻🇯🇵")
        XCTAssertTrue(state.deleteBackward())
        XCTAssertEqual(state.reading, "か\u{3099}👩‍💻")
        XCTAssertTrue(state.deleteBackward())
        XCTAssertEqual(state.commit(), "か\u{3099}")
        XCTAssertFalse(state.deleteBackward())
        XCTAssertNil(state.commit())
    }
}
