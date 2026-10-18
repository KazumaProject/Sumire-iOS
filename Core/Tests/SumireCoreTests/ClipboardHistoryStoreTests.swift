import XCTest
import SQLite3
import ImageIO
import CoreGraphics
@testable import SumireCore

final class ClipboardHistoryStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SumireClipboardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.sqlite")
    }
    private func png(width: Int = 2, height: Int = 3) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func sql(_ url: URL, _ command: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, command, nil, nil, nil), SQLITE_OK)
    }

    func testRestartMetadataAndSelectedContentPreserveTextAndImages() throws {
        let url = try temporaryURL(), image = try png()
        var store: ClipboardHistoryStore? = try ClipboardHistoryStore(url: url)
        let text = "日本語👩‍💻\0' ; DROP TABLE clipboard_items; --\nnext"
        let textID = try XCTUnwrap(store!.recordText(text, historyEnabled: true))
        let imageID = try XCTUnwrap(store!.recordImage(image, historyEnabled: true))
        try store!.setPinned(id: textID, pinned: true)
        store = nil
        store = try ClipboardHistoryStore(url: url)
        let entries = try store!.items()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.id, textID)
        XCTAssertEqual(entries.last?.kind, .image)
        XCTAssertEqual(entries.last?.pixelWidth, 2)
        XCTAssertEqual(entries.last?.pixelHeight, 3)
        XCTAssertEqual(try store!.content(id: textID), .text(text))
        XCTAssertEqual(try store!.content(id: imageID), .image(image))
        try store!.setPinned(id: textID, pinned: false)
        XCTAssertFalse(try XCTUnwrap(store!.items().first { $0.id == textID }).pinned)
        try store!.delete(id: imageID)
        XCTAssertNil(try store!.content(id: imageID))
        try store!.clear()
        XCTAssertEqual(try store!.items(), [])
    }

    func testOffDoesNotRecordOrDeleteExistingHistory() throws {
        let store = try ClipboardHistoryStore(url: temporaryURL())
        let id = try XCTUnwrap(store.recordText("retained", historyEnabled: true))
        XCTAssertNil(try store.recordText("not saved", historyEnabled: false))
        XCTAssertNil(try store.recordImage(Data(), historyEnabled: false))
        XCTAssertEqual(try store.items().count, 1)
        XCTAssertEqual(try store.content(id: id), .text("retained"))
        let name = "ClipboardSettings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(ClipboardHistorySettings.isEnabled(defaults: defaults))
        ClipboardHistorySettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(ClipboardHistorySettings.isEnabled(defaults: defaults))
    }

    func testCountAndByteEvictionNeverRemovePinnedRows() throws {
        let store = try ClipboardHistoryStore(url: temporaryURL(), limits: .init(count: 3, totalBytes: 12))
        let pinned = try XCTUnwrap(store.recordText("aaaa", historyEnabled: true, pinned: true, date: Date(timeIntervalSince1970: 1)))
        let old = try XCTUnwrap(store.recordText("bbbb", historyEnabled: true, date: Date(timeIntervalSince1970: 2)))
        let recent = try XCTUnwrap(store.recordText("cccc", historyEnabled: true, date: Date(timeIntervalSince1970: 3)))
        _ = try store.recordText("dddd", historyEnabled: true, date: Date(timeIntervalSince1970: 4))
        XCTAssertNil(try store.content(id: old))
        XCTAssertEqual(try store.content(id: pinned), .text("aaaa"))
        XCTAssertNotNil(try store.content(id: recent))
        let before = try store.items()
        for item in before { try store.setPinned(id: item.id, pinned: true) }
        let allPinned = try store.items()
        XCTAssertThrowsError(try store.recordText("new", historyEnabled: true))
        XCTAssertEqual(try store.items(), allPinned)
    }

    func testCountAndByteBudgetsAreIndependentlyEnforced() throws {
        let countStore = try ClipboardHistoryStore(url: temporaryURL(), limits: .init(count: 2, totalBytes: 100))
        let oldest = try XCTUnwrap(countStore.recordText("a", historyEnabled: true))
        _ = try countStore.recordText("b", historyEnabled: true)
        _ = try countStore.recordText("c", historyEnabled: true)
        XCTAssertEqual(try countStore.items().count, 2)
        XCTAssertNil(try countStore.content(id: oldest))
        let byteStore = try ClipboardHistoryStore(url: temporaryURL(), limits: .init(count: 100, totalBytes: 5))
        let first = try XCTUnwrap(byteStore.recordText("abc", historyEnabled: true))
        _ = try byteStore.recordText("def", historyEnabled: true)
        XCTAssertEqual(try byteStore.items().count, 1)
        XCTAssertNil(try byteStore.content(id: first))
    }

    func testRollbackRestoresEvictedRowsIfPinnedBytesPreventInsert() throws {
        let store = try ClipboardHistoryStore(url: temporaryURL(), limits: .init(count: 3, totalBytes: 10))
        _ = try store.recordText("12345678", historyEnabled: true, pinned: true)
        let other = try XCTUnwrap(store.recordText("ab", historyEnabled: true))
        let before = try store.items()
        XCTAssertThrowsError(try store.recordText("xyz", historyEnabled: true))
        XCTAssertEqual(try store.items(), before)
        XCTAssertEqual(try store.content(id: other), .text("ab"))
    }

    func testMalformedAndOversizedInputsLeaveExistingHistory() throws {
        let store = try ClipboardHistoryStore(url: temporaryURL())
        _ = try store.recordText("kept", historyEnabled: true)
        let before = try store.items()
        XCTAssertThrowsError(try store.recordText("", historyEnabled: true))
        XCTAssertThrowsError(try store.recordText(String(repeating: "あ", count: 22000), historyEnabled: true))
        XCTAssertThrowsError(try store.recordImage(Data("not an image".utf8), historyEnabled: true))
        XCTAssertThrowsError(try store.recordImage(Data(repeating: 0, count: ClipboardHistoryStore.Limits.maximumImageBytes + 1), historyEnabled: true))
        XCTAssertThrowsError(try store.recordImage(png(width: 4097, height: 1), historyEnabled: true))
        XCTAssertThrowsError(try store.recordImage(png(width: 2001, height: 2000), historyEnabled: true))
        XCTAssertThrowsError(try store.recordText("date", historyEnabled: true, date: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try store.items(), before)
    }

    func testExpirationDeletesOnlyUnpinnedOlderThanThreshold() throws {
        let store = try ClipboardHistoryStore(url: temporaryURL())
        let old = Date(timeIntervalSince1970: 1)
        _ = try store.recordText("old", historyEnabled: true, date: old)
        _ = try store.recordText("pin", historyEnabled: true, pinned: true, date: old)
        _ = try store.recordText("new", historyEnabled: true, date: Date(timeIntervalSince1970: 7199))
        XCTAssertEqual(try store.deleteExpiredUnpinned(retentionHours: 1, now: Date(timeIntervalSince1970: 7200)), 1)
        XCTAssertEqual(try store.items().map(\.preview).sorted(), ["new", "pin"])
        XCTAssertThrowsError(try store.deleteExpiredUnpinned(retentionHours: 0))
    }

    func testUnknownOrCorruptDatabaseIsNotReplaced() throws {
        let url = try temporaryURL()
        let original = Data("corrupt-not-sqlite".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try ClipboardHistoryStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let future = try temporaryURL()
        try sql(future, "PRAGMA user_version=999; CREATE TABLE keep(value TEXT); INSERT INTO keep VALUES('retained')")
        let bytes = try Data(contentsOf: future)
        XCTAssertThrowsError(try ClipboardHistoryStore(url: future))
        XCTAssertEqual(try Data(contentsOf: future), bytes)
    }

    func testMetadataListingDoesNotReadPayloadAndSelectionDetectsTampering() throws {
        let url = try temporaryURL()
        let store = try ClipboardHistoryStore(url: url)
        let id = try XCTUnwrap(store.recordText("original", historyEnabled: true))
        try sql(url, "UPDATE clipboard_payloads SET content=CAST('tampered' AS BLOB) WHERE id=\(id)")
        // Matching byte length is enough for a metadata-only list, but selection checks the actual bytes.
        XCTAssertEqual(try store.items().count, 1)
        XCTAssertThrowsError(try store.content(id: id))
        try sql(url, "UPDATE clipboard_items SET byte_count=99999999 WHERE id=\(id)")
        XCTAssertThrowsError(try store.items())
        XCTAssertThrowsError(try store.recordText("new", historyEnabled: true))
        XCTAssertThrowsError(try ClipboardHistoryStore(url: url))
    }
}
