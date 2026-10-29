import XCTest

@testable import SumireCore

final class PhysicalKeyboardShortcutKeyTests: XCTestCase {
  func testCatalogMatchesAndroidShortcutKeyOrderAndHasUniqueKeyCodes() {
    let keys = PhysicalKeyboardShortcutKey.allCases
    let letterKeyCodes = Array(29...54)
    let digitKeyCodes = Array(7...16)
    let functionKeyCodes = Array(131...142)
    let punctuationKeyCodes: [Int] = [
      62, 66, 67, 112, 111, 61, 21, 22, 19, 20, 214, 213, 211, 212, 215, 218,
      69, 70, 71, 72, 73, 74, 75, 55, 56, 76, 68, 216, 217,
    ]
    let expectedKeyCodes = letterKeyCodes + digitKeyCodes + functionKeyCodes + punctuationKeyCodes

    let letterLabels: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) }
    let digitLabels: [String] = Array("0123456789").map { String($0) }
    let functionKeyLabels: [String] = (1...12).map { "F\($0)" }
    let punctuationLabels: [String] = [
      "Space", "Enter", "Backspace", "Delete", "Escape", "Tab", "Left", "Right", "Up",
      "Down", "Henkan", "Muhenkan", "Zenkaku/Hankaku", "Eisu", "Katakana/Hiragana",
      "Kana", "Minus", "Equals", "Left bracket", "Right bracket", "Backslash", "Semicolon",
      "Apostrophe", "Comma", "Period", "Slash", "Grave", "Yen", "Ro",
    ]
    let expectedLabels = letterLabels + digitLabels + functionKeyLabels + punctuationLabels

    XCTAssertEqual(keys.count, 77)
    XCTAssertEqual(keys.map(\.keyCode), expectedKeyCodes)
    XCTAssertEqual(keys.map(\.label), expectedLabels)
    XCTAssertEqual(Set(keys.map(\.keyCode)).count, keys.count)
  }

  func testCatalogContainsEveryDefaultBindingAndMapsJapaneseKeys() {
    let catalogCodes = Set(PhysicalKeyboardShortcutKey.allCases.map(\.keyCode))
    let defaultCodes = Set(PhysicalKeyboardShortcutDefaults.items.map(\.keyCode))

    XCTAssertTrue(defaultCodes.isSubset(of: catalogCodes))
    XCTAssertEqual(PhysicalKeyboardShortcutKey.fromKeyCode(214)?.label, "Henkan")
    XCTAssertEqual(PhysicalKeyboardShortcutKey.fromKeyCode(213)?.label, "Muhenkan")
    XCTAssertEqual(PhysicalKeyboardShortcutKey.fromKeyCode(212)?.label, "Eisu")
    XCTAssertNil(PhysicalKeyboardShortcutKey.fromKeyCode(-1))
  }

  func testJapaneseKeyLabelsMatchAndroidShortcutEditorResources() {
    let expected: [(keyCode: Int, label: String)] = [
      (21, "左"), (22, "右"), (19, "上"), (20, "下"),
      (214, "変換"), (213, "無変換"), (211, "全角/半角"), (212, "英数"),
      (215, "カタカナ/ひらがな"), (218, "かな"), (69, "マイナス"), (70, "イコール"),
      (71, "左角括弧"), (72, "右角括弧"), (73, "バックスラッシュ"), (74, "セミコロン"),
      (75, "アポストロフィ"), (55, "カンマ"), (56, "ピリオド"), (76, "スラッシュ"),
      (68, "グレイヴ"), (216, "円記号"), (217, "ろ"),
    ]

    for entry in expected {
      XCTAssertEqual(
        PhysicalKeyboardShortcutKey.fromKeyCode(entry.keyCode)?.displayLabel(languageCode: "ja"),
        entry.label,
        "Android Japanese label for Android key code \(entry.keyCode)"
      )
    }
    XCTAssertEqual(
      PhysicalKeyboardShortcutKey.fromKeyCode(21)?.displayLabel(languageCode: "ja-JP"), "左")
    XCTAssertEqual(
      PhysicalKeyboardShortcutKey.fromKeyCode(21)?.displayLabel(languageCode: "ja_JP"), "左")
  }

  func testNonJapaneseKeyLabelsUseTheStableCatalogFallback() {
    let key = PhysicalKeyboardShortcutKey.fromKeyCode(21)

    XCTAssertEqual(key?.displayLabel(languageCode: "en"), "Left")
    XCTAssertEqual(key?.displayLabel(languageCode: nil), "Left")
    XCTAssertEqual(
      PhysicalKeyboardShortcutKey.fromKeyCode(29)?.displayLabel(languageCode: "ja"), "A")
  }
}
