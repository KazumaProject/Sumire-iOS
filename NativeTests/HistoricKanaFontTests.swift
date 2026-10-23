import XCTest
import UIKit
import CoreText
import CryptoKit

final class HistoricKanaFontTests: XCTestCase {
    func testBundledFontHasRealGlyphsForHistoricKanaCandidates() throws {
        let font = try XCTUnwrap(HistoricKanaFont.fallback(size: 18))
        XCTAssertEqual(font.fontName, "NotoSerifHentaigana-Regular")
        for point: UInt32 in [
            0x1B002, 0x1B003, 0x1B004, 0x1B005,
            0x1B116, 0x1B117, 0x1B118, 0x1B119, 0x1B11A, 0x1B11B, 0x1B11C
        ] {
            let text = String(UnicodeScalar(point)!)
            let line = CTLineCreateWithAttributedString(HistoricKanaFont.attributed(text))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            XCTAssertEqual(runs.count, 1)
            let run = try XCTUnwrap(runs.first)
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            XCTAssertFalse(glyphs.isEmpty)
            XCTAssertTrue(glyphs.allSatisfy { $0 != 0 }, String(format: "U+%05X", point))
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let actualFont = try XCTUnwrap(attributes[kCTFontAttributeName]) as! CTFont
            XCTAssertEqual(CTFontCopyPostScriptName(actualFont) as String, font.fontName)
        }
    }

    func testMixedTextPreservesScalarsAndUsesUTF16Ranges() throws {
        let text = "👨‍👩‍👧‍👦か\u{3099}\u{1B002}\u{1B003}\u{1B004}\u{1B005}\u{1B116}を✈️"
        let attributed = HistoricKanaFont.attributed(text)
        XCTAssertEqual(Array(attributed.string.utf16), Array(text.utf16))
        let normal = UIFont.systemFont(ofSize: 18).fontName
        var offset = 0
        for scalar in text.unicodeScalars {
            let font = try XCTUnwrap(attributed.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
            let historic = [0x1B002, 0x1B003, 0x1B004, 0x1B005, 0x1B116].contains(scalar.value)
            XCTAssertEqual(font.fontName, historic ? HistoricKanaFont.assetName : normal)
            offset += scalar.utf16.count
        }
        XCTAssertGreaterThan(attributed.size().width, 0)
    }

    func testBundledAssetIsPinnedAndLicenseAvailable() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: HistoricKanaFont.assetName, withExtension: "ttf"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 150_320)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), HistoricKanaFont.assetSHA256)
        let licenseURL = try XCTUnwrap(Bundle.main.url(forResource: "NotoSerifHentaigana-OFL", withExtension: "txt"))
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        XCTAssertTrue(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(license.contains("Copyright 2023 The Noto Project Authors"))
    }
}
