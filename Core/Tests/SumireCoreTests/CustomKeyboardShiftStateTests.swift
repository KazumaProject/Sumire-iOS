import XCTest
@testable import SumireCore

final class CustomKeyboardShiftStateTests: XCTestCase {
    func testShiftAndCapsLockTransitionsMatchReference() {
        var state = CustomKeyboardShiftState.off
        XCTAssertFalse(state.isActive)
        state.tapShift(); XCTAssertEqual(state, .oneShot); XCTAssertTrue(state.isActive)
        state.tapShift(); XCTAssertEqual(state, .off)
        state.tapCapsLock(); XCTAssertEqual(state, .locked)
        state.tapShift(); XCTAssertEqual(state, .off)
        state.tapShift(); state.tapCapsLock(); XCTAssertEqual(state, .locked)
        state.tapCapsLock(); XCTAssertEqual(state, .off)
    }
    func testOnlyAsciiLowercaseChangesWithoutUnicodeOrLocaleExpansion() {
        let input = "aAzZ 123-ßıİéか\u{3099}👩‍💻\n"
        XCTAssertEqual(CustomKeyboardShiftState.off.applying(to: input), input)
        for state in [CustomKeyboardShiftState.oneShot, .locked] {
            XCTAssertEqual(state.applying(to: input), "AAZZ 123-ßıİéか\u{3099}👩‍💻\n")
            XCTAssertEqual(state.applying(to: ""), "")
        }
    }
    func testNonemptyTextIncludingPunctuationConsumesOnlyOneShot() {
        for text in ["a", ".", " ", "\n", "あ", "👩‍💻"] {
            var state = CustomKeyboardShiftState.oneShot
            state.consumeText(text); XCTAssertEqual(state, .off, text)
            state = .locked; state.consumeText(text); XCTAssertEqual(state, .locked, text)
            state = .off; state.consumeText(text); XCTAssertEqual(state, .off, text)
        }
    }
    func testTransformingCompositionPrefixPreservesUnicodeTailAndCaret() {
        var composition = CompositionState(); composition.append("a👩‍💻か\u{3099}")
        XCTAssertTrue(composition.moveCursor(by: -2))
        let previous = composition.generation
        composition.transformPrefix { CustomKeyboardShiftState.oneShot.applying(to: $0) }
        XCTAssertEqual(composition.reading, "A👩‍💻か\u{3099}")
        XCTAssertEqual(composition.cursorUTF16, 1)
        XCTAssertEqual(composition.generation, previous + 1)
        XCTAssertFalse(composition.accepts(previous))
    }
    func testPresentationAndEmptyOutputDoNotConsumePendingShift() {
        var state = CustomKeyboardShiftState.oneShot
        XCTAssertEqual(state.applying(to: "key"), "KEY")
        XCTAssertEqual(state, .oneShot)
        state.consumeText(""); XCTAssertEqual(state, .oneShot)
        // A command has no consume call: preparing its guide preserves the state.
        XCTAssertEqual(state.applying(to: "←"), "←")
        XCTAssertEqual(state, .oneShot)
    }
}
