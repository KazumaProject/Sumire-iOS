import XCTest
import UIKit
import SumireCore

/// Fixed synthetic snapshots of the production Swift service and its actual
/// CandidateBar cell/selection projection. This is an export, not an Android
/// parity assertion or cross-process keyboard-extension acceptance test.
@MainActor
final class ProductionCandidateDisplayExportTests: XCTestCase {
    // Exact baseline.readings of prediction-policy.json (policy is not bundled).
    private let readings = ["にほんご", "とうきょう", "あい", "はし", "かみ", "きしゃ", "しろ", "しろい", "しろくろ", "しろあり",
        "みにゅうりょくじ", "にて", "ひを", "がっこう", "かつこう", "びょういん", "きょうはいいてんきですね",
        "わたしはにほんごをにゅうりょくします", "このあぷりのへんかんこうほをこうそくにしたい", "にほん", "とうき", "かっこん", "あせん", "あめり", "りゅう"]
    private let policySHA256 = "7c5bc811622d6d853a51bf8f0ba43faf900ae004e354c2e1fd82d62f754209a3"
    private let manifestSHA256 = "60f44627887e96ef2618d90571234853e89ec193a0b23c2d0f8ab54ce2265f46"

    func testExportOrdinaryProductionDisplaySnapshots() async throws { try await export(omission: false) }
    /// Unpaired diagnostic until an equivalent Android omission export exists.
    func testExportOmissionProductionDisplaySnapshots() async throws { try await export(omission: true) }

    private func export(omission: Bool) async throws {
        #if DEBUG
        throw XCTSkip("Run the production display exporter in Release; shared provenance is Release-scoped")
        #else
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        let provenance = try ConversionBenchmarkProvenance.collectFullDictionary(directory: directory)
        XCTAssertEqual(provenance["manifest_sha256"] as? String, manifestSHA256)
        XCTAssertEqual(provenance["verified_manifest_output_count"] as? Int, 44)
        XCTAssertEqual(readings.count, 25)
        var conditions: [[String: Any]] = []
        for (category, mask) in [("none", UInt32(0)), ("all", UInt32(0x3fff_ffff))] {
            let service = ConversionService(directory: directory, categoryMask: mask)
            service.setPersonal(PersonalLexicon())
            service.setLearning(url: nil)
            service.setEnglishReading(true)
            for (index, reading) in readings.enumerated() {
                let generation = UInt64(index + 1)
                let response: ConversionResponse = try await withCheckedThrowingContinuation { continuation in
                    service.convert(reading, generation: generation, editStart: 0, omission: omission,
                                    english: false, includeBunsetsu: false, bunsetsuSearch: false) {
                        continuation.resume(with: $0)
                    }
                }
                XCTAssertEqual(response.generation, generation)
                XCTAssertTrue(response.complete, reading)
                XCTAssertNil(response.warning, reading)
                let candidates: [[String: Any]] = response.candidates.enumerated().map { order, candidate in
                    ["candidate_index": order, "id": candidate.id, "text": candidate.text,
                     "raw_text": candidate.rawText as Any? ?? NSNull(),
                     "corrected_reading": candidate.correctedReading as Any? ?? NSNull(),
                     "start_utf16": candidate.range.location, "length_utf16": candidate.range.length,
                     "score": candidate.score, "dictionaries": candidate.dictionaries,
                     "is_reading_prefix": candidate.isReadingPrefix,
                     "display_annotation": candidate.displayAnnotation as Any? ?? NSNull()]
                }
                conditions.append(["reading": reading, "categories": category, "category_mask": mask,
                    "flags": omission ? 13 : 12, "generation": generation, "complete": response.complete,
                    "candidate_count": candidates.count, "candidates": candidates,
                    "normal": try presentation(response.candidates, expanded: false),
                    "expanded": try presentation(response.candidates, expanded: true)])
            }
        }
        XCTAssertEqual(conditions.count, 50)
        let report: [String: Any] = ["schema_version": 1, "platform": "ios",
            "export_kind": omission ? "unpaired_omission_display_diagnostic" : "production_ordinary_display_snapshot",
            "reference_revision": "df1f38315bf56d860d32919a3eaed6a75499e91e",
            "prediction_policy_sha256": policySHA256, "readings": readings,
            "provenance": provenance, "route": "ConversionService.convert → CandidateBar.setCandidates",
            "configuration": ["build_configuration": "Release", "testability_override": "ENABLE_TESTABILITY=YES (hosted test imports; not a performance benchmark)", "candidate_count": 20, "max_states": 200_000, "flags": omission ? 13 : 12,
                "omission": omission, "japanese_prediction": true, "reading_prefix": true, "english_reading": true,
                "english": false, "bunsetsu_search": false, "include_bunsetsu": false,
                "personal_entries": 0, "learning_enabled": false],
            "scope": "Containing-app service with actual CandidateBar cells. Does not invoke KeyboardSurface/textDocumentProxy, establish physical rendering, or assert Android parity. All input is fixed synthetic data.",
            "condition_count": conditions.count, "conditions": conditions]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = omission ? "ios-production-candidate-display-omission.json" : "ios-production-candidate-display-ordinary.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    private func presentation(_ candidates: [ConversionCandidate], expanded: Bool) throws -> [String: Any] {
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
        var items: [[String: Any]] = []
        for (index, candidate) in candidates.enumerated() {
            let path = IndexPath(item: index, section: 0)
            list.scrollToItem(at: path, at: expanded ? .centeredVertically : .centeredHorizontally, animated: false)
            list.layoutIfNeeded()
            let cell = try XCTUnwrap(list.cellForItem(at: path))
            cell.layoutIfNeeded()
            selected = nil
            bar.collectionView(list, didSelectItemAt: path)
            XCTAssertEqual(selected, index)
            let mapped = try XCTUnwrap(selected)
            XCTAssertTrue(candidates.indices.contains(mapped))
            let labels: [[String: Any]] = cell.contentView.subviews.compactMap { $0 as? UILabel }.map {
                ["identifier": $0.accessibilityIdentifier as Any? ?? NSNull(), "text": $0.attributedText?.string ?? $0.text ?? "", "hidden": $0.isHidden]
            }
            items.append(["candidate_index": index, "semantic_text": candidate.text,
                "accessibility_label": cell.accessibilityLabel as Any? ?? NSNull(),
                "accessibility_value": cell.accessibilityValue as Any? ?? NSNull(),
                "labels": labels, "selected_index": mapped, "selected_candidate_id": candidates[mapped].id,
                "cell_height": cell.bounds.height])
        }
        return ["expanded": expanded, "row_count": 3, "width_pt": 390, "height_pt": expanded ? 352 : 132,
                "selection_scope": "Actual CandidateBar delegate callback maps display index to owned ConversionCandidate.id; no text is committed.", "items": items]
    }
}
