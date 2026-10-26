import XCTest
@testable import SumireCore

final class DictionaryCategoryCatalogTests: XCTestCase {
    func testReleaseTaxonomyAndLegacyExpansion() {
        XCTAssertEqual(DictionaryCategoryCatalog.categories.count, 143)
        XCTAssertEqual(DictionaryCategoryCatalog.idSet.count, 143)
        XCTAssertEqual(DictionaryCategoryCatalog.legacyIDs, DictionaryArchivePlan.categoryIDs)
        XCTAssertEqual(DictionaryCategoryCatalog.expanded(legacyMask: 0x3fff_ffff), DictionaryCategoryCatalog.ids)
        let people = DictionaryCategoryCatalog.expanded(legacyMask: 1)
        XCTAssertEqual(people.count, 29)
        XCTAssertTrue(people.contains("actor"))
        let facility = DictionaryCategoryCatalog.expanded(legacyMask: 1 << 6)
        XCTAssertTrue(facility.contains("facility/religious/shrine"))
        XCTAssertTrue(facility.allSatisfy { $0.hasPrefix("facility/") })
        let character = DictionaryCategoryCatalog.expanded(legacyMask: 1 << 1)
        XCTAssertEqual(character.filter { $0.hasPrefix("media_demographic/") }.count, 8)
        XCTAssertEqual(DictionaryCategoryCatalog.legacyMask(for: ["actor", "facility/religious/shrine"]), (1 << 0) | (1 << 6))
        XCTAssertEqual(DictionaryCategoryCatalog.legacyMask(for: ["media_demographic/audience/shonen"]), 0)
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
        let loaded = try store.publish(importedFiles: ["facility/religious/shrine.sud": incoming], from: base)
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
