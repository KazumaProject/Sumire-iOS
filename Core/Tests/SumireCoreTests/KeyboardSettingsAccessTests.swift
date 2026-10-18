import XCTest
@testable import SumireCore

final class KeyboardSettingsAccessTests: XCTestCase {
    private func stores(_ body: (UserDefaults, UserDefaults) throws -> Void) rethrows {
        let a = "SharedSettingsTests." + UUID().uuidString
        let b = "LocalSettingsTests." + UUID().uuidString
        let shared = UserDefaults(suiteName: a)!, local = UserDefaults(suiteName: b)!
        defer { shared.removePersistentDomain(forName: a); local.removePersistentDomain(forName: b) }
        try body(shared, local)
    }

    func testClosedAccessReadsAppValuesWithoutMigratingOrWritingSharedStore() throws {
        try stores { shared, local in
            shared.set(3, forKey: "candidateRowCount")
            let theme = KeyboardTheme(hue: 0.2, mode: .dark, saturation: 0.8, brightness: 0.9)
            theme.save(defaults: shared)
            local.set(1, forKey: "candidateRowCount")
            KeyboardTheme(hue: 0.7).save(defaults: local)
            let before = shared.dictionaryRepresentation() as NSDictionary
            let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            XCTAssertTrue(access.readsSharedSettings)
            XCTAssertFalse(access.writesSharedSettings)
            XCTAssertTrue(access.writeDefaults === local)
            XCTAssertEqual(access.readDefaults.integer(forKey: "candidateRowCount"), 3)
            XCTAssertEqual(KeyboardTheme.load(defaults: access.readDefaults), theme)
            // Accidental readers calling a save method cannot write either store.
            KeyboardTheme().save(defaults: access.readDefaults)
            try KeyboardSelection(ids: ["sumire"]).save(defaults: access.readDefaults)
            access.reload()
            XCTAssertEqual(before, shared.dictionaryRepresentation() as NSDictionary)
            XCTAssertEqual(local.integer(forKey: "candidateRowCount"), 1)
            XCTAssertNil(shared.object(forKey: "internal.appGroupSettingsMigrated.v1"))
        }
    }

    func testRuntimeWritesPersistPrivatelyAndHostChangesInvalidateOverlay() throws {
        try stores { shared, local in
            let key = KeyboardSizingStore.key(.portrait)
            let initial = KeyboardSize(height: 300, width: 1, alignment: 0.5)
            let privateSize = KeyboardSize(height: 360, width: 0.8, alignment: 1)
            let hostSize = KeyboardSize(height: 330, width: 0.9, alignment: 0)
            try KeyboardSizingStore(defaults: shared).save(initial, for: .portrait)
            let before = shared.dictionaryRepresentation() as NSDictionary
            let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            try KeyboardSizingStore(defaults: access.writeDefaults).save(privateSize, for: .portrait)
            access.didWrite([key])
            XCTAssertEqual(KeyboardSizingStore(defaults: access.readDefaults).load(.portrait), privateSize)
            XCTAssertEqual(shared.dictionaryRepresentation() as NSDictionary, before)
            let recreated = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            XCTAssertEqual(KeyboardSizingStore(defaults: recreated.readDefaults).load(.portrait), privateSize)
            try KeyboardSizingStore(defaults: shared).save(hostSize, for: .portrait)
            recreated.reload()
            XCTAssertEqual(KeyboardSizingStore(defaults: recreated.readDefaults).load(.portrait), hostSize)
            XCTAssertNil(local.object(forKey: key))
            shared.removeObject(forKey: key)
            recreated.reload()
            XCTAssertEqual(KeyboardSizingStore(defaults: recreated.readDefaults).load(.portrait), .standard(.portrait))
        }
    }

    func testPrivateResetAndLegacyStateAndOpenAccessPromotion() throws {
        try stores { shared, local in
            local.set("sumire", forKey: "keyboard.lastUsed")
            let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            XCTAssertEqual(access.readDefaults.string(forKey: "keyboard.lastUsed"), "sumire")
            XCTAssertNil(shared.string(forKey: "keyboard.lastUsed"))
            access.writeDefaults.removeObject(forKey: "keyboard.lastUsed")
            access.didWrite(["keyboard.lastUsed"])
            XCTAssertNil(access.readDefaults.object(forKey: "keyboard.lastUsed"))
            access.writeDefaults.set("tenKey", forKey: "keyboard.lastUsed")
            access.didWrite(["keyboard.lastUsed"])
            let open = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: true)
            XCTAssertTrue(open.writeDefaults === shared)
            XCTAssertEqual(shared.string(forKey: "keyboard.lastUsed"), "tenKey")
            XCTAssertNil(local.object(forKey: "keyboard.lastUsed"))
            shared.set("romaji", forKey: "keyboard.lastUsed")
            open.reload()
            XCTAssertEqual(open.readDefaults.string(forKey: "keyboard.lastUsed"), "romaji")
        }
    }

    func testMalformedOverlayCannotReplaceSharedOrResurrectAfterRemoval() {
        stores { shared, local in
            let key = KeyboardSizingStore.key(.portrait)
            shared.set("sumire", forKey: "keyboard.lastUsed")
            local.set(Data("broken size".utf8), forKey: key)
            local.set("tenKey", forKey: "keyboard.lastUsed")
            local.set([key: Data([1]), "keyboard.lastUsed": "invalid digest"], forKey: "internal.extensionSettingsOverlay.v1")
            let before = shared.dictionaryRepresentation() as NSDictionary
            let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            XCTAssertEqual(access.readDefaults.string(forKey: "keyboard.lastUsed"), "sumire")
            XCTAssertEqual(KeyboardSizingStore(defaults: access.readDefaults).load(.portrait), .standard(.portrait))
            XCTAssertNil(local.object(forKey: "keyboard.lastUsed"))
            XCTAssertNil(local.object(forKey: key))
            XCTAssertEqual(before, shared.dictionaryRepresentation() as NSDictionary)
            shared.removeObject(forKey: "keyboard.lastUsed")
            access.reload()
            XCTAssertNil(access.readDefaults.object(forKey: "keyboard.lastUsed"))
        }
    }

    func testHostChangeBeforePromotionWinsAndUnrelatedLocalKeysNeverOverlay() {
        stores { shared, local in
            shared.set("sumire", forKey: "keyboard.lastUsed")
            let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            local.set("tenKey", forKey: "keyboard.lastUsed")
            local.set(2, forKey: "candidateRowCount")
            access.didWrite(["keyboard.lastUsed", "candidateRowCount"])
            XCTAssertNil(access.readDefaults.object(forKey: "candidateRowCount"))
            shared.set("romaji", forKey: "keyboard.lastUsed")
            let open = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: true)
            XCTAssertEqual(open.readDefaults.string(forKey: "keyboard.lastUsed"), "romaji")
            XCTAssertEqual(shared.string(forKey: "keyboard.lastUsed"), "romaji")
        }
    }

    func testMissingGroupUsesPrivateSettingsAndRefreshesAfterRuntimeWrite() {
        stores { _, local in
            local.set(2, forKey: "candidateRowCount")
            let access = KeyboardSettingsAccess(shared: nil, local: local, allowSharedWrites: true)
            XCTAssertFalse(access.readsSharedSettings)
            XCTAssertFalse(access.writesSharedSettings)
            XCTAssertEqual(access.readDefaults.integer(forKey: "candidateRowCount"), 2)
            local.set("sumire", forKey: "keyboard.lastUsed")
            access.didWrite(["keyboard.lastUsed"])
            XCTAssertEqual(access.readDefaults.string(forKey: "keyboard.lastUsed"), "sumire")
        }
    }
}
