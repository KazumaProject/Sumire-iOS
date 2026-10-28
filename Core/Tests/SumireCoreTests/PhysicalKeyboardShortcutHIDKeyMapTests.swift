import XCTest

@testable import SumireCore

final class PhysicalKeyboardShortcutHIDKeyMapTests: XCTestCase {
  func testMapsEveryDefaultShortcutKeyToAnAndroidKeyCode() {
    let mappedKeyCodes = Set(
      PhysicalKeyboardShortcutDefaults.items.compactMap {
        PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: Self.hidUsage(for: $0.keyCode) ?? -1)
      }
    )

    XCTAssertEqual(mappedKeyCodes, Set(PhysicalKeyboardShortcutDefaults.items.map(\.keyCode)))
  }

  func testMapsAlphabetAndNumberRangesWithoutUsingCharacters() {
    XCTAssertEqual(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: 0x04), 29)  // A
    XCTAssertEqual(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: 0x1D), 54)  // Z
    XCTAssertEqual(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: 0x1E), 8)  // 1
    XCTAssertEqual(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: 0x26), 16)  // 9
    XCTAssertEqual(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: 0x27), 7)  // 0
  }

  func testMapsDefaultShortcutKeysAndJapaneseConversionKeys() {
    let cases: [(usage: Int, androidKeyCode: Int)] = [
      (0x06, 31),  // C
      (0x19, 50),  // V
      (0x1B, 52),  // X
      (0x2C, 62),  // Space
      (0x34, 75),  // Apostrophe
      (0x3F, 136),  // F6
      (0x40, 137),  // F7
      (0x41, 138),  // F8
      (0x42, 139),  // F9
      (0x43, 140),  // F10
      (0x4C, 112),  // Delete Forward
      (0x4F, 22),  // Right
      (0x50, 21),  // Left
      (0x51, 20),  // Down
      (0x52, 19),  // Up
      (0x87, 217),  // Ro
      (0x88, 215),  // Katakana/Hiragana
      (0x89, 216),  // Yen
      (0x8A, 214),  // Henkan
      (0x8B, 213),  // Muhenkan
      (0x90, 218),  // LANG1 / Kana switch
      (0x91, 212),  // LANG2 / Alphanumeric switch (Eisu)
      (0x94, 211),  // Zenkaku/Hankaku
    ]

    for testCase in cases {
      XCTAssertEqual(
        PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: testCase.usage),
        testCase.androidKeyCode,
        "HID usage 0x\(String(testCase.usage, radix: 16))"
      )
    }
  }

  func testMapsAllSupportedFunctionKeys() {
    for usage in 0x3A...0x45 {
      XCTAssertEqual(
        PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: usage),
        131 + usage - 0x3A
      )
    }
  }

  func testDoesNotGuessForUnsupportedOrModifierUsages() {
    for usage in [0, 0x32, 0x46, 0x65, 0x92, 0x93, 0xE0, 0xE7, 0xFFFF] {
      XCTAssertNil(PhysicalKeyboardShortcutHIDKeyMap.androidKeyCode(for: usage))
    }
  }

  /// Inverse of the tested subset needed by the Android default catalog.
  private static func hidUsage(for androidKeyCode: Int) -> Int? {
    switch androidKeyCode {
    case 7: return 0x27
    case 8...16: return 0x1E + androidKeyCode - 8
    case 19: return 0x52
    case 20: return 0x51
    case 21: return 0x50
    case 22: return 0x4F
    case 29...54: return 0x04 + androidKeyCode - 29
    case 55: return 0x36
    case 56: return 0x37
    case 61: return 0x2B
    case 62: return 0x2C
    case 66: return 0x28
    case 67: return 0x2A
    case 68: return 0x35
    case 69: return 0x2D
    case 70: return 0x2E
    case 71: return 0x2F
    case 72: return 0x30
    case 73: return 0x31
    case 74: return 0x33
    case 75: return 0x34
    case 76: return 0x38
    case 111: return 0x29
    case 112: return 0x4C
    case 131...142: return 0x3A + androidKeyCode - 131
    case 211: return 0x94
    case 213: return 0x8B
    case 214: return 0x8A
    case 215: return 0x88
    case 216: return 0x89
    case 217: return 0x87
    default: return nil
    }
  }
}
