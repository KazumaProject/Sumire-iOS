import XCTest

final class KeyboardSurfaceSizingTests: XCTestCase {
    func testHeightBudgetUsesScreenBoundsInsteadOfKeyboardWindowBounds() {
        XCTAssertEqual(
            KeyboardSurfaceSizingPlan.availableHeight(screenHeight: 896, windowHeight: 340),
            896)
    }

    func testHeightBudgetFallsBackOnlyWhenScreenBoundsAreUnavailable() {
        XCTAssertEqual(
            KeyboardSurfaceSizingPlan.availableHeight(screenHeight: .nan, windowHeight: 340),
            340)
        XCTAssertEqual(
            KeyboardSurfaceSizingPlan.availableHeight(screenHeight: nil, windowHeight: nil),
            1000)
    }

    func testShortKeyboardHostWindowDoesNotSquashConfiguredRows() {
        let screenHeight = KeyboardSurfaceSizingPlan.availableHeight(
            screenHeight: 874,
            windowHeight: 320)
        let plan = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 275,
            candidateHeight: 132,
            bottomInset: 34,
            availableHeight: screenHeight)

        XCTAssertEqual(screenHeight, 874)
        XCTAssertEqual(plan.keyAreaHeight, 275)
        XCTAssertEqual(plan.candidateHeight, 132)
        XCTAssertEqual(plan.totalHeight, 441)
    }

    func testThreeRowsGrowTheKeyboardWhenThereIsRoom() {
        let plan = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 275,
            candidateHeight: 132,
            bottomInset: 34,
            availableHeight: 896)

        XCTAssertEqual(plan.keyAreaHeight, 275)
        XCTAssertEqual(plan.candidateHeight, 132)
        XCTAssertEqual(plan.totalHeight, 441)
    }

    func testConstrainedHostKeepsKeyAreaStableAndClipsCandidateViewport() {
        let oneRow = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 275,
            candidateHeight: 44,
            bottomInset: 0,
            availableHeight: 400)
        let threeRows = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 275,
            candidateHeight: 132,
            bottomInset: 0,
            availableHeight: 400)

        XCTAssertEqual(oneRow.keyAreaHeight, 244)
        XCTAssertEqual(threeRows.keyAreaHeight, oneRow.keyAreaHeight)
        XCTAssertEqual(threeRows.candidateHeight, 44)
        XCTAssertEqual(threeRows.totalHeight, oneRow.totalHeight)
        XCTAssertEqual(threeRows.totalHeight, 288)
    }

    func testLargeSavedKeyboardUsesCandidateScrollBeforeShrinkingKeys() {
        let oneRow = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 600,
            candidateHeight: 44,
            bottomInset: 0,
            availableHeight: 896)
        let threeRows = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: 600,
            candidateHeight: 132,
            bottomInset: 0,
            availableHeight: 896)

        XCTAssertEqual(oneRow.keyAreaHeight, 600)
        XCTAssertEqual(threeRows.keyAreaHeight, oneRow.keyAreaHeight)
        XCTAssertEqual(threeRows.candidateHeight, 44)
    }
}
