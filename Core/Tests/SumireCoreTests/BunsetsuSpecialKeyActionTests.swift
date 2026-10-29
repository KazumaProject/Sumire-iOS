import XCTest
@testable import SumireCore

final class BunsetsuSpecialKeyActionTests: XCTestCase {
    func testSpaceConvertLongPressUsesTrackpadWhenEmptyAndCyclesSplitWhileComposing() {
        let settings = SumireSpecialKeySettings()

        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: true), .cycleBunsetsuSplitPattern)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: false), .cursorMoveMode)
        XCTAssertNotEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .english, hasComposition: true), .cycleBunsetsuSplitPattern)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .english, hasComposition: false), .doNothing)
    }

    func testExplicitTapOverrideDisablesTheDefaultBunsetsuLongPress() throws {
        var settings = SumireSpecialKeySettings()
        try settings.set(.space, for: .spaceConvert, gesture: .tap,
            arrangement: .toggle, mode: .japanese)

        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: true), .doNothing)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: false), .doNothing)
    }

    func testBunsetsuCycleActionIsAvailableOnlyForJapaneseSpaceConvertLongPress() {
        let action = SumireSpecialKeyAction.cycleBunsetsuSplitPattern

        XCTAssertNil(action.unavailabilityReason(for: .spaceConvert, gesture: .longPress, mode: .japanese))
        XCTAssertNotNil(action.unavailabilityReason(for: .spaceConvert, gesture: .longPress, mode: .english))
        XCTAssertNotNil(action.unavailabilityReason(for: .spaceConvert, gesture: .longPress, mode: .number))
        XCTAssertNotNil(action.unavailabilityReason(for: .spaceConvert, gesture: .tap, mode: .japanese))
        XCTAssertNotNil(action.unavailabilityReason(for: .paste, gesture: .longPress, mode: .japanese))
    }

    func testCursorMoveModeIsAvailableOnlyForJapaneseSpaceConvertLongPress() {
        let action = SumireSpecialKeyAction.cursorMoveMode

        XCTAssertNil(action.unavailabilityReason(for: .spaceConvert, gesture: .longPress, mode: .japanese))
        XCTAssertNotNil(action.unavailabilityReason(for: .spaceConvert, gesture: .longPress, mode: .english))
        XCTAssertNotNil(action.unavailabilityReason(for: .spaceConvert, gesture: .tap, mode: .japanese))
        XCTAssertNotNil(action.unavailabilityReason(for: .paste, gesture: .longPress, mode: .japanese))
    }
    func testPersistedExplicitHoldOverridesTapAndOnlyRepeatableTapRepeats() throws {
        var settings = SumireSpecialKeySettings()
        try settings.set(.deleteBackward, for: .spaceConvert, gesture: .tap,
            arrangement: .toggle, mode: .japanese)
        XCTAssertEqual(settings.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: false), .deleteBackward)
        try settings.set(.cursorMoveMode, for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese)
        let restored = try SumireSpecialKeySettings.decode(JSONEncoder().encode(settings))
        XCTAssertEqual(restored.action(for: .spaceConvert, gesture: .longPress,
            arrangement: .toggle, mode: .japanese, hasComposition: true), .cursorMoveMode)
        XCTAssertFalse(SumireSpecialKeyAction.cursorMoveMode.isRepeatable)
        XCTAssertFalse(SumireSpecialKeyAction.cycleBunsetsuSplitPattern.isRepeatable)
        XCTAssertNotNil(SumireSpecialKeyAction.deleteAfterCursorUntilBoundary.unavailabilityReason(
            for: .delete, gesture: .up, mode: .japanese))
    }

}
