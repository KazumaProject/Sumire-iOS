import XCTest
@testable import SumireCore

final class RomajiLibraryTests: XCTestCase {
    func testMixedImportStagesOnlyWholeValidProfilesWithoutMutation() throws {
        let name = "RomajiPreviewTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var original = RomajiLibrary()
        original.profiles = [RomajiProfile(name: "existing", rules: ["x": .init("く", 1)])]
        original.activeID = original.profiles[0].id
        try original.save(defaults: defaults)
        let data = Data(#"[{"name":"valid","mapData":{"a":{"first":"あ","second":1}}},{"name":"invalid","mapData":{"a":{"first":"あ","second":0}}},null,{"name":"missing"}]"#.utf8)
        let preview = try RomajiImportPreview.parse(data)
        XCTAssertEqual(preview.profiles.map(\.name), ["valid"])
        XCTAssertEqual(preview.errors.count, 3)
        XCTAssertTrue(preview.errors[0].hasPrefix("2件目:"))
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), original)
        var next = original; next.profiles += preview.profiles
        try next.save(defaults: defaults)
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), next)
        XCTAssertEqual(next.activeID, original.activeID)
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data("{broken".utf8)))
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data("{}".utf8)))
    }

    func testAndroidImportSelectionPersistenceAndInvalidSavePreservesRules() throws {
        let name = "RomajiLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(#"[{"id":5,"name":"test","mapData":{"a":{"first":"す","second":1}},"isActive":true,"autoN":false,"autoSokuon":false}]"#.utf8)
        var library = RomajiLibrary()
        library.profiles = try RomajiLibrary.importAndroid(data)
        XCTAssertEqual(try library.converter().convert("a"), "あ")
        library.activeID = library.profiles[0].id
        try library.save(defaults: defaults)
        let restored = try RomajiLibrary.load(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(restored, library)
        XCTAssertEqual(try restored.converter().convert("a"), "す")
        XCTAssertEqual(try restored.converter().flush("n"), "n")
        library.profiles[0].rules["bad"] = .init("x", 0)
        XCTAssertThrowsError(try library.save(defaults: defaults))
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), restored)
        library = restored; library.activeID = UUID()
        XCTAssertThrowsError(try library.save(defaults: defaults))
        library = restored; library.version = 999
        XCTAssertThrowsError(try library.save(defaults: defaults))
    }
    func testDefaultRulesCanBeCopiedAndImportRejectsBadConsumption() throws {
        XCTAssertThrowsError(try RomajiProfile(name: "split", rules: ["😀": .init("x", 1)]).validate())
        try RomajiProfile(name: "copy", rules: RomajiConverter.standard().rules).validate()
        for n in [0, -1, 3] {
            let data = Data("[{\"name\":\"bad\",\"mapData\":{\"a\":{\"first\":\"あ\",\"second\":\(n)}}}]".utf8)
            XCTAssertThrowsError(try RomajiLibrary.importAndroid(data))
        }
    }
}
