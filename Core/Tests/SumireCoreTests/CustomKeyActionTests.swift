import XCTest
@testable import SumireCore

final class CustomKeyActionTests: XCTestCase {
    func testTextAndCommandRemainDistinctAndUnknownDoesNotBecomeText() throws {
        let targets = CustomLayoutTargets(layouts: [])
        XCTAssertEqual(CustomKeyAction.tap("Text:Delete", targets: targets), .text("Delete"))
        XCTAssertEqual(CustomKeyAction.tap("InputText:🌸", targets: targets), .inputText("🌸"))
        XCTAssertEqual(CustomKeyAction.tap("Delete", targets: targets), .command(.delete))
        XCTAssertEqual(CustomKeyAction.flick(type: "DELETE", value: "表示名", targets: targets), .command(.delete))
        XCTAssertEqual(CustomKeyAction.tap("MoveCustomKeyboardTab", targets: targets), .command(.moveCustomKeyboardTab))
        XCTAssertEqual(CustomKeyAction.flick(type: "MoveCustomKeyboardTab", value: "⇄", targets: targets), .command(.moveCustomKeyboardTab))
        XCTAssertEqual(CustomKeyAction.flick(type: "INPUT_TEXT", value: "Delete", targets: targets), .text("Delete"))
        if case .unsupported(let raw, _) = CustomKeyAction.tap("VoiceInput", targets: targets) { XCTAssertEqual(raw, "VoiceInput") }
        else { XCTFail("Unsupported action must not silently change behavior") }
    }
    func testLegacyLayoutReferencesAndReviewPreserveUnresolvedActions() throws {
        let json = #"[{"layout":{"layoutId":11,"stableId":"a","name":"A","rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"keyIdentifier":"key","action":"MoveToCustomKeyboard:12","doubleTapAction":"VoiceInput"},"flicks":[{"actionType":"MoveToCustomKeyboard","actionValue":"missing"}]}]},{"layout":{"layoutId":12,"stableId":"b","name":"B","rowCount":1,"columnCount":1},"keysWithFlicks":[]}]"#
        let preview = try CustomLayoutImportPreview.parse(Data(json.utf8))
        XCTAssertEqual(preview.layouts.count, 2)
        let targets = CustomLayoutTargets(layouts: preview.layouts)
        XCTAssertEqual(CustomKeyAction.tap("MoveToCustomKeyboard:12", targets: targets), .switchLayout("b"))
        XCTAssertEqual(CustomKeyAction.flick(type: "MoveToCustomKeyboard", value: "b", targets: targets), .switchLayout("b"))
        let review = CustomLayoutActionReview(layouts: preview.layouts)
        XCTAssertEqual(review.items.count, 3)
        XCTAssertEqual(review.unsupported.count, 2)
        XCTAssertEqual(review.unsupported.map(\.keyID), ["key", "key"])
        let ambiguous = CustomLayoutTargets(layouts: preview.layouts + [preview.layouts[1]])
        if case .unsupported = CustomKeyAction.tap("MoveToCustomKeyboard:12", targets: ambiguous) {} else { XCTFail("Ambiguous reference") }
    }
}
