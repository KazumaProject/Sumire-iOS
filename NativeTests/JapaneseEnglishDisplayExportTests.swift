import XCTest
import UIKit
import SumireCore

/// Synthetic hosted snapshots; never physical keyboard/editor acceptance.
@MainActor
final class JapaneseEnglishDisplayExportTests: XCTestCase {
    func testExportRealEnglishProductionDisplay() async throws {
        #if DEBUG
        throw XCTSkip("The provenance exporter requires Release")
        #else
        let readings = ["a", "A", "ab", "Ab", "AB", "app", "ApP", "APP", "iPh", "NASA", "zzzzq",
            "ａｂ", "Ａｂ", "ＡＢ", "＋", "　", "ａ＋ｂ", "a1", "a+b", "é", "123", "１２３"]
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        let provenance = try ConversionBenchmarkProvenance.collectFullDictionary(directory: directory)
        let service = ConversionService(directory: directory, categoryMask: 0)
        service.setPersonal(PersonalLexicon()); service.setLearning(url: nil)
        var rows: [[String: Any]] = []
        for (index, reading) in readings.enumerated() {
            let response: ConversionResponse = try await withCheckedThrowingContinuation { continuation in
                service.convert(reading, generation: UInt64(index + 1), editStart: 0) {
                    continuation.resume(with: $0)
                }
            }
            XCTAssertTrue(response.complete, reading)
            let candidates: [[String: Any]] = response.candidates.map { candidate in
                ["id": candidate.id, "text": candidate.text, "score": candidate.score,
                 "raw_text": candidate.rawText as Any? ?? NSNull(),
                 "corrected_reading": candidate.correctedReading as Any? ?? NSNull(),
                 "consumed_utf16": candidate.range.length, "start_utf16": candidate.range.location,
                 "annotation": candidate.displayAnnotation as Any? ?? NSNull(),
                 "is_reading_prefix": candidate.isReadingPrefix,
                 "presentation_kind": candidate.presentationKind.rawValue,
                 "classified_categories": candidate.classifiedCategories, "dictionaries": candidate.dictionaries]
            }
            rows.append(["reading": reading, "candidates": candidates,
                "normal": try presentation(response.candidates, expanded: false),
                "expanded": try presentation(response.candidates, expanded: true)])
        }
        let report: [String: Any] = ["schema_version": 1, "platform": "ios", "provenance": provenance,
            "configuration": ["n": 20, "flags": 12, "categories": "none", "learning": false, "personal": false],
            "conditions": rows, "scope": "Actual service and CandidateBar projection/callback. No editor commit, touch, physical acceptance or independent semantic accuracy assertion."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "ios-real-english-display.json"; attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    private func presentation(_ candidates: [ConversionCandidate], expanded: Bool) throws -> [[String: Any]] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController(); window.rootViewController = controller
        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 390, height: expanded ? 352 : 132))
        bar.rowCount = 3; bar.clipboardAccessAllowed = false; bar.showsShortcuts = false
        if expanded { bar.useExpandedLayout() }
        controller.view.addSubview(bar); window.isHidden = false
        defer { window.isHidden = true }
        bar.setCandidates(candidates.map { .init(text: $0.text, annotation: $0.displayAnnotation) })
        window.layoutIfNeeded(); bar.layoutIfNeeded()
        let list = try XCTUnwrap(bar.subviews.compactMap { $0 as? UICollectionView }.first)
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), candidates.count)
        var selected: Int?
        bar.onSelect = { selected = $0 }
        return try candidates.enumerated().map { index, candidate in
            let path = IndexPath(item: index, section: 0)
            list.scrollToItem(at: path, at: expanded ? .centeredVertically : .centeredHorizontally, animated: false)
            list.layoutIfNeeded()
            let cell = try XCTUnwrap(list.cellForItem(at: path)); cell.layoutIfNeeded()
            selected = nil; bar.collectionView(list, didSelectItemAt: path)
            XCTAssertEqual(selected, index)
            let labels: [[String: Any]] = cell.contentView.subviews.compactMap { $0 as? UILabel }.map {
                ["identifier": $0.accessibilityIdentifier as Any? ?? NSNull(), "text": $0.attributedText?.string ?? $0.text ?? "", "hidden": $0.isHidden]
            }
            return ["text": candidate.text, "selected_id": candidates[try XCTUnwrap(selected)].id,
                "labels": labels, "annotation": cell.accessibilityValue as Any? ?? NSNull()]
        }
    }
}
