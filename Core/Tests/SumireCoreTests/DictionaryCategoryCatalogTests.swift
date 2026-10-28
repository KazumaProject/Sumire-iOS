import XCTest
@testable import SumireCore

final class DictionaryCategoryCatalogTests: XCTestCase {
    private func legacyAggregates(_ ids: [String]) -> Set<DictionaryCategoryCatalog.LegacyAggregateID> {
        Set(ids.map(DictionaryCategoryCatalog.LegacyAggregateID.init(rawValue:)))
    }

    func testReleaseTaxonomyAndLegacyExpansion() {
        XCTAssertEqual(DictionaryCategoryCatalog.categories.count, 143)
        XCTAssertEqual(DictionaryCategoryCatalog.idSet.count, 143)
        XCTAssertEqual(DictionaryCategoryCatalog.legacyIDs, DictionaryArchivePlan.categoryIDs)
        let demographicIDs = DictionaryCategoryCatalog.ids.filter { $0.hasPrefix("media_demographic/") }
        XCTAssertEqual(
            DictionaryCategoryCatalog.expanded(legacyMask: 0x3fff_ffff),
            DictionaryCategoryCatalog.ids.filter { !$0.hasPrefix("media_demographic/") }
        )
        let people = DictionaryCategoryCatalog.expanded(legacyMask: 1)
        XCTAssertEqual(people.count, 29)
        XCTAssertTrue(people.contains("actor"))
        let facility = DictionaryCategoryCatalog.expanded(legacyMask: 1 << 6)
        XCTAssertTrue(facility.contains("facility/religious/shrine"))
        XCTAssertTrue(facility.allSatisfy { $0.hasPrefix("facility/") })
        let character = DictionaryCategoryCatalog.expanded(legacyMask: 1 << 1)
        XCTAssertEqual(character, ["character"])
        XCTAssertEqual(demographicIDs.count, 8)
        XCTAssertEqual(DictionaryCategoryCatalog.legacyMask(for: ["actor", "facility/religious/shrine"]), (1 << 0) | (1 << 6))
        XCTAssertEqual(DictionaryCategoryCatalog.legacyMask(for: ["media_demographic/audience/shonen"]), 0)
    }

    func testDemographicReleaseLeavesRemainDirectlySelectableOutsideLegacyMasks() {
        let demographicIDs = Set(DictionaryCategoryCatalog.ids.filter { $0.hasPrefix("media_demographic/") })
        XCTAssertEqual(demographicIDs.count, 8)
        XCTAssertTrue(
            DictionaryCategoryCatalog.categories
                .filter { demographicIDs.contains($0.id) }
                .allSatisfy { $0.legacyFamilies.isEmpty }
        )
        XCTAssertEqual(Set(DictionaryCategoryCatalog.normalize(Array(demographicIDs))), demographicIDs)
        XCTAssertEqual(DictionaryCategoryCatalog.legacyMask(for: Array(demographicIDs)), 0)

        for (index, family) in DictionaryCategoryCatalog.legacyIDs.enumerated() {
            let selected = Set(DictionaryCategoryCatalog.expanded(legacyMask: UInt32(1) << index))
            XCTAssertTrue(selected.isDisjoint(with: demographicIDs), "Legacy family: \(family)")
        }
    }

    func testCompleteIndependentFamilyUsesAggregateAndKeepsUnrelatedLeaves() {
        let facilityLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("facility") }
            .map(\.id)
        let selected = facilityLeaves + ["actor"]

        let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
            selectedIDs: selected,
            availableLegacyAggregateIDs: legacyAggregates(["facility"])
        )

        XCTAssertEqual(resolved.legacyAggregateIDs.map(\.rawValue), ["facility"])
        XCTAssertEqual(resolved.releaseLeafIDs, ["actor"])
    }

    func testPartialFamilySelectionKeepsReleaseLeaves() {
        let selected = ["facility/religious/shrine", "facility/religious/temple", "actor"]
        let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
            selectedIDs: selected,
            availableLegacyAggregateIDs: legacyAggregates(["facility"])
        )

        XCTAssertTrue(resolved.legacyAggregateIDs.isEmpty)
        XCTAssertEqual(Set(resolved.releaseLeafIDs), Set(selected))
    }

    func testCharacterAggregateSubstitutesOnlyItsMappedReleaseLeaf() {
        let characterLeaves = DictionaryCategoryCatalog.categories
            .filter { $0.legacyFamilies.contains("character") }
            .map(\.id)
        XCTAssertEqual(characterLeaves, ["character"])
        let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
            selectedIDs: characterLeaves,
            availableLegacyAggregateIDs: legacyAggregates(["character"])
        )

        XCTAssertEqual(resolved.legacyAggregateIDs.map(\.rawValue), ["character"])
        XCTAssertEqual(resolved.releaseLeafIDs, [])
    }

    func testUnrelatedAggregateDoesNotReplaceSelectedReleaseLeaf() {
        let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
            selectedIDs: ["character"],
            availableLegacyAggregateIDs: legacyAggregates(["work_franchise"])
        )

        XCTAssertTrue(resolved.legacyAggregateIDs.isEmpty)
        XCTAssertEqual(resolved.releaseLeafIDs, ["character"])
    }

    func testResolvedCompleteCatalogHasNoAggregateAndLeafDoubleCoverage() {
        let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
            selectedIDs: DictionaryCategoryCatalog.ids,
            availableLegacyAggregateIDs: legacyAggregates(DictionaryCategoryCatalog.legacyIDs)
        )
        let aggregates = Set(resolved.legacyAggregateIDs.map(\.rawValue))

        XCTAssertEqual(aggregates.count, resolved.legacyAggregateIDs.count)
        XCTAssertEqual(Set(resolved.releaseLeafIDs).count, resolved.releaseLeafIDs.count)
        XCTAssertTrue(Set(resolved.releaseLeafIDs).isDisjoint(with: aggregates))
        for family in aggregates {
            let mappedLeaves = DictionaryCategoryCatalog.categories
                .filter { $0.legacyFamilies.contains(family) }
            XCTAssertFalse(mappedLeaves.contains { resolved.releaseLeafIDs.contains($0.id) })
        }
    }

    func testResolverRoutesEverySelectedReleaseLeafExactlyOnceAcrossCatalogScenarios() {
        let allIDs = DictionaryCategoryCatalog.ids
        let allAggregates = legacyAggregates(DictionaryCategoryCatalog.legacyIDs)
        var scenarios: [(name: String, selectedIDs: [String], available: Set<DictionaryCategoryCatalog.LegacyAggregateID>)] = [
            ("nothing selected", [], allAggregates),
            ("no aggregates available", allIDs, []),
            ("all aggregates available", allIDs, allAggregates),
        ]

        // Each single leaf must remain independently selectable even when all overlays exist.
        for category in DictionaryCategoryCatalog.categories {
            scenarios.append(("single leaf: \(category.id)", [category.id], allAggregates))
        }

        // Exercise each legacy family as the only available aggregate against the full
        // release selection; this catches lost or duplicated routing for every taxonomy family.
        for family in DictionaryCategoryCatalog.legacyIDs {
            scenarios.append(("only aggregate: \(family)", allIDs, legacyAggregates([family])))
        }

        // Complete leaf sets for each family, including shared leaves, must not make a
        // partial multi-family overlay replace a release leaf.
        for family in DictionaryCategoryCatalog.legacyIDs {
            let familyLeaves = DictionaryCategoryCatalog.categories
                .filter { $0.legacyFamilies.contains(family) }
                .map(\.id)
            scenarios.append(("family leaf set: \(family)", familyLeaves, allAggregates))
        }

        for scenario in scenarios {
            let selected = Set(DictionaryCategoryCatalog.normalize(scenario.selectedIDs))
            let result = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
                selectedIDs: scenario.selectedIDs,
                availableLegacyAggregateIDs: scenario.available
            )
            let releaseLeaves = Set(result.releaseLeafIDs)
            let aggregateIDs = Set(result.legacyAggregateIDs.map(\.rawValue))

            XCTAssertEqual(releaseLeaves.count, result.releaseLeafIDs.count, scenario.name)
            XCTAssertEqual(aggregateIDs.count, result.legacyAggregateIDs.count, scenario.name)
            XCTAssertTrue(releaseLeaves.isSubset(of: selected), scenario.name)
            XCTAssertTrue(aggregateIDs.isSubset(of: Set(scenario.available.map(\.rawValue))), scenario.name)

            for category in DictionaryCategoryCatalog.categories where selected.contains(category.id) {
                let directCoverage = releaseLeaves.contains(category.id)
                let overlayCoverage = !category.legacyFamilies.isEmpty
                    && Set(category.legacyFamilies).isSubset(of: aggregateIDs)
                XCTAssertNotEqual(directCoverage, overlayCoverage,
                                  "Selected leaf must have exactly one route (direct or complete overlay): \(category.id), \(scenario.name)")
            }

            for family in aggregateIDs {
                let mappedLeaves = DictionaryCategoryCatalog.categories
                    .filter { $0.legacyFamilies.contains(family) }
                XCTAssertFalse(mappedLeaves.isEmpty, "Unknown aggregate family: \(family), \(scenario.name)")
                XCTAssertTrue(mappedLeaves.allSatisfy { selected.contains($0.id) }, scenario.name)
                XCTAssertTrue(mappedLeaves.allSatisfy { Set($0.legacyFamilies).isSubset(of: aggregateIDs) },
                              "A shared leaf must not be split across legacy and release sources: \(family), \(scenario.name)")
            }
        }
    }

    func testSelectionAndBackupPreserveNewIDsAndMigrateOldMask() throws {
        let suite = "DictionaryCategoryCatalogTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "categoryMask")
        XCTAssertEqual(DictionaryCategoryCatalog.selection(defaults: defaults).count, 29)
        DictionaryCategoryCatalog.save(["actor", "facility/religious/shrine"], defaults: defaults)
        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        XCTAssertEqual(snapshot.values[DictionaryCategoryCatalog.selectionKey], .textArray(["facility/religious/shrine", "actor"]))
        DictionaryCategoryCatalog.save([], defaults: defaults)
        XCTAssertTrue(DictionaryCategoryCatalog.selection(defaults: defaults).isEmpty)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(Set(DictionaryCategoryCatalog.selection(defaults: defaults)), ["actor", "facility/religious/shrine"])
        var old = KeyboardSettingsSnapshot()
        old.values["categoryMask"] = .number(1)
        try old.restore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: DictionaryCategoryCatalog.selectionKey))
        XCTAssertEqual(DictionaryCategoryCatalog.selection(defaults: defaults).count, 29)
        DictionaryCategoryCatalog.save(["actor"], defaults: defaults)
        old.values["categoryMask"] = .number(0)
        try old.applyImportedValues(to: defaults)
        XCTAssertTrue(DictionaryCategoryCatalog.selection(defaults: defaults).isEmpty)
        var invalid = KeyboardSettingsSnapshot()
        invalid.values[DictionaryCategoryCatalog.selectionKey] = .textArray(["../actor"])
        XCTAssertThrowsError(try invalid.validate())
        invalid.values[DictionaryCategoryCatalog.selectionKey] = .textArray(["actor", "actor"])
        XCTAssertThrowsError(try invalid.validate())
    }

    func testNestedArchiveLeavesAndPersonAliasesNeverFallBackToSystem() throws {
        for (archive, id) in [("facility/religious/shrine", "facility/religious/shrine"), ("person/actor", "actor"), ("term/general/food_drink_cooking", "term/general/food_drink_cooking")] {
            let plan = try DictionaryArchivePlan(entryNames: ["yomi", "tango", "token"].map { "categories/\(archive)/\($0).dat.zip" })
            XCTAssertEqual(plan.validationCandidates.count, 1)
            XCTAssertEqual(plan.groups.first?.group, .category(id))
        }
        XCTAssertTrue(try DictionaryArchivePlan(entryNames: ["categories/facility/../person/yomi.dat"]).groups.isEmpty)
        XCTAssertTrue(try DictionaryArchivePlan(entryNames: ["categories/facility/unlisted/yomi.dat"]).groups.isEmpty)
    }

    func testGenerationPreservesNestedLeavesAndMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for file in ["system.sud", "connection.sud", "actor.sud", DictionaryCategoryCatalog.releaseMarker] {
            try Data(file.utf8).write(to: base.appendingPathComponent(file))
        }
        let incoming = root.appendingPathComponent("shrine.sud")
        try Data("nested replacement".utf8).write(to: incoming)
        let store = DictionaryGenerationStore(directory: root.appendingPathComponent("generations"))
        let loaded = try store.publish(importedFiles: ["facility/religious/shrine.sud": incoming], from: base,
                                       supportFallback: base, importMode: .releaseLeaf)
        XCTAssertEqual(try Data(contentsOf: loaded.directory.appendingPathComponent("facility/religious/shrine.sud")), Data("nested replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path))
        XCTAssertEqual(store.loadCurrent()?.generation, loaded.generation)
        let next = try store.publish(importedFiles: [:], from: loaded.directory)
        XCTAssertEqual(try Data(contentsOf: next.directory.appendingPathComponent("facility/religious/shrine.sud")), Data("nested replacement".utf8))
        try FileManager.default.removeItem(at: base.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker))
        let legacy = root.appendingPathComponent("person.sud")
        try Data("legacy person".utf8).write(to: legacy)
        XCTAssertThrowsError(try store.publish(importedFiles: ["person.sud": legacy], from: loaded.directory))
        XCTAssertEqual(store.loadCurrent()?.generation, next.generation)
        let old = try store.publish(importedFiles: ["person.sud": legacy], from: base)
        XCTAssertEqual(try Data(contentsOf: old.directory.appendingPathComponent("person.sud")), Data("legacy person".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path))
    }
}
