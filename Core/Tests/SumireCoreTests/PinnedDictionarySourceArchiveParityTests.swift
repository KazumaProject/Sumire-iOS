import CryptoKit
import Foundation
import XCTest
@testable import SumireCore

final class PinnedDictionarySourceArchiveParityTests: XCTestCase {
    private struct Manifest: Decodable {
        let sourceRevision: String
        let assetSHA256: [String: String]
        let outputSHA256: [String: String]

        enum CodingKeys: String, CodingKey {
            case sourceRevision = "source_revision"
            case assetSHA256 = "asset_sha256"
            case outputSHA256 = "output_sha256"
        }
    }

    private let sourceRevision = "df1f38315bf56d860d32919a3eaed6a75499e91e"
    private let sourceArchiveSHA256 = "45f3078272be30c936af389d44c8df6fb2cda565ea490b21c12afa1016d8bd54"
    private let nativeManifestSHA256 = "60f44627887e96ef2618d90571234853e89ec193a0b23c2d0f8ab54ce2265f46"
    private let expectedConvertedFiles: Set<String> = [
        "address.sud", "agreement.sud", "award.sud", "character.sud", "connection.sud",
        "emoji.sud", "emoticon.sud", "english.sud", "english_reading.sud", "event.sud",
        "facility.sud", "initiative.sud", "kampo.sud", "lineage.sud", "medical.sud",
        "mythological_figure.sud", "organization.sud", "person.sud", "place.sud", "product.sud",
        "reading_correction.sud", "single_kanji.sud", "station.sud", "symbol.sud", "system.sud",
        "term.sud", "transport_route.sud", "vehicle.sud", "work_anime.sud", "work_book.sud",
        "work_film.sud", "work_franchise.sud", "work_game.sud", "work_manga.sud", "work_music.sud",
        "work_other.sud", "work_periodical.sud", "work_program.sud", "work_stage.sud"
    ]

    func testCompletePinnedAndroidSourceArchiveMatchesNativeOutputHashesWhenConfigured() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_SOURCE_ZIP"],
              !archivePath.isEmpty,
              let nativePath = ProcessInfo.processInfo.environment["SUMIRE_REFERENCE_NATIVE_DICTIONARIES"],
              !nativePath.isEmpty else {
            throw XCTSkip("Set SUMIRE_REFERENCE_SOURCE_ZIP and SUMIRE_REFERENCE_NATIVE_DICTIONARIES for pinned source parity")
        }

        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        XCTAssertEqual(sha256(archiveData), sourceArchiveSHA256, "The complete fixture must remain the reviewed pinned archive")

        let nativeDirectory = URL(fileURLWithPath: nativePath, isDirectory: true)
        let nativeManifestData = try Data(contentsOf: nativeDirectory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(sha256(nativeManifestData), nativeManifestSHA256,
                       "The native output oracle must remain the reviewed manifest")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: nativeManifestData)
        XCTAssertEqual(manifest.sourceRevision, sourceRevision)
        XCTAssertEqual(manifest.assetSHA256.count, 121)
        XCTAssertEqual(manifest.outputSHA256.count, 44,
                       "The native generation also includes five outputs outside this source converter")
        XCTAssertTrue(expectedConvertedFiles.isSubset(of: Set(manifest.outputSHA256.keys)),
                      "Every converter output needs a pinned native hash")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sumire-pinned-source-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        // Bind the native manifest to this exact archive by checking each source
        // asset, rather than trusting a revision label stored beside another build.
        let archive = try DictionaryZipArchive(data: archiveData)
        let archiveFiles = Dictionary(uniqueKeysWithValues: archive.entries
            .filter { !$0.isDirectory }
            .map { ($0.name, $0) })
        XCTAssertEqual(manifest.assetSHA256.count, 121)
        for (path, expectedHash) in manifest.assetSHA256.sorted(by: { $0.key < $1.key }) {
            guard let entry = archiveFiles[path] else {
                XCTFail("Pinned native manifest asset is missing from the archive: \(path)")
                continue
            }
            let extracted = root.appendingPathComponent(UUID().uuidString)
            try archive.extract(entry, to: extracted)
            let actualHash = sha256(try Data(contentsOf: extracted, options: .mappedIfSafe))
            XCTAssertEqual(actualHash, expectedHash, "Pinned source asset differs for \(path)")
        }

        let output = root.appendingPathComponent("converted", isDirectory: true)
        let report = try DictionarySourceArchiveConverter.convert(archiveAt: archiveURL, into: output)

        XCTAssertEqual(Set(report.convertedFiles), expectedConvertedFiles)
        XCTAssertEqual(Set(report.importedFiles.keys), expectedConvertedFiles)
        XCTAssertTrue(report.legacyAggregateOverlays.isEmpty)
        XCTAssertTrue(report.skippedGroups.isEmpty)
        for name in report.convertedFiles.sorted() {
            guard let expected = manifest.outputSHA256[name] else {
                XCTFail("Converted output has no pinned native hash: \(name)")
                continue
            }
            let data = try Data(contentsOf: output.appendingPathComponent(name), options: .mappedIfSafe)
            XCTAssertEqual(sha256(data), expected, "Native binary differs for \(name)")
        }

        // The same legacy source can also be converted without erasing the distinction
        // between an old family aggregate and a release leaf with the same raw name.
        let aggregateOutput = root.appendingPathComponent("aggregate-converted", isDirectory: true)
        let aggregateReport = try DictionarySourceArchiveConverter.convert(
            archiveAt: archiveURL,
            into: aggregateOutput,
            categoryInterpretation: .legacyAggregate
        )
        let expectedAggregateIDs = Set(DictionaryCategoryCatalog.legacyIDs.map {
            DictionaryCategoryCatalog.LegacyAggregateID(rawValue: $0)
        })
        XCTAssertEqual(Set(aggregateReport.legacyAggregateOverlays.keys), expectedAggregateIDs)
        XCTAssertEqual(aggregateReport.legacyAggregateOverlays.count, 30)
        XCTAssertTrue(Set(aggregateReport.importedFiles.keys).isDisjoint(with: Set(
            DictionaryCategoryCatalog.legacyIDs.map { $0 + ".sud" }
        )), "A typed old-family file must not also be emitted as a flat release replacement")
        var logicalOutputs = aggregateReport.importedFiles
        for (id, url) in aggregateReport.legacyAggregateOverlays {
            logicalOutputs[id.rawValue + ".sud"] = url
            XCTAssertEqual(url.lastPathComponent, id.rawValue + ".sud")
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "legacy_aggregates")
        }
        XCTAssertEqual(Set(logicalOutputs.keys), expectedConvertedFiles)
        XCTAssertTrue(aggregateReport.skippedGroups.isEmpty)
        for (name, url) in logicalOutputs.sorted(by: { $0.key < $1.key }) {
            guard let expected = manifest.outputSHA256[name] else {
                XCTFail("Typed conversion output has no pinned native hash: \(name)")
                continue
            }
            XCTAssertEqual(sha256(try Data(contentsOf: url, options: .mappedIfSafe)), expected,
                           "Typed native binary differs for \(name)")
        }

        // Publication keeps release leaves intact while persisting same-named family
        // aggregates under a typed subdirectory. This validates conversion-to-store handoff,
        // not native-engine consumption of aggregate dictionaries.
        let base = root.appendingPathComponent("release-base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        let releaseCharacter = Data("release character leaf".utf8)
        let releaseFranchise = Data("release franchise leaf".utf8)
        try Data("release baseline system".utf8).write(to: base.appendingPathComponent("system.sud"))
        try Data("release baseline connection".utf8).write(to: base.appendingPathComponent("connection.sud"))
        try releaseCharacter.write(to: base.appendingPathComponent("character.sud"))
        try releaseFranchise.write(to: base.appendingPathComponent("work_franchise.sud"))
        try Data().write(to: base.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("generation-store", isDirectory: true))
        // This fixture models the explicit bundled-bootstrap trust path. Without
        // supportFallback pointing at the base, the Store correctly refuses to
        // trust or preserve a release marker that it cannot authenticate.
        let published = try store.publish(importedFiles: aggregateReport.importedFiles,
                                          from: base,
                                          supportFallback: base,
                                          legacyAggregateOverlays: aggregateReport.legacyAggregateOverlays,
                                          importMode: .typedLegacyAggregate)
        let loaded = try XCTUnwrap(store.loadCurrent())
        XCTAssertEqual(Set(published.legacyAggregateOverlayIDs), expectedAggregateIDs)
        XCTAssertEqual(Set(loaded.legacyAggregateOverlayIDs), expectedAggregateIDs)
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("character.sud")), releaseCharacter)
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("work_franchise.sud")), releaseFranchise)
        for id in ["character", "work_franchise"] {
            let file = loaded.directory.appendingPathComponent("legacy_aggregates/\(id).sud")
            XCTAssertEqual(sha256(try Data(contentsOf: file, options: .mappedIfSafe)),
                           manifest.outputSHA256[id + ".sud"])
        }

        let availableAggregateIDs = Set(loaded.legacyAggregateOverlayIDs.map(\.rawValue))
        let aggregateCoveredCategoryIDs = Set(DictionaryCategoryCatalog.categories.compactMap { category -> String? in
            guard !category.legacyFamilies.isEmpty,
                  Set(category.legacyFamilies).isSubset(of: availableAggregateIDs) else { return nil }
            return category.id
        })
        let directlyImportedCategoryIDs = Set(aggregateReport.importedFiles.keys.compactMap { file -> String? in
            guard file.hasSuffix(".sud") else { return nil }
            let id = String(file.dropLast(4))
            return DictionaryCategoryCatalog.idSet.contains(id) ? id : nil
        })
        let expectedSelectableCategoryIDs = aggregateCoveredCategoryIDs.union(directlyImportedCategoryIDs)
        let sourceSelection = loaded.resolveSourceSelection(for: expectedSelectableCategoryIDs.sorted())
        let selectedAggregateIDs = Set(sourceSelection.legacyAggregateSources.map { $0.id.rawValue })
        let actuallyAggregateCoveredCategoryIDs = Set(DictionaryCategoryCatalog.categories.compactMap { category -> String? in
            guard !category.legacyFamilies.isEmpty,
                  Set(category.legacyFamilies).isSubset(of: selectedAggregateIDs) else { return nil }
            return category.id
        })
        let selectedReleaseLeafIDs = Set(sourceSelection.releaseLeafIDs)

        XCTAssertEqual(Set(sourceSelection.unavailableCategoryIDs), [])
        XCTAssertEqual(selectedAggregateIDs, availableAggregateIDs)
        XCTAssertEqual(selectedReleaseLeafIDs.union(actuallyAggregateCoveredCategoryIDs), expectedSelectableCategoryIDs)
        XCTAssertTrue(selectedReleaseLeafIDs.isDisjoint(with: actuallyAggregateCoveredCategoryIDs),
                      "A selected category must not be routed through both a release leaf and a complete aggregate set")
        XCTAssertEqual(sourceSelection.releaseLeafIDs.count, selectedReleaseLeafIDs.count,
                       "A release leaf must be selected at most once")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
