import XCTest
import UIKit
@testable import Sumire

@MainActor final class DocumentForwardDeleteTests: XCTestCase {
    private final class Proxy: NSObject, UITextDocumentProxy {
        let text = UITextView()
        var contextAvailable = true
        var movements: [Int] = []
        var deletions = 0
        let documentIdentifier = UUID()
        var documentInputMode: UITextInputMode? { nil }
        var hasText: Bool { text.hasText }
        var documentContextBeforeInput: String? {
            contextAvailable ? (text.text as NSString).substring(to: text.selectedRange.location) : nil
        }
        var documentContextAfterInput: String? {
            contextAvailable ? (text.text as NSString).substring(from: NSMaxRange(text.selectedRange)) : nil
        }
        var selectedText: String? {
            text.selectedRange.length > 0 ? (text.text as NSString).substring(with: text.selectedRange) : nil
        }
        func insertText(_ text: String) { self.text.insertText(text) }
        func deleteBackward() { deletions += 1; text.deleteBackward() }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            movements.append(offset)
            guard let selection = text.selectedTextRange,
                  let target = text.position(from: selection.start, offset: offset),
                  let range = text.textRange(from: target, to: target) else {
                XCTFail("Fixture could not resolve public UITextInput relative position"); return
            }
            text.selectedTextRange = range
        }
        func setMarkedText(_ markedText: String, selectedRange: NSRange) { XCTFail("Forward deletion must not create a mark") }
        func unmarkText() { XCTFail("Forward deletion must not change marked ownership") }
    }

    func testProxyKnownNextCharacterUsesUTF16OffsetAndDeletesOneGrapheme() {
        for next in ["あ", "👩‍💻", "か\u{3099}", "🇯🇵"] {
            let proxy = Proxy()
            proxy.text.text = "前" + next + "後"
            proxy.text.selectedRange = NSRange(location: 1, length: 0)
            DocumentForwardDelete.apply(to: proxy)
            XCTAssertEqual(proxy.text.text, "前後")
            XCTAssertEqual(proxy.text.selectedRange, NSRange(location: 1, length: 0))
            XCTAssertEqual(proxy.movements, [next.utf16.count])
            XCTAssertEqual(proxy.deletions, 1)
        }
    }
    func testProxySelectionIsDeletedWithoutMovingEvenWithUnknownContext() {
        let proxy = Proxy()
        proxy.text.text = "前👩‍💻後"
        proxy.text.selectedRange = NSRange(location: 1, length: "👩‍💻".utf16.count)
        proxy.contextAvailable = false
        DocumentForwardDelete.apply(to: proxy)
        XCTAssertEqual(proxy.text.text, "前後")
        XCTAssertEqual(proxy.movements, [])
        XCTAssertEqual(proxy.deletions, 1)
    }
    func testProxyUnknownOrEmptyAfterContextIsNoOp() {
        for unknown in [false, true] {
            let proxy = Proxy()
            proxy.text.text = "前後"
            proxy.text.selectedRange = NSRange(location: unknown ? 1 : 2, length: 0)
            proxy.contextAvailable = !unknown
            let selection = proxy.text.selectedRange
            DocumentForwardDelete.apply(to: proxy)
            XCTAssertEqual(proxy.text.text, "前後")
            XCTAssertEqual(proxy.text.selectedRange, selection)
            XCTAssertEqual(proxy.movements, [])
            XCTAssertEqual(proxy.deletions, 0)
        }
    }
    func testHarnessSelectionEndAndNilTextDoNotDeleteAnotherCharacter() {
        let text = UITextView()
        text.text = "前👩‍💻後"
        text.selectedRange = NSRange(location: 1, length: "👩‍💻".utf16.count)
        InputHarness.deleteForward(in: text)
        XCTAssertEqual(text.text, "前後")
        XCTAssertEqual(text.selectedRange, NSRange(location: 1, length: 0))
        text.selectedRange = NSRange(location: 2, length: 0)
        InputHarness.deleteForward(in: text)
        XCTAssertEqual(text.text, "前後")
        XCTAssertEqual(text.selectedRange, NSRange(location: 2, length: 0))
        InputHarness.deleteForward(in: nil)
    }
    func testHarnessDoesNotDeleteFromInsideGraphemeBoundary() {
        let text = UITextView()
        text.text = "前👩‍💻後"
        text.selectedRange = NSRange(location: 2, length: 0)
        let actual = text.selectedRange
        XCTAssertEqual(actual, NSRange(location: 2, length: 0), "Fixture must expose an unknown grapheme boundary")
        InputHarness.deleteForward(in: text)
        XCTAssertEqual(text.text, "前👩‍💻後")
        XCTAssertEqual(text.selectedRange, actual)
    }
}
