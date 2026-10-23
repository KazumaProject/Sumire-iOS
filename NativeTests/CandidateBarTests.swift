import XCTest
import UIKit
import CoreText
import SumireCore
@testable import Sumire

final class CandidateBarTests: XCTestCase {
    @MainActor
    func testMacroClipboardPasteControlRequiresAnEnabledClipboardMacro() {
        let disabled = PersonalTextMacro(name: "disabled", body: "{clipboard}", enabled: false)
        let enabled = PersonalTextMacro(name: "enabled", body: "{clipboard}")
        let palette = Sumire.KeyboardPalette(hue: 0.73, dark: false)

        func pasteControl(for macros: [PersonalTextMacro], canUseContext: Bool = true) -> UIPasteControl? {
            let panel = Sumire.KeyboardTextMacroPanel(macros: macros, palette: palette,
                                                       canUseContext: canUseContext, hasSelection: false)
            return panel.subviews.compactMap { $0 as? UIPasteControl }
                .first { $0.accessibilityIdentifier == "text-macro-clipboard-paste" }
        }

        XCTAssertTrue(pasteControl(for: [disabled])?.isHidden ?? false)
        XCTAssertFalse(pasteControl(for: [enabled])?.isHidden ?? true)
        XCTAssertTrue(pasteControl(for: [enabled], canUseContext: false)?.isHidden ?? false)
    }
    func testProductionBridgePreservesPrimaryNumericAndPersonalOrigins() throws {
        let service = ConversionService(categoryMask: 0)
        func convert(_ reading: String, generation: UInt64) throws -> [ConversionCandidate] {
            let completed = expectation(description: "Primary presentation metadata")
            var response: Result<ConversionResponse, Error>?
            service.convert(reading, generation: generation, editStart: 0) { response = $0; completed.fulfill() }
            wait(for: [completed], timeout: 20)
            return try XCTUnwrap(response).get().candidates
        }
        for (index, entry) in [("12", "[半]"), ("１２", "[全]")].enumerated() {
            let candidates = try convert(entry.0, generation: UInt64(index + 1))
            let primary = try XCTUnwrap(candidates.first { $0.text == entry.0 && !$0.dictionaries.isEmpty })
            XCTAssertEqual(primary.displayAnnotation, entry.1)
        }
        var personal = PersonalLexicon()
        personal.words = [PersonalWord(word: "１", reading: "ばっじ", posScore: -10000)]
        service.setPersonal(personal)
        let candidates = try convert("ばっじ", generation: 3)
        let user = try XCTUnwrap(candidates.first { $0.text == "１" && $0.dictionaries.contains("user") })
        XCTAssertNil(user.displayAnnotation)
        XCTAssertEqual(user.presentationKind, .none)
    }
    private func withBar(rows: Int = 1, _ body: @escaping (CandidateBar, UICollectionView) -> Void) {
        let finished = expectation(description: "Rendered candidate bar")
        DispatchQueue.main.async {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIViewController()
            window.rootViewController = controller
            let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 390, height: CGFloat(rows * 44)))
            bar.backgroundColor = .white
            bar.rowCount = rows
            bar.clipboardAccessAllowed = false
            controller.view.addSubview(bar)
            window.isHidden = false
            bar.showsShortcuts = false
            window.layoutIfNeeded()
            let collection = bar.subviews.compactMap { $0 as? UICollectionView }.first!
            body(bar, collection)
            window.isHidden = true
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testAnnotationsPreserveRowsDuplicateSelectionAndClearOnPlainUpdate() {
        for rows in 1...3 {
            for expanded in [false, true] {
                withBar(rows: rows) { bar, list in
                    if expanded { bar.useExpandedLayout() }
                    bar.setCandidates([.init(text: "橋", annotation: "[部]"),
                                       .init(text: "橋", annotation: "[読] はし")])
                    bar.layoutIfNeeded(); list.layoutIfNeeded()
                    for index in 0..<2 {
                        let path = IndexPath(item: index, section: 0)
                        let cell = list.cellForItem(at: path)
                        cell?.layoutIfNeeded()
                        XCTAssertEqual(cell?.accessibilityLabel, "橋")
                        XCTAssertEqual(cell?.accessibilityValue, index == 0 ? "[部]" : "[読] はし")
                        XCTAssertEqual(cell?.bounds.height, 44)
                        let label = cell?.contentView.subviews.compactMap { $0 as? UILabel }
                            .first { $0.accessibilityIdentifier == "candidate-annotation" }
                        XCTAssertFalse(label?.isHidden ?? true)
                        XCTAssertGreaterThan(label?.frame.width ?? 0, 0)
                    }
                    var selected: Int?
                    bar.onSelect = { selected = $0 }
                    bar.collectionView(list, didSelectItemAt: IndexPath(item: 1, section: 0))
                    XCTAssertEqual(selected, 1)
                    bar.candidates = ["橋", "橋"]
                    bar.layoutIfNeeded(); list.layoutIfNeeded()
                    XCTAssertNil(list.cellForItem(at: IndexPath(item: 0, section: 0))?.accessibilityValue)
                }
            }
        }
    }

    func testLongAnnotationTruncatesBeforeCandidateInNarrowBar() {
        withBar { bar, list in
            bar.frame.size.width = 120
            bar.setCandidates([.init(text: "橋", annotation: "[読] " + String(repeating: "はし", count: 40))])
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            let path = IndexPath(item: 0, section: 0)
            let cell = list.cellForItem(at: path)!
            cell.layoutIfNeeded()
            let title = cell.contentView.subviews.compactMap { $0 as? UILabel }.first!
            XCTAssertGreaterThanOrEqual(title.frame.width, HistoricKanaFont.attributed("橋").size().width)
            XCTAssertGreaterThanOrEqual(title.frame.minX, 0)
            XCTAssertLessThanOrEqual(title.frame.maxX, cell.contentView.bounds.width)
            XCTAssertEqual(cell.bounds.height, 44)
            let identity = ObjectIdentifier(cell)
            bar.setCandidates([.init(text: "橋", annotation: "[部]")])
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            XCTAssertEqual(list.cellForItem(at: path).map(ObjectIdentifier.init), identity)
            XCTAssertEqual(list.cellForItem(at: path)?.accessibilityValue, "[部]")
        }
    }

    func testDisplayMergePreservesFirstBehaviorAndUnionsDictionaryLabels() {
        let first = ConversionCandidate(id: 11, text: "橋", score: 90,
            range: NSRange(location: 0, length: 1), dictionaries: ["system"], isReadingPrefix: true,
            classifiedCategories: ["term"])
        let duplicate = ConversionCandidate(id: 12, text: "橋", score: 1,
            range: NSRange(location: 0, length: 2), dictionaries: ["category", "system"],
            presentationKind: .fullWidth, classifiedCategories: ["person", "term"])
        let distinct = ConversionCandidate(id: 13, text: "箸", score: 2,
            range: NSRange(location: 0, length: 2), dictionaries: [])
        let merged = ConversionCandidate.mergedForDisplay([first, distinct, duplicate])
        XCTAssertEqual(merged.map(\.id), [11, 13])
        XCTAssertEqual(merged[0].score, 90)
        XCTAssertEqual(merged[0].range, first.range)
        XCTAssertEqual(merged[0].displayAnnotation, "[部] [人名・用語]")
        XCTAssertEqual(merged[0].dictionaries, ["system", "category"])
        XCTAssertEqual(merged[0].presentationKind, .none)
    }

    func testOriginBadgesDoNotInferPrimaryKindFromSurface() {
        func candidate(_ text: String, _ kind: ConversionCandidate.PresentationKind) -> ConversionCandidate {
            ConversionCandidate(id: 1, text: text, score: 1,
                range: NSRange(location: 0, length: 1), dictionaries: ["person"], presentationKind: kind)
        }
        XCTAssertNil(candidate("ｶﾞ", .none).displayAnnotation)
        XCTAssertEqual(candidate("ｶﾞ", .halfWidth).displayAnnotation, "[半]")
        XCTAssertEqual(candidate("Ａ", .fullWidth).displayAnnotation, "[全]")
        for text in ["1", "!?", " "] { XCTAssertEqual(candidate(text, .numericSymbol).displayAnnotation, "[半]") }
        for text in ["１", "！？", "　"] { XCTAssertEqual(candidate(text, .numericSymbol).displayAnnotation, "[全]") }
        for text in ["abc", "123", "Ａ", "ｶﾞ", "1！", ""] { XCTAssertNil(candidate(text, .numericSymbol).displayAnnotation, text) }
    }

    func testCorrectionAndCategoryBadgesRenderAndKeepCommitIdentity() {
        let candidate = ConversionCandidate(id: 50, text: "橋", score: 4,
            range: NSRange(location: 0, length: 1), dictionaries: ["system"],
            rawText: "橋\tはし", correctedReading: "はし", isReadingPrefix: true,
            classifiedCategories: ["term", "unknown", "person", "term"])
        XCTAssertEqual(candidate.displayAnnotation, "[読] はし [人名・用語]")
        for expanded in [false, true] {
            withBar { bar, list in
                if expanded { bar.useExpandedLayout() }
                bar.setCandidates([.init(text: candidate.text, annotation: candidate.displayAnnotation)])
                bar.layoutIfNeeded(); list.layoutIfNeeded()
                let cell = list.cellForItem(at: IndexPath(item: 0, section: 0))
                XCTAssertEqual(cell?.accessibilityValue, candidate.displayAnnotation)
                var selected: ConversionCandidate?
                bar.onSelect = { _ in selected = candidate }
                bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
                XCTAssertEqual(selected?.id, 50)
                XCTAssertEqual(selected?.text, "橋")
                XCTAssertEqual(selected?.range.length, 1)
            }
        }
    }

    func testMergedCandidatesSelectFirstIdentityInNormalAndExpandedBars() {
        let candidates = ConversionCandidate.mergedForDisplay([
            ConversionCandidate(id: 41, text: "橋", score: 0,
                range: NSRange(location: 0, length: 1), dictionaries: [], isReadingPrefix: true),
            ConversionCandidate(id: 42, text: "橋", score: 1,
                range: NSRange(location: 0, length: 2), dictionaries: []),
            ConversionCandidate(id: 43, text: "橋", score: 2,
                range: NSRange(location: 0, length: 2), dictionaries: [],
                rawText: "橋\tはし", correctedReading: "はし")])
        for expanded in [false, true] {
            withBar(rows: 3) { bar, list in
                if expanded { bar.useExpandedLayout() }
                bar.setCandidates(candidates.map { .init(text: $0.text, annotation: $0.displayAnnotation) })
                bar.layoutIfNeeded(); list.layoutIfNeeded()
                XCTAssertEqual(list.numberOfItems(inSection: 0), 2)
                var selected: ConversionCandidate?
                bar.onSelect = { selected = candidates[$0] }
                bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
                XCTAssertEqual(selected?.id, 41)
                XCTAssertEqual(selected?.range.length, 1)
                bar.collectionView(list, didSelectItemAt: IndexPath(item: 1, section: 0))
                XCTAssertEqual(selected?.id, 43)
                XCTAssertEqual(selected?.text, "橋")
                XCTAssertEqual(selected?.correctedReading, "はし")
            }
        }
    }

    func testDisplayMergeKeepsCorrectionRawIdentityAndCanonicalDistinctStrings() {
        func candidate(_ id: UInt64, _ text: String, raw: String? = nil, correction: String? = nil) -> ConversionCandidate {
            ConversionCandidate(id: id, text: text, score: 0,
                range: NSRange(location: 0, length: 2), dictionaries: [],
                rawText: raw, correctedReading: correction)
        }
        let merged = ConversionCandidate.mergedForDisplay([
            candidate(1, "橋"), candidate(2, "橋", raw: "橋\tはし", correction: "はし"),
            candidate(3, "橋", raw: "橋\tはし", correction: "はし"),
            candidate(4, "が"), candidate(5, "か\u{3099}")])
        XCTAssertEqual(merged.map(\.id), [1, 2, 4, 5])
        XCTAssertEqual(merged[1].text, "橋")
        XCTAssertEqual(merged[1].displayAnnotation, "[読] はし")
        XCTAssertEqual(Array(merged[3].text.utf16), [0x304B, 0x3099])
    }

    func testCorrectionAnnotationDoesNotChangeCommitText() {
        let candidate = ConversionCandidate(id: 1, text: "雰囲気", score: 0,
            range: NSRange(location: 0, length: 4), dictionaries: [],
            rawText: "雰囲気\tふんいき", correctedReading: "ふんいき", isReadingPrefix: true)
        XCTAssertEqual(candidate.displayAnnotation, "[読] ふんいき")
        XCTAssertEqual(candidate.text, "雰囲気")
        XCTAssertEqual(ConversionCandidate(id: 2, text: "橋", score: 0,
            range: NSRange(location: 0, length: 2), dictionaries: [],
            isReadingPrefix: true).displayAnnotation, "[部]")
    }

    func testHistoricKanaCandidateUsesBundledFontWithoutChangingSelection() {
        for expanded in [false, true] {
            withBar { bar, list in
                if expanded { bar.useExpandedLayout() }
                let text = "👩‍💻か\u{3099}\u{1B005}\u{1B116}を"
                bar.candidates = [text]
                bar.layoutIfNeeded(); list.layoutIfNeeded()
                let path = IndexPath(item: 0, section: 0)
                let cell = list.cellForItem(at: path)
                let label = cell?.contentView.subviews.compactMap { $0 as? UILabel }.first
                XCTAssertEqual(label?.attributedText?.string, text)
                XCTAssertEqual(cell?.accessibilityLabel, text)
                let range = (text as NSString).range(of: "\u{1B005}")
                let font = label?.attributedText?.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
                XCTAssertEqual(font?.fontName, HistoricKanaFont.assetName)
                var selected: String?
                bar.onSelect = { selected = bar.candidates[$0] }
                bar.collectionView(list, didSelectItemAt: path)
                XCTAssertEqual(selected, text)
                let size = bar.collectionView(list, layout: list.collectionViewLayout, sizeForItemAt: path)
                XCTAssertEqual(size.width, min(max(44, HistoricKanaFont.attributed(text).size().width + 32), max(44, list.bounds.width)))
            }
        }
    }

    func testProductionConversionHistoricKanaReachesCandidateCellWithoutScalarLoss() throws {
        let font = try XCTUnwrap(HistoricKanaFont.fallback(size: 18))
        let characterSet = CTFontCopyCharacterSet(font as CTFont) as CharacterSet
        let bundledDictionary = try XCTUnwrap(ConversionService.bundledDictionary)
        let readings = ["を", "にほんご", "とうきょう", "かっこんとう"]
        let categoryMasks: [UInt32] = [0, 0x3fff_ffff]
        var generation: UInt64 = 1
        var foundWholeCandidateForWo = false
        var historicScalars = Set<UInt32>()
        var displayCandidates: [(text: String, annotation: String?)] = []

        for categoryMask in categoryMasks {
            let service = ConversionService(directory: bundledDictionary, categoryMask: categoryMask)
            service.setPersonal(PersonalLexicon())
            service.setLearning(url: nil)
            service.setEnglishReading(true)
            for reading in readings {
                let converted = expectation(description: "Production conversion candidate fixture")
                var result: Result<ConversionResponse, Error>?
                service.convert(reading, generation: generation, editStart: 0) {
                    result = $0
                    converted.fulfill()
                }
                wait(for: [converted], timeout: 20)
                generation += 1

                let response = try XCTUnwrap(result).get()
                XCTAssertTrue(response.complete)
                if categoryMask == 0 && reading == "を" {
                    foundWholeCandidateForWo = response.candidates.contains {
                        $0.text.unicodeScalars.map(\.value) == [0x1B005]
                    }
                }

                for candidate in response.candidates where candidate.text.unicodeScalars.contains(where: {
                    (0x1B000...0x1B16F).contains($0.value)
                }) {
                    if !displayCandidates.contains(where: { $0.text == candidate.text && $0.annotation == candidate.displayAnnotation }) {
                        displayCandidates.append((candidate.text, candidate.displayAnnotation))
                    }
                    for scalar in candidate.text.unicodeScalars where (0x1B000...0x1B16F).contains(scalar.value) {
                        historicScalars.insert(scalar.value)
                        XCTAssertTrue(characterSet.contains(scalar), String(format: "U+%05X is absent from the bundled font", scalar.value))
                        let attributed = HistoricKanaFont.attributed(String(scalar))
                        let selectedFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
                        XCTAssertEqual(selectedFont?.fontName, HistoricKanaFont.assetName,
                                       String(format: "U+%05X did not select the bundled font", scalar.value))

                        let line = CTLineCreateWithAttributedString(attributed)
                        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                        var glyphs: [CGGlyph] = []
                        for run in runs {
                            let count = CTRunGetGlyphCount(run)
                            var runGlyphs = [CGGlyph](repeating: 0, count: count)
                            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
                            glyphs.append(contentsOf: runGlyphs)
                        }
                        XCTAssertFalse(glyphs.isEmpty, String(format: "U+%05X produced no glyph", scalar.value))
                        XCTAssertTrue(glyphs.allSatisfy { $0 != 0 }, String(format: "U+%05X produced a missing glyph", scalar.value))
                    }
                    XCTAssertEqual(HistoricKanaFont.attributed(candidate.text).string.unicodeScalars.map(\.value),
                                   candidate.text.unicodeScalars.map(\.value),
                                   "Historic-kana font attribution must preserve candidate scalars")
                }
            }
        }

        XCTAssertTrue(foundWholeCandidateForWo, "The production fixture for を should include whole-candidate U+1B005")
        XCTAssertTrue(historicScalars.contains(0x1B005), "The production fixtures should exercise U+1B005")
        XCTAssertFalse(displayCandidates.isEmpty, "Production fixtures should include historical-kana candidates")

        withBar(rows: 3) { bar, list in
            bar.useExpandedLayout()
            bar.setCandidates(displayCandidates.map { .init(text: $0.text, annotation: $0.annotation) })
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            XCTAssertEqual(list.numberOfItems(inSection: 0), displayCandidates.count)
            for (index, candidate) in displayCandidates.enumerated() {
                let path = IndexPath(item: index, section: 0)
                list.scrollToItem(at: path, at: .centeredVertically, animated: false)
                list.layoutIfNeeded()
                let cell = list.cellForItem(at: path)
                let label = cell?.contentView.subviews.compactMap { $0 as? UILabel }.first
                XCTAssertEqual(label?.attributedText?.string.unicodeScalars.map(\.value), candidate.text.unicodeScalars.map(\.value))
                XCTAssertEqual(cell?.accessibilityLabel?.unicodeScalars.map(\.value), candidate.text.unicodeScalars.map(\.value))
                if let cell {
                    let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
                        cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "historic-kana-candidate-\(index)"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
                var offset = 0
                for scalar in candidate.text.unicodeScalars {
                    if (0x1B000...0x1B16F).contains(scalar.value) {
                        let selectedFont = label?.attributedText?.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
                        XCTAssertEqual(selectedFont?.fontName, HistoricKanaFont.assetName,
                                       String(format: "Candidate %d U+%05X", index, scalar.value))
                    }
                    offset += scalar.utf16.count
                }
            }
        }
    }

    func testThreeRowsPackVariableWidthsWithoutBlankColumns() {
        withBar(rows: 3) { bar, list in
            bar.candidates = ["か", "株式会社", "かな", "神奈川県横浜市", "家", "加", "蚊", "科学", "カメラ", "漢字", "課", "仮名"]
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            list.visibleCells.forEach { $0.layoutIfNeeded() }
            let first = list.cellForItem(at: IndexPath(item: 0, section: 0))
            let middle = list.cellForItem(at: IndexPath(item: 1, section: 0))
            let last = list.cellForItem(at: IndexPath(item: 2, section: 0))
            XCTAssertEqual(first?.accessibilityLabel, "か")
            XCTAssertEqual(middle?.accessibilityLabel, "株式会社")
            XCTAssertEqual(last?.accessibilityLabel, "かな")
            XCTAssertEqual(first?.contentView.bounds.height ?? 0, 44)
            XCTAssertEqual(middle?.contentView.bounds.height ?? 0, 44)
            XCTAssertEqual(last?.contentView.bounds.height ?? 0, 44)
            let labels = [first, middle, last].compactMap { cell in
                cell?.contentView.subviews.compactMap { $0 as? UILabel }.first
            }
            XCTAssertEqual(labels.count, 3)
            XCTAssertEqual(labels.map(\.text), ["か", "株式会社", "かな"])
            for label in labels {
                XCTAssertGreaterThan(label.frame.height, 0)
                XCTAssertGreaterThanOrEqual(label.frame.minY, 0)
                XCTAssertLessThanOrEqual(label.frame.maxY, label.superview?.bounds.maxY ?? 0)
            }
            var didDrawHierarchy = false
            let image = UIGraphicsImageRenderer(bounds: bar.bounds).image { _ in
                didDrawHierarchy = bar.drawHierarchy(in: bar.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(didDrawHierarchy)
            let attachment = XCTAttachment(image: image); attachment.name = "three-row-variable-width"; attachment.lifetime = .keepAlways
            self.add(attachment)
            let attributes = (0..<bar.candidates.count).compactMap { list.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            XCTAssertEqual(list.adjustedContentInset, .zero)
            XCTAssertEqual(Set(attributes.map { $0.frame.minY }).count, 3)
            for row in Dictionary(grouping: attributes, by: { $0.frame.minY }).values {
                let sorted = row.sorted { $0.frame.minX < $1.frame.minX }
                for pair in zip(sorted, sorted.dropFirst()) {
                    XCTAssertEqual(pair.1.frame.minX - pair.0.frame.maxX, 6, accuracy: 0.5)
                }
            }
        }
    }

    func testSavedThreeRowsKeepTheirHeightWhileShortcutsAreVisible() {
        withBar(rows: 3) { bar, list in
            XCTAssertEqual(bar.displayedHeight, 132)
            bar.showsShortcuts = true
            XCTAssertEqual(bar.rowCount, 3)
            XCTAssertEqual(bar.displayedHeight, 132)
            XCTAssertEqual(bar.requestedDisplayedHeight, 132)
            bar.showsShortcuts = false
            XCTAssertEqual(bar.rowCount, 3)
            XCTAssertEqual(bar.displayedHeight, 132)
        }
    }

    func testConstrainedHeightIsEqualWhileIdleAndComposing() {
        withBar(rows: 3) { bar, _ in
            bar.setDisplayedHeightLimit(90)
            XCTAssertEqual(bar.displayedHeight, 88)
            bar.showsShortcuts = true
            XCTAssertEqual(bar.displayedHeight, 88)
            XCTAssertEqual(bar.requestedDisplayedHeight, 132)
            let controls = bar.subviews.compactMap { $0 as? UIButton }
            bar.layoutIfNeeded()
            for control in controls { XCTAssertEqual(control.frame.height, 44) }
            bar.showsShortcuts = false
            XCTAssertEqual(bar.displayedHeight, 88)
        }
    }

    func testThreeRowRepackingPreservesSelectionAndFitsChangedWidth() {
        withBar(rows: 3) { bar, list in
            bar.candidates = (0..<24).map { $0 % 4 == 0 ? "長い変換候補\($0)" : "候補\($0)" }
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            bar.frame.size.width = 240
            bar.layoutIfNeeded(); list.layoutIfNeeded()
            bar.candidates = (0..<18).map { "更新\($0)" }
            list.layoutIfNeeded()
            var selected: Int?
            bar.onSelect = { selected = $0 }
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 7, section: 0))
            XCTAssertEqual(selected, 7)
            for index in 0..<18 {
                let attributes = list.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!
                XCTAssertEqual(attributes.frame.minY, CGFloat(index % 3) * 44)
                XCTAssertLessThanOrEqual(attributes.frame.width, ceil(list.bounds.width))
            }
        }
    }

    func testConfiguredThreeRowsSurviveFractionalCollectionHeight() {
        withBar(rows: 3) { bar, list in
            bar.candidates = (0..<6).map { "候補\($0)" }
            XCTAssertEqual(list.numberOfItems(inSection: 0), 6)

            // The keyboard host can report a fractional point after layout even
            // though the saved candidate setting still requests three 44pt rows.
            list.bounds.size.height = 131.5
            list.collectionViewLayout.invalidateLayout()
            list.collectionViewLayout.prepare()

            let rowOrigins = (0..<6).compactMap { index -> CGFloat? in
                list.collectionViewLayout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0))?.frame.minY
            }
            XCTAssertEqual(rowOrigins, [0, 44, 88, 0, 44, 88])
            XCTAssertEqual(bar.rowCount, 3)
        }
    }

    func testConstrainedThreeRowViewportScrollsToHiddenRows() {
        withBar(rows: 3) { bar, list in
            bar.candidates = (0..<9).map { "候補\($0)" }
            bar.setDisplayedHeightLimit(44)
            bar.frame.size.height = bar.displayedHeight
            bar.layoutIfNeeded(); list.layoutIfNeeded()

            XCTAssertEqual(bar.rowCount, 3)
            XCTAssertEqual(bar.requestedDisplayedHeight, 132)
            XCTAssertEqual(bar.displayedHeight, 44)
            XCTAssertTrue(list.alwaysBounceVertical)
            XCTAssertEqual(list.contentSize.height, 132)

            list.setContentOffset(CGPoint(x: 0, y: 88), animated: false)
            list.layoutIfNeeded()
            XCTAssertTrue(list.indexPathsForVisibleItems.contains(IndexPath(item: 2, section: 0)))
            XCTAssertFalse(list.indexPathsForVisibleItems.contains(IndexPath(item: 0, section: 0)))

            bar.rowCount = 1
            XCTAssertEqual(bar.rowCount, 1)
            XCTAssertEqual(list.contentOffset.y, 0)
        }
    }

    func testPendingUpdateKeepsFrameAndRejectsOldCandidateSelection() {
        withBar { bar, list in
            bar.candidates = ["東京", "東京都", "東京駅"]
            list.layoutIfNeeded()
            let first = list.cellForItem(at: IndexPath(item: 0, section: 0))
            XCTAssertNotNil(first)
            var selections: [Int] = []
            bar.onSelect = { selections.append($0) }
            bar.isUpdating = true
            XCTAssertEqual(list.numberOfItems(inSection: 0), 3)
            XCTAssertEqual(first?.accessibilityLabel, "東京")
            XCTAssertTrue(first?.accessibilityTraits.contains(.notEnabled) == true)
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertTrue(selections.isEmpty)
            bar.candidates = ["東京", "東京都", "東京湾"]
            XCTAssertTrue(first === list.cellForItem(at: IndexPath(item: 0, section: 0)))
            bar.isUpdating = false
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertEqual(selections, [0])
            XCTAssertFalse(first?.accessibilityTraits.contains(.notEnabled) ?? true)
        }
    }

    func testIdenticalResultsAndSelectionDoNotReplaceCells() {
        withBar { bar, list in
            bar.candidates = ["日本", "日本語"]
            list.layoutIfNeeded()
            let first = list.cellForItem(at: IndexPath(item: 0, section: 0))
            let second = list.cellForItem(at: IndexPath(item: 1, section: 0))
            XCTAssertNotNil(first); XCTAssertNotNil(second)
            bar.candidates = ["日本", "日本語"]
            bar.selectedIndex = 1
            XCTAssertTrue(first === list.cellForItem(at: IndexPath(item: 0, section: 0)))
            XCTAssertTrue(second === list.cellForItem(at: IndexPath(item: 1, section: 0)))
            XCTAssertFalse(first?.accessibilityTraits.contains(.selected) ?? true)
            XCTAssertTrue(second?.accessibilityTraits.contains(.selected) == true)
            bar.selectedIndex = nil
            XCTAssertFalse(second?.accessibilityTraits.contains(.selected) ?? true)
        }
    }

    func testExpandedListRetainsDuplicateCandidateIndicesDuringUpdates() {
        withBar { bar, list in
            bar.useExpandedLayout()
            bar.candidates = ["同じ", "別の候補", "同じ"]
            list.layoutIfNeeded()
            var selections: [Int] = []
            bar.onSelect = { selections.append($0) }
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 2, section: 0))
            XCTAssertEqual(selections, [2])
            bar.isUpdating = true
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 0, section: 0))
            XCTAssertEqual(selections, [2])
            bar.candidates = ["新しい候補", "同じ"]
            bar.isUpdating = false
            bar.collectionView(list, didSelectItemAt: IndexPath(item: 1, section: 0))
            XCTAssertEqual(selections, [2, 1])
            XCTAssertEqual((list.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection, .vertical)
        }
    }

    func testScrollableOffsetSurvivesUpdateAndClampsWhenListShrinks() {
        withBar { bar, list in
            bar.candidates = (0..<30).map { "候補\($0)" }
            list.layoutIfNeeded()
            list.setContentOffset(CGPoint(x: 200, y: 0), animated: false)
            let offset = list.contentOffset.x
            bar.candidates = (0..<30).map { $0 == 29 ? "末尾変更" : "候補\($0)" }
            XCTAssertEqual(list.contentOffset.x, offset, accuracy: 1)
            bar.candidates = ["ひとつ"]
            XCTAssertLessThanOrEqual(list.contentOffset.x, 0.5)
            XCTAssertEqual(list.numberOfItems(inSection: 0), 1)
            bar.candidates = []
            XCTAssertEqual(list.numberOfItems(inSection: 0), 0)
        }
    }
}
