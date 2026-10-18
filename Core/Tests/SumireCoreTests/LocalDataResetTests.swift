import XCTest
@testable import SumireCore

final class LocalDataResetTests: XCTestCase {
    private func fixture(_ body: (UserDefaults, UserDefaults, URL) throws -> Void) throws {
        let a = "ResetShared." + UUID().uuidString, b = "ResetLocal." + UUID().uuidString
        let shared = UserDefaults(suiteName: a)!, local = UserDefaults(suiteName: b)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            shared.removePersistentDomain(forName: a); local.removePersistentDomain(forName: b)
            try? FileManager.default.removeItem(at: root)
        }
        try body(shared, local, root)
    }
    func testBothPrivateDatabasesClearAndOnlyPrivateAcknowledgementsChange() throws {
        try fixture { shared, local, root in
            for store in [LocalDataReset.Store.learning, .clipboard] {
                let url = root.appendingPathComponent(store.rawValue + ".sqlite")
                if store == .learning { try LearningStore(url: url).record(reading: "あ", text: "亜") }
                else { try ClipboardHistoryStore(url: url).recordText("fixture", historyEnabled: true, pinned: true) }
                shared.set(UUID().uuidString, forKey: store.rawValue + ".resetToken")
                let before = shared.dictionaryRepresentation() as NSDictionary
                let reset = try XCTUnwrap(LocalDataReset(store: store, url: url, sharedDefaults: shared, localDefaults: local))
                try reset.apply()
                XCTAssertNil(LocalDataReset(store: store, url: url, sharedDefaults: shared, localDefaults: local))
                XCTAssertEqual(before, shared.dictionaryRepresentation() as NSDictionary)
                if store == .learning { XCTAssertEqual(try LearningStore(url: url).candidates(reading: "あ"), []) }
                else { XCTAssertEqual(try ClipboardHistoryStore(url: url).items(), []) }
            }
        }
    }
    func testFailureDoesNotAcknowledgeAndNewRequestsAndPermissionsDoNotLoseDeletion() throws {
        try fixture { shared, local, root in
            let url = root.appendingPathComponent("learning.sqlite")
            let token = UUID().uuidString
            shared.set(token, forKey: "learning.resetToken")
            let closed = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            let reset = try XCTUnwrap(LocalDataReset(store: .learning, url: url, sharedDefaults: closed.readDefaults, localDefaults: local))
            XCTAssertThrowsError(try reset.apply { _ in throw PersonalDataError("fixture failure") })
            XCTAssertNil(local.string(forKey: "internal.appliedReset.learning"))
            // Opening write access does not acknowledge a private deletion in the
            // shared defaults, nor skip a deletion previously attempted OFF.
            let open = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: true)
            let retry = try XCTUnwrap(LocalDataReset(store: .learning, url: url, sharedDefaults: open.readDefaults, localDefaults: local))
            try retry.apply()
            XCTAssertEqual(local.string(forKey: "internal.appliedReset.learning"), token)
            XCTAssertNil(shared.object(forKey: "internal.appliedReset.learning"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            shared.set(UUID().uuidString, forKey: "learning.resetToken")
            open.reload()
            XCTAssertNotNil(LocalDataReset(store: .learning, url: url, sharedDefaults: open.readDefaults, localDefaults: local))
            shared.set("malformed", forKey: "learning.resetToken")
            open.reload()
            XCTAssertNil(LocalDataReset(store: .learning, url: url, sharedDefaults: open.readDefaults, localDefaults: local))
        }
    }
}
