import XCTest
@testable import SumireCore

final class KanaInputTests: XCTestCase {
    func testJapaneseQwertyWidthPreferencesAreIndependent() {
        XCTAssertEqual(QwertyFlick.japaneseWidth("1１#＃", halfWidthNumbers: false, halfWidthSymbols: false), "１１＃＃")
        XCTAssertEqual(QwertyFlick.japaneseWidth("1１#＃", halfWidthNumbers: true, halfWidthSymbols: false), "11＃＃")
        XCTAssertEqual(QwertyFlick.japaneseWidth("1１#＃", halfWidthNumbers: false, halfWidthSymbols: true), "１１##")
        XCTAssertEqual(QwertyFlick.japaneseWidth("「」。、￥¥’🪻", halfWidthNumbers: true, halfWidthSymbols: true), "「」。、￥¥’🪻")
    }
    func testQwertyNumberAndSymbolPageOutputs() {
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "1", page: 1, japanese: false, up: true, down: true), ["1", "", "１", "", "1"])
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "1", page: 1, japanese: true, up: false, down: true), ["１", "", "", "", "１"])
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "#", page: 2, japanese: true, up: false, down: false).first, "＃")
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "「", page: 1, japanese: true, up: false, down: false).first, "「")
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "q", page: 1, japanese: true, up: true, down: true), [])
        XCTAssertEqual(QwertyFlick.pageOutputs(for: "1", page: 0, japanese: false, up: true, down: true), [])
    }
    func testQwertyFlickMappingsAndDisabledDirections() {
        XCTAssertEqual(QwertyFlick.outputs(for: "a", japanese: false, up: true, down: true), ["a", "", "@", "", "A"])
        XCTAssertEqual(QwertyFlick.outputs(for: "C", japanese: false, up: true, down: false), ["C", "", "\"", "", ""])
        XCTAssertEqual(QwertyFlick.outputs(for: "q", japanese: true, up: true, down: true), ["q", "", "１", "", "Ｑ"])
        XCTAssertEqual(QwertyFlick.outputs(for: "a", japanese: true, up: false, down: false), ["a", "", "", "", ""])
        XCTAssertEqual(QwertyFlick.outputs(for: "🪻", japanese: false, up: true, down: true), ["🪻", "", "", "", ""])
    }
    func testGojuonPreviousCharacterFollowsReferenceInMixedInput() {
        XCTAssertEqual(GojuonInput.previous("a", mode: .english), "2")
        XCTAssertEqual(GojuonInput.previous("a", mode: .japanese), "2")
        XCTAssertEqual(GojuonInput.previous("あ", mode: .english), "ぉ")
        XCTAssertEqual(GojuonInput.previous("x", mode: .english), "9")
        XCTAssertEqual(GojuonInput.previous("w", mode: .english), "x")
        XCTAssertNil(GojuonInput.previous("あ", mode: .number))
        XCTAssertNil(GojuonInput.previous("ａ", mode: .english))
        XCTAssertNil(GojuonInput.previous("🪻", mode: .english))
    }
    func testGojuonModeGeometryCoversEverySlotWithoutOverlap() {
        for mode in TenKeyMode.allCases {
            let columns = GojuonInput.columns(mode: mode)
            var occupied = Set<Int>()
            for cell in GojuonInput.cells(mode: mode) {
                for column in cell.column..<(cell.column + cell.columnSpan) {
                    XCTAssertTrue((0..<columns).contains(column))
                    XCTAssertTrue(occupied.insert(cell.row * columns + column).inserted)
                }
            }
            XCTAssertEqual(occupied.count, columns * 5)
        }
        XCTAssertEqual(GojuonInput.cells(mode: .english).first { $0.row == 4 && $0.sourceColumn == 10 }?.columnSpan, 2)
        XCTAssertFalse(GojuonInput.cells(mode: .number).contains { $0.sourceColumn == 3 || $0.sourceColumn == 4 })
    }
    func testGojuonEnglishAndNumberReferenceMappings() {
        XCTAssertEqual(GojuonInput.outputs(row: 0, column: 0, mode: .english), ["a", "A", "ａ", "Ａ", ""])
        XCTAssertEqual(GojuonInput.outputs(row: 3, column: 3, mode: .english), ["/", "\\", "／", "＼", ""])
        XCTAssertEqual(GojuonInput.label(row: 3, column: 10, mode: .english), "'")
        XCTAssertEqual(GojuonInput.label(row: 3, column: 6, mode: .english), "@")
        XCTAssertEqual(GojuonInput.label(row: 4, column: 8, mode: .english), "?")
        XCTAssertEqual(GojuonInput.outputs(row: 3, column: 10, mode: .english).first, "`")
        XCTAssertEqual(GojuonInput.label(row: 1, column: 6, mode: .number), "ー")
        XCTAssertEqual(GojuonInput.outputs(row: 1, column: 6, mode: .number), ["−", "", "－", "", ""])
        XCTAssertEqual(GojuonInput.outputs(row: 0, column: 8, mode: .number), ["1", "", "１", "", ""])
        // The reference KeyMap contains duplicate entries for hidden cells;
        // they must not become active keys when constructing the iOS grid.
        for mode in [TenKeyMode.english, .number] {
            for row in 0..<5 {
                XCTAssertEqual(GojuonInput.label(row: row, column: 1, mode: mode), "")
                XCTAssertEqual(GojuonInput.outputs(row: row, column: 1, mode: mode), [])
            }
            XCTAssertEqual(GojuonInput.label(row: 4, column: 10, mode: mode), "全角")
            XCTAssertEqual(GojuonInput.outputs(row: 4, column: 10, mode: mode), ["", "", "", "", ""])
            XCTAssertEqual(GojuonInput.label(row: 5, column: 0, mode: mode), "")
            XCTAssertEqual(GojuonInput.outputs(row: 0, column: 11, mode: mode), [])
        }
    }
    func testGojuonDirectionalOutputsAndEmptySlots() {
        XCTAssertEqual(GojuonInput.outputs(row: 0, column: 10), ["あ", "", "ぁ", "", ""])
        XCTAssertEqual(GojuonInput.outputs(row: 0, column: 5), ["は", "ば", "", "ぱ", ""])
        XCTAssertEqual(GojuonInput.outputs(row: 0, column: 0), ["「", "「", "」", "(", ")"])
        XCTAssertEqual(GojuonInput.outputs(row: 1, column: 0).first, "？")
        XCTAssertTrue(GojuonInput.outputs(row: 1, column: 3).isEmpty)
        XCTAssertTrue(GojuonInput.outputs(row: -1, column: 10).isEmpty)
    }
    func testTenKeyModeMappingsAndCycles() {
        XCTAssertEqual(TenKeyMode.japanese.next, .english)
        XCTAssertEqual(TenKeyMode.english.next, .number)
        XCTAssertEqual(TenKeyMode.number.next, .japanese)
        XCTAssertEqual(TenKeyMode.english.keys[1], ["a", "b", "c", "", "2"])
        XCTAssertEqual(TenKeyMode.number.keys[0], ["1", "☆", "♪", "→", ""])
        XCTAssertEqual(TenKeyMode.number.keys[9], ["(", ")", "[", "]", ""])
        XCTAssertEqual(TenKeyMode.english.tapCycle(at: 1), "abcABC2")
        XCTAssertEqual(TenKeyMode.english.previous("a"), "2")
        XCTAssertNil(TenKeyMode.number.previous("1"))
        XCTAssertEqual(TenKeyMode.japanese.tapCycle(at: 7), "やゆよゃゅょ")
        for mode in TenKeyMode.allCases { XCTAssertEqual(mode.keys.count, 12) }
    }
    func testPreviousJapaneseIncludesSmallKanaAndPreservesUnsupportedCharacters() {
        XCTAssertEqual(KanaInput.previousJapanese("あ"), "ぉ")
        XCTAssertEqual(KanaInput.previousJapanese("っ"), "と")
        XCTAssertEqual(KanaInput.previousJapanese("わ"), "〜")
        XCTAssertNil(KanaInput.previousJapanese("🪻"))
        XCTAssertNil(KanaInput.previousJapanese("が"))
    }
    func testFlickThresholdAndDominantDirection() {
        XCTAssertEqual(FlickDirection.resolve(dx: 13, dy: 13), .tap)
        XCTAssertEqual(FlickDirection.resolve(dx: 13, dy: 13, shape: .radial), .down)
        XCTAssertEqual(FlickDirection.resolve(dx: 9, dy: 9, shape: .radial), .tap)
        XCTAssertEqual(FlickDirection.resolve(dx: -14, dy: 0, shape: .radial), .left)
        XCTAssertEqual(FlickDirection.resolve(dx: -30, dy: 4), .left)
        XCTAssertEqual(FlickDirection.resolve(dx: 2, dy: -30), .up)
        XCTAssertEqual(FlickDirection.resolve(dx: 30, dy: -4), .right)
        XCTAssertEqual(FlickDirection.resolve(dx: 3, dy: 30), .down)
    }
    func testTapCycleCannotReplaceAfterExternalEditOrFlick() {
        var cycle = KanaTapCycle()
        let first = cycle.choose("あいうえお", direction: .tap, generation: 1, time: 0, enabled: true)
        XCTAssertEqual(first.text, "あ"); XCTAssertFalse(first.replacing)
        let next = cycle.choose("あいうえお", direction: .tap, generation: 2, time: 0.2, enabled: true)
        XCTAssertEqual(next.text, "い"); XCTAssertTrue(next.replacing)
        XCTAssertFalse(cycle.choose("あいうえお", direction: .tap, generation: 4, time: 0.3, enabled: true).replacing)
        let flick = cycle.choose("あいうえお", direction: .up, generation: 5, time: 0.4, enabled: true)
        XCTAssertEqual(flick.text, "う"); XCTAssertFalse(flick.replacing)
        XCTAssertFalse(cycle.choose("あいうえお", direction: .tap, generation: 6, time: 0.5, enabled: true).replacing)
        XCTAssertFalse(cycle.choose("あいうえお", direction: .tap, generation: 7, time: 2, enabled: true).replacing)
        XCTAssertFalse(cycle.choose("あいうえお", direction: .tap, generation: 8, time: 2.1, enabled: false).replacing)
    }
    func testModifiersAndGraphemeReplacement() {
        XCTAssertEqual(KanaInput.modified("は"), "ば")
        XCTAssertEqual(KanaInput.modified("ば"), "ぱ")
        XCTAssertEqual(KanaInput.modified("ぱ"), "は")
        XCTAssertEqual(KanaInput.modified("つ"), "っ")
        XCTAssertNil(KanaInput.modified("👩‍💻"))
        var state = CompositionState()
        state.append("あ👩‍💻")
        XCTAssertTrue(state.replaceLast("い"))
        XCTAssertEqual(state.reading, "あい")
    }
}
