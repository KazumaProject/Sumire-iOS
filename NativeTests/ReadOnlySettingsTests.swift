import XCTest
import SumireCore

final class ReadOnlySettingsTests: XCTestCase {
    private func convert(_ service: ConversionService, _ reading: String,
                         generation: UInt64) throws -> ConversionResponse {
        let complete = expectation(description: "Reset conversion")
        var result: Result<ConversionResponse, Error>?
        service.convert(reading, generation: generation, editStart: 0, english: false) {
            result = $0; complete.fulfill()
        }
        wait(for: [complete], timeout: 20)
        return try XCTUnwrap(result).get()
    }

    func testLearningResetClearsPrivateDatabaseOnProductionConversionQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sharedName = "NativeResetShared." + UUID().uuidString, localName = "NativeResetLocal." + UUID().uuidString
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName)), local = try XCTUnwrap(UserDefaults(suiteName: localName))
        defer {
            shared.removePersistentDomain(forName: sharedName); local.removePersistentDomain(forName: localName)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("private-learning.sqlite")
        try LearningStore(url: url).record(reading: "しろ", text: "白")
        let service = ConversionService()
        service.setLearning(url: url)
        let learned = try convert(service, "しろ", generation: 1).candidates.first {
            $0.text == "白" && $0.dictionaries.contains("learning")
        }
        XCTAssertNotNil(learned)
        let token = UUID().uuidString
        shared.set(token, forKey: "learning.resetToken")
        let reset = try XCTUnwrap(LocalDataReset(store: .learning, url: url, sharedDefaults: shared, localDefaults: local))
        service.setLearning(url: url, localReset: reset)
        let cleared = try convert(service, "しろ", generation: 2)
        XCTAssertFalse(cleared.candidates.contains { $0.dictionaries.contains("learning") })
        XCTAssertNil(cleared.warning)
        XCTAssertEqual(try LearningStore(url: url).candidates(reading: "しろ"), [])
        XCTAssertEqual(local.string(forKey: "internal.appliedReset.learning"), token)
        XCTAssertNil(shared.object(forKey: "internal.appliedReset.learning"))

        // A broken local database must not silently keep learning active or
        // acknowledge an operation that could not be completed.
        let broken = root.appendingPathComponent("broken.sqlite")
        try Data("not sqlite".utf8).write(to: broken)
        let next = UUID().uuidString
        shared.set(next, forKey: "learning.resetToken")
        let failed = try XCTUnwrap(LocalDataReset(store: .learning, url: broken, sharedDefaults: shared, localDefaults: local))
        service.setLearning(url: url, localReset: failed)
        let stopped = try convert(service, "しろ", generation: 3)
        XCTAssertFalse(stopped.candidates.contains { $0.dictionaries.contains("learning") })
        XCTAssertTrue(stopped.warning?.contains("削除を再試行") == true)
        XCTAssertEqual(local.string(forKey: "internal.appliedReset.learning"), token)
    }

    func testIOSFoundationReaderAndWriterIsolationAndHostRefresh() throws {
        let sharedName = "NativeShared." + UUID().uuidString, localName = "NativeLocal." + UUID().uuidString
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        let local = try XCTUnwrap(UserDefaults(suiteName: localName))
        defer { shared.removePersistentDomain(forName: sharedName); local.removePersistentDomain(forName: localName) }
        shared.set(3, forKey: "candidateRowCount")
        shared.set(0.25, forKey: "theme.hue")
        shared.set("dark", forKey: "theme.mode")
        shared.set(true, forKey: "learningEnabled")
        shared.set(["a", "b"], forKey: "array")
        let before = shared.dictionaryRepresentation() as NSDictionary
        let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
        let reader = access.readDefaults
        XCTAssertEqual(KeyboardSettings.candidateRowCount(from: reader), 3)
        XCTAssertEqual(KeyboardTheme.load(defaults: reader).hue, 0.25)
        XCTAssertEqual(KeyboardTheme.load(defaults: reader).mode, .dark)
        XCTAssertTrue(reader.bool(forKey: "learningEnabled"))
        XCTAssertEqual(reader.stringArray(forKey: "array"), ["a", "b"])
        reader.set(1, forKey: "candidateRowCount")
        reader.register(defaults: ["unexpectedReadOnlyRegistration": true])
        XCTAssertEqual(KeyboardSettings.candidateRowCount(from: reader), 3)
        XCTAssertNil(local.object(forKey: "unexpectedReadOnlyRegistration"))
        access.writeDefaults.set("sumire", forKey: "keyboard.lastUsed")
        access.didWrite(["keyboard.lastUsed"])
        XCTAssertEqual(reader.string(forKey: "keyboard.lastUsed"), "sumire")
        XCTAssertEqual(before, shared.dictionaryRepresentation() as NSDictionary)
        shared.set(2, forKey: "candidateRowCount")
        shared.set("tenKey", forKey: "keyboard.lastUsed")
        access.reload()
        XCTAssertEqual(KeyboardSettings.candidateRowCount(from: reader), 2)
        XCTAssertEqual(reader.string(forKey: "keyboard.lastUsed"), "tenKey")
    }
}
