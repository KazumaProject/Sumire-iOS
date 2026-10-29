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
        XCTAssertEqual(preview.profiles.map(\.name), ["valid", "invalid"])
        XCTAssertEqual(preview.profiles[1].rules["a"], RomajiRule("あ", 1))
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertTrue(preview.errors[0].hasPrefix("4件目:"))
        XCTAssertEqual(try RomajiLibrary.importAndroid(data).map(\.name), ["valid", "invalid"])
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), original)
        var next = original; next.profiles += preview.profiles
        try next.save(defaults: defaults)
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), next)
        XCTAssertEqual(next.activeID, original.activeID)
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data("{broken".utf8)))
        let singleObjectPreview = try RomajiImportPreview.parse(Data("{}".utf8))
        XCTAssertTrue(singleObjectPreview.profiles.isEmpty)
        XCTAssertEqual(singleObjectPreview.errors.count, 1)
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
        library.profiles[0].setRule(.init("x", 0), for: "bad")
        XCTAssertThrowsError(try library.save(defaults: defaults))
        XCTAssertEqual(try RomajiLibrary.load(defaults: defaults), restored)
        library = restored; library.activeID = UUID()
        XCTAssertThrowsError(try library.save(defaults: defaults))
        library = restored; library.version = 999
        XCTAssertThrowsError(try library.save(defaults: defaults))
    }
    func testImportedRuleOrderSurvivesProfilePersistenceAndConverterCreation() throws {
        let data = Data(#"[{"name":"ordered","mapData":{"hu":{"first":"ふ","second":2},"fu":{"first":"ふ","second":2}}}]"#.utf8)
        var library = RomajiLibrary()
        library.profiles = try RomajiLibrary.importAndroid(data)
        let imported = try XCTUnwrap(library.profiles.first)
        XCTAssertEqual(imported.ruleOrder, ["hu", "fu"])
        XCTAssertEqual(imported.converter.ruleOrder, ["hu", "fu"])

        library.activeID = imported.id
        let defaultsName = "RomajiRuleOrder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        try library.save(defaults: defaults)
        let restored = try RomajiLibrary.load(defaults: defaults)
        XCTAssertEqual(restored.profiles.first?.ruleOrder, ["hu", "fu"])
        XCTAssertEqual(try restored.converter().ruleOrder, ["hu", "fu"])
    }

    func testExistingProfilesWithoutRuleOrderLoadWithDeterministicLegacyOrder() throws {
        let legacy = Data(#"{"name":"legacy","rules":{"hu":{"first":"ふ","second":2},"fu":{"first":"ふ","second":2}}}"#.utf8)
        let profile = try JSONDecoder().decode(RomajiProfile.self, from: legacy)
        XCTAssertEqual(profile.ruleOrder, ["fu", "hu"])
        try profile.validate()
    }

    func testRuleEditingPreservesExistingPositionAndTracksAddedAndRemovedRules() throws {
        var profile = RomajiProfile(name: "ordered", rules: ["hu": .init("ふ", 2), "fu": .init("ふ", 2)], ruleOrder: ["hu", "fu"])
        profile.setRule(.init("ふ", 2), for: "fu")
        XCTAssertEqual(profile.ruleOrder, ["hu", "fu"])
        profile.setRule(.init("てぃ", 3), for: "thi")
        XCTAssertEqual(profile.ruleOrder, ["hu", "fu", "thi"])
        profile.removeRule(for: "hu")
        XCTAssertEqual(profile.ruleOrder, ["fu", "thi"])
        try profile.validate()
    }

    func testDefaultRulesCanBeCopiedAndImportRejectsBadConsumption() throws {
        XCTAssertThrowsError(try RomajiProfile(name: "split", rules: ["😀": .init("x", 1)]).validate())
        try RomajiProfile(name: "copy", rules: RomajiConverter.standard().rules).validate()
        for n in [0, -1] {
            let data = Data("[{\"name\":\"normalized\",\"mapData\":{\"a\":{\"first\":\"あ\",\"second\":\(n)}}}]".utf8)
            XCTAssertEqual(try RomajiLibrary.importAndroid(data).first?.rules["a"], RomajiRule("あ", 1))
        }
        let overconsuming = Data(#"[{"name":"legacy","mapData":{"a":{"first":"あ","second":3}}}]"#.utf8)
        let profile = try XCTUnwrap(RomajiLibrary.importAndroid(overconsuming).first)
        XCTAssertEqual(profile.rules["a"], RomajiRule("あ", 3))
        XCTAssertEqual(profile.converter.convert("abcd"), "あd")
    }

    func testAndroidImportAcceptsBomObjectWrappersAliasesAndEncodedMaps() throws {
        let wrapperKeys = ["maps", "romajiMaps", "romaji_maps", "items", "list"]
        for wrapperKey in wrapperKeys {
            let json = """
            {"\(wrapperKey)":[{"mapName":"\(wrapperKey)","data":"{\\"ka\\":{\\"kana\\":\\"か\\",\\"consume\\":2}}","autoSokuon":"false","autoN":true}]}
            """
            let preview = try RomajiImportPreview.parse(Data(([0xEF, 0xBB, 0xBF] + Array(json.utf8))))
            XCTAssertEqual(preview.errors, [], wrapperKey)
            XCTAssertEqual(preview.profiles.count, 1, wrapperKey)
            XCTAssertEqual(preview.profiles[0].name, wrapperKey)
            XCTAssertEqual(preview.profiles[0].rules["ka"], RomajiRule("か", 2))
            XCTAssertFalse(preview.profiles[0].autoSokuon)
            XCTAssertTrue(preview.profiles[0].autoN)
        }

        let singleObject = Data(#"{"title":"single","map":{"a":{"first":"あ","second":1}}}"#.utf8)
        let profile = try RomajiLibrary.importAndroid(singleObject).first
        XCTAssertEqual(profile?.name, "single")
        XCTAssertEqual(profile?.rules["a"], RomajiRule("あ", 1))
        XCTAssertEqual(profile?.autoSokuon, true)
        XCTAssertEqual(profile?.autoN, true)

        let mapJSON = #"{"ka":{"kana":"か","consume":2}}"#
        let encodedMapJSON = String(decoding: try JSONEncoder().encode(mapJSON), as: UTF8.self)
        for dataKey in ["mapData", "map", "data"] {
            for payload in [mapJSON, encodedMapJSON] {
                let item = "{\"name\":\"\(dataKey)\",\"\(dataKey)\":\(payload)}"
                let decoded = try RomajiImportPreview.parse(Data(item.utf8))
                XCTAssertEqual(decoded.errors, [], item)
                XCTAssertEqual(decoded.profiles.first?.rules["ka"], RomajiRule("か", 2), item)
            }
        }

        let fallback = Data(#"{"name":"fallback","mapData":"not JSON","map":{"x":{"kana":"え","consume":1}}}"#.utf8)
        XCTAssertEqual(try RomajiLibrary.importAndroid(fallback).first?.rules["x"], RomajiRule("え", 1))
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data("[01]".utf8)))
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data("[{} ,]".utf8)))
    }

    func testAndroidImportReadsCompactObfuscatedAndDefaultUtf16ConsumptionRules() throws {
        let data = Data(#"[{"title":"legacy","autoSokuon":false,"map":{"pp":{"c":"っ","d":2},"ab":{"a":"ん","b":1},"obey":{"z":"を","a":"あ","count":4,"other":2},"no":{"first":"の"},"😀":{"kana":"絵"},"bad":{"first":7,"second":1}}}]"#.utf8)
        let profile = try XCTUnwrap(RomajiLibrary.importAndroid(data).first)

        XCTAssertEqual(profile.rules["pp"], RomajiRule("っ", 2))
        XCTAssertEqual(profile.rules["ab"], RomajiRule("ん", 1))
        XCTAssertEqual(profile.rules["obey"], RomajiRule("を", 4))
        XCTAssertEqual(profile.rules["no"], RomajiRule("の", 2))
        XCTAssertEqual(profile.rules["😀"], RomajiRule("絵", 2))
        XCTAssertNil(profile.rules["bad"])
        XCTAssertEqual(profile.converter.convert("ppabno😀"), "っんbの絵")
    }

    func testAndroidImportKeepsValidRulesAndRejectsInvalidUnicodeConsumption() throws {
        let mixed = Data(#"[{"name":"mixed","mapData":{"a":{"first":"あ","second":1},"bad":{"first":3,"second":"oops"}}}]"#.utf8)
        let mixedPreview = try RomajiImportPreview.parse(mixed)
        XCTAssertEqual(mixedPreview.errors, [])
        XCTAssertEqual(mixedPreview.profiles.first?.rules, ["a": RomajiRule("あ", 1), "bad": RomajiRule("oops", 3)])

        let splitScalar = Data(#"[{"name":"split","mapData":{"😀":{"kana":"絵","consume":1}}}]"#.utf8)
        let splitPreview = try RomajiImportPreview.parse(splitScalar)
        XCTAssertTrue(splitPreview.profiles.isEmpty)
        XCTAssertEqual(splitPreview.errors.count, 1)
        XCTAssertTrue(splitPreview.errors[0].hasPrefix("1件目:"))
    }

    func testAndroidImportUsesInt32ConsumptionSemanticsAndBoundsJSONValues() throws {
        let numeric = Data(#"[{"name":"numeric","mapData":{"abc":{"kana":"あ","consume":2147483648}}}]"#.utf8)
        XCTAssertEqual(try RomajiLibrary.importAndroid(numeric).first?.rules["abc"], RomajiRule("あ", 1))

        let outOfRangeString = Data(#"[{"name":"string","mapData":{"abc":{"kana":"あ","consume":"2147483648"}}}]"#.utf8)
        XCTAssertEqual(try RomajiLibrary.importAndroid(outOfRangeString).first?.rules["abc"], RomajiRule("あ", 3))

        let tooManyValues = "[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]"
        XCTAssertThrowsError(try RomajiImportPreview.parse(Data(tooManyValues.utf8)))
    }

    func testAndroidImportPreservesNumericJSONLexemesWhenNarrowingToInt32() throws {
        let cases: [(key: String, number: String, consume: Int, output: String)] = [
            ("a", "9007199254740995", 3, "あd"),
            ("a", "18446744073709551619", 3, "あd"),
            ("a", "9007199254740995.9", 3, "あd"),
            ("abc", "1e9999", 1, "あbcd"),
            ("abc", "1e10000", 3, "あd")
        ]

        for fixture in cases {
            let json = #"[{"name":"numeric","mapData":{"\#(fixture.key)":{"kana":"あ","consume":\#(fixture.number)}}}]"#
            let preview = try RomajiImportPreview.parse(Data(json.utf8))
            XCTAssertEqual(preview.errors, [], fixture.number)
            let profile = try XCTUnwrap(preview.profiles.first, fixture.number)
            XCTAssertEqual(profile.rules[fixture.key], RomajiRule("あ", fixture.consume), fixture.number)
            XCTAssertEqual(profile.converter.convert("abcd"), fixture.output, fixture.number)
        }
    }

    func testAndroidImportPreservesDeletionProtectionAndLegacyProfilesDefaultToDeletable() throws {
        let data = Data(#"[{"name":"protected","isDeletable":false,"mapData":{"a":{"kana":"あ","consume":1}}},{"name":"custom","mapData":{"ka":{"kana":"か","consume":2}}}]"#.utf8)
        let profiles = try RomajiLibrary.importAndroid(data)
        XCTAssertEqual(profiles.map(\.name), ["protected", "custom"])
        XCTAssertFalse(profiles[0].isDeletable)
        XCTAssertTrue(profiles[1].isDeletable)

        let encodedProtected = try JSONEncoder().encode(profiles[0])
        XCTAssertFalse(try JSONDecoder().decode(RomajiProfile.self, from: encodedProtected).isDeletable)

        var oldStoredProfile = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles[1])) as? [String: Any])
        oldStoredProfile.removeValue(forKey: "isDeletable")
        let oldStoredData = try JSONSerialization.data(withJSONObject: oldStoredProfile)
        XCTAssertTrue(try JSONDecoder().decode(RomajiProfile.self, from: oldStoredData).isDeletable)
    }
}
