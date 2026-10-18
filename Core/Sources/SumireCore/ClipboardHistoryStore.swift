import Foundation
import SQLite3
import CryptoKit
import ImageIO

public enum ClipboardHistorySettings {
    public static let enabledKey = "clipboard.historyEnabled"
    public static func isEnabled(defaults: UserDefaults) -> Bool { defaults.bool(forKey: enabledKey) }
    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults) { defaults.set(enabled, forKey: enabledKey) }
}

/// Synchronous local storage. Run on a host-owned background queue, never on the input/UI queue.
/// The store never accesses the pasteboard, network, or decodes image pixels.
public final class ClipboardHistoryStore {
    public enum Kind: String { case text, image }
    public struct Item: Equatable {
        public let id: Int64
        public let kind: Kind
        public let preview: String
        public let pinned: Bool
        public let timestamp: Int64 // Unix milliseconds
        public let byteCount: Int
        public let imageType: String?
        public let pixelWidth: Int?
        public let pixelHeight: Int?
    }
    public enum Content: Equatable { case text(String), image(Data) }
    public struct Limits {
        public static let maximumTextBytes = 65_536
        public static let maximumImageBytes = 4 * 1024 * 1024
        public static let maximumImagePixels = 4_000_000
        public static let maximumImageDimension = 4096
        public let count: Int
        public let totalBytes: Int
        public init(count: Int = 100, totalBytes: Int = 32 * 1024 * 1024) {
            self.count = count; self.totalBytes = totalBytes
        }
    }
    private var db: OpaquePointer?
    private let limits: Limits
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, limits: Limits = Limits()) throws {
        guard (1...100).contains(limits.count), (1...32 * 1024 * 1024).contains(limits.totalBytes), url.isFileURL else {
            throw PersonalDataError("クリップボード履歴の保存条件が不正です")
        }
        self.limits = limits
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 500)
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(Limits.maximumImageBytes + 4096))
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw PersonalDataError("未対応のクリップボード履歴形式です") }
            if version == 0 {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                    throw PersonalDataError("別のデータベースをクリップボード履歴に変更しません")
                }
            } else {
                let check = try prepare("PRAGMA quick_check(1)")
                defer { sqlite3_finalize(check) }
                guard sqlite3_step(check) == SQLITE_ROW, try string(check, 0) == "ok" else {
                    throw PersonalDataError("クリップボード履歴が破損しています")
                }
                try validateMetadata()
            }
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA cache_size=-512")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA journal_size_limit=1048576")
            try execute("PRAGMA wal_autocheckpoint=256")
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE clipboard_items(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,preview TEXT NOT NULL,pinned INTEGER NOT NULL CHECK(pinned IN (0,1)),timestamp INTEGER NOT NULL,byte_count INTEGER NOT NULL,image_type TEXT,pixel_width INTEGER,pixel_height INTEGER,sha256 TEXT NOT NULL)")
                    try execute("CREATE TABLE clipboard_payloads(id INTEGER PRIMARY KEY REFERENCES clipboard_items(id) ON DELETE CASCADE,content BLOB NOT NULL)")
                    try execute("PRAGMA user_version=1")
                }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    /// OFF returns nil without changing existing history. Clipboard permission is handled by the caller.
    @discardableResult public func recordText(_ text: String, historyEnabled: Bool, pinned: Bool = false, date: Date = Date()) throws -> Int64? {
        guard historyEnabled else { return nil }
        guard !text.isEmpty, text.utf8.count <= Limits.maximumTextBytes else { throw PersonalDataError("クリップボードの文字列は1〜65536バイトで保存できます") }
        var preview = ""
        for character in text.prefix(150) {
            let value = character.isWhitespace ? " " : String(character)
            guard preview.utf8.count + value.utf8.count <= 1024 else { break }
            preview += value
        }
        if preview.isEmpty { preview = "テキスト" }
        return try locked { try insert(kind: .text, data: Data(text.utf8), preview: preview, image: nil, pinned: pinned, date: date) }
    }

    /// Accepts encoded, single-frame PNG/JPEG/HEIC. ImageIO reads dimensions only (caching disabled).
    /// The caller must downsample separately before decoding/displaying; this store returns encoded bytes.
    @discardableResult public func recordImage(_ data: Data, historyEnabled: Bool, pinned: Bool = false, date: Date = Date()) throws -> Int64? {
        guard historyEnabled else { return nil }
        let image = try Self.imageMetadata(data)
        return try locked { try insert(kind: .image, data: data, preview: "画像", image: image, pinned: pinned, date: date) }
    }

    /// Metadata only: this query never selects text/image BLOBs. Pinned first, then newest first.
    public func items() throws -> [Item] {
        try locked {
            try validateMetadata()
            let statement = try prepare("SELECT id,kind,preview,pinned,timestamp,byte_count,image_type,pixel_width,pixel_height FROM clipboard_items ORDER BY pinned DESC,timestamp DESC,id DESC")
            defer { sqlite3_finalize(statement) }
            var result: [Item] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                result.append(try item(statement))
            }
            return result
        }
    }

    /// Loads one bounded payload, only on selection/explicit thumbnail request. No pixel decompression.
    public func content(id: Int64) throws -> Content? {
        try locked {
            let metadata = try prepare("SELECT id,kind,preview,pinned,timestamp,byte_count,image_type,pixel_width,pixel_height,sha256 FROM clipboard_items WHERE id=?")
            defer { sqlite3_finalize(metadata) }
            sqlite3_bind_int64(metadata, 1, id)
            let status = sqlite3_step(metadata)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw failure() }
            let entry = try item(metadata)
            let digest = try string(metadata, 9)
            let payload = try prepare("SELECT content FROM clipboard_payloads WHERE id=? AND length(content)=?")
            defer { sqlite3_finalize(payload) }
            sqlite3_bind_int64(payload, 1, id); sqlite3_bind_int64(payload, 2, Int64(entry.byteCount))
            guard sqlite3_step(payload) == SQLITE_ROW, sqlite3_column_bytes(payload, 0) == entry.byteCount,
                  let bytes = sqlite3_column_blob(payload, 0) else { throw PersonalDataError("クリップボード履歴の内容が破損しています") }
            let data = Data(bytes: bytes, count: entry.byteCount)
            guard Self.digest(data) == digest else { throw PersonalDataError("クリップボード履歴のチェックサムが一致しません") }
            if entry.kind == .text {
                guard let value = String(data: data, encoding: .utf8) else { throw PersonalDataError("クリップボードの文字コードが不正です") }
                return .text(value)
            }
            let image = try Self.imageMetadata(data)
            guard image.type == entry.imageType, image.width == entry.pixelWidth, image.height == entry.pixelHeight else {
                throw PersonalDataError("クリップボード画像のサイズ情報が一致しません")
            }
            return .image(data)
        }
    }

    public func setPinned(id: Int64, pinned: Bool) throws {
        try locked { try transaction {
            try validateMetadata()
            let statement = try prepare("UPDATE clipboard_items SET pinned=? WHERE id=?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, pinned ? 1 : 0); sqlite3_bind_int64(statement, 2, id)
            try done(statement)
        } }
    }
    public func delete(id: Int64) throws {
        try locked { try transaction {
            try validateMetadata()
            let statement = try prepare("DELETE FROM clipboard_items WHERE id=?")
            defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement, 1, id); try done(statement)
        } }
    }
    public func clear() throws {
        try locked { try transaction { try validateMetadata(); try execute("DELETE FROM clipboard_items") } }
    }
    /// Mirrors upstream expiration policy; pinned rows are never removed by retention or capacity eviction.
    @discardableResult public func deleteExpiredUnpinned(retentionHours: Int, now: Date = Date()) throws -> Int {
        guard (1...72).contains(retentionHours) else { throw PersonalDataError("履歴の保持時間は1〜72時間です") }
        let threshold = try Self.timestamp(now) - Int64(retentionHours) * 3_600_000
        return try locked { try transaction {
            try validateMetadata()
            let statement = try prepare("DELETE FROM clipboard_items WHERE pinned=0 AND timestamp<?")
            defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement, 1, threshold); try done(statement)
            return Int(sqlite3_changes(db))
        } }
    }

    private func insert(kind: Kind, data: Data, preview: String, image: ImageMetadata?, pinned: Bool, date: Date) throws -> Int64 {
        let timestamp = try Self.timestamp(date)
        guard data.count <= limits.totalBytes else { throw PersonalDataError("履歴の保存容量を超えています") }
        return try transaction {
            try validateMetadata()
            let statement = try prepare("INSERT INTO clipboard_items(kind,preview,pinned,timestamp,byte_count,image_type,pixel_width,pixel_height,sha256) VALUES(?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            try bind(kind.rawValue, statement, 1); try bind(preview, statement, 2)
            sqlite3_bind_int(statement, 3, pinned ? 1 : 0); sqlite3_bind_int64(statement, 4, timestamp)
            sqlite3_bind_int64(statement, 5, Int64(data.count))
            if let image {
                try bind(image.type, statement, 6); sqlite3_bind_int64(statement, 7, Int64(image.width)); sqlite3_bind_int64(statement, 8, Int64(image.height))
            } else { for index: Int32 in 6...8 { sqlite3_bind_null(statement, index) } }
            try bind(Self.digest(data), statement, 9); try done(statement)
            let id = sqlite3_last_insert_rowid(db)
            let payload = try prepare("INSERT INTO clipboard_payloads(id,content) VALUES(?,?)")
            defer { sqlite3_finalize(payload) }; sqlite3_bind_int64(payload, 1, id)
            let bound = data.withUnsafeBytes { sqlite3_bind_blob(payload, 2, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK else { throw failure() }; try done(payload)
            while try scalar("SELECT count(*) FROM clipboard_items") > limits.count || scalar("SELECT coalesce(sum(byte_count),0) FROM clipboard_items") > limits.totalBytes {
                let victim = try prepare("SELECT id FROM clipboard_items WHERE pinned=0 AND id<>? ORDER BY timestamp ASC,id ASC LIMIT 1")
                sqlite3_bind_int64(victim, 1, id)
                let status = sqlite3_step(victim)
                let oldID = sqlite3_column_int64(victim, 0); sqlite3_finalize(victim)
                guard status == SQLITE_ROW else { throw PersonalDataError("ピン留めされた履歴で上限に達したため保存できません") }
                let deletion = try prepare("DELETE FROM clipboard_items WHERE id=?")
                defer { sqlite3_finalize(deletion) }; sqlite3_bind_int64(deletion, 1, oldID); try done(deletion)
            }
            return id
        }
    }

    public static func validateImageData(_ data: Data) throws { _ = try imageMetadata(data) }

    private struct ImageMetadata { let type: String; let width: Int; let height: Int }
    private static func imageMetadata(_ data: Data) throws -> ImageMetadata {
        guard !data.isEmpty, data.count <= Limits.maximumImageBytes else { throw PersonalDataError("履歴画像は4MiB以下で保存できます") }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "public.heic", "public.heif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...Limits.maximumImageDimension).contains(width), (1...Limits.maximumImageDimension).contains(height),
              width <= Limits.maximumImagePixels / height,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw PersonalDataError("画像形式が不正か、画像サイズが上限（4096px・400万画素）を超えています")
        }
        return ImageMetadata(type: type, width: width, height: height)
    }
    private func validateMetadata() throws {
        guard try scalar("SELECT count(*) FROM clipboard_items") <= 100,
              try scalar("SELECT coalesce(sum(byte_count),0) FROM clipboard_items") <= 32 * 1024 * 1024,
              try scalar("SELECT count(*) FROM clipboard_items LEFT JOIN clipboard_payloads USING(id) WHERE clipboard_payloads.id IS NULL OR typeof(content)<>'blob' OR length(content)<>byte_count") == 0,
              try scalar("SELECT count(*) FROM clipboard_payloads LEFT JOIN clipboard_items USING(id) WHERE clipboard_items.id IS NULL") == 0 else {
            throw PersonalDataError("クリップボード履歴の件数・サイズ・構造が不正です")
        }
        let statement = try prepare("SELECT id,kind,preview,pinned,timestamp,byte_count,image_type,pixel_width,pixel_height,sha256 FROM clipboard_items")
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            _ = try item(statement)
            let hash = try string(statement, 9)
            guard hash.utf8.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw PersonalDataError("履歴のチェックサム形式が不正です") }
        }
    }
    private func item(_ statement: OpaquePointer) throws -> Item {
        guard [0, 3, 4, 5].allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
              sqlite3_column_type(statement, 1) == SQLITE_TEXT, sqlite3_column_type(statement, 2) == SQLITE_TEXT else {
            throw PersonalDataError("履歴のメタデータ型が不正です")
        }
        guard let kind = Kind(rawValue: try string(statement, 1)) else { throw PersonalDataError("履歴の種別が不正です") }
        let id = sqlite3_column_int64(statement, 0), pin = sqlite3_column_int64(statement, 3)
        let timestamp = sqlite3_column_int64(statement, 4), bytes = sqlite3_column_int64(statement, 5)
        let preview = try string(statement, 2)
        guard id > 0, (0...1).contains(pin), timestamp >= 0, !preview.isEmpty, preview.utf8.count <= 1024,
              bytes > 0, bytes <= (kind == .text ? Limits.maximumTextBytes : Limits.maximumImageBytes) else {
            throw PersonalDataError("履歴のサイズまたはメタデータが不正です")
        }
        let type = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : try string(statement, 6)
        let width = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7))
        let height = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 8))
        if kind == .image {
            guard let type, ["public.png", "public.jpeg", "public.heic", "public.heif"].contains(type), let width, let height,
                  (1...Limits.maximumImageDimension).contains(width), (1...Limits.maximumImageDimension).contains(height), width <= Limits.maximumImagePixels / height else {
                throw PersonalDataError("履歴画像のサイズ情報が不正です")
            }
        } else if type != nil || width != nil || height != nil { throw PersonalDataError("文字列履歴のメタデータが不正です") }
        return Item(id: id, kind: kind, preview: preview, pinned: pin == 1, timestamp: timestamp, byteCount: Int(bytes), imageType: type, pixelWidth: width, pixelHeight: height)
    }
    private static func timestamp(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw PersonalDataError("履歴の日時が不正です") }
        return Int64(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try action(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); throw failure() }
        return statement
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }; return sqlite3_column_int64(statement, 0)
    }
    private func done(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() } }
    private func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) throws {
        let result = value.utf8CString.withUnsafeBufferPointer { sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient) }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= 4096, let bytes = sqlite3_column_text(statement, column),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { throw PersonalDataError("履歴の文字コードまたは文字数が不正です") }
        return value
    }
    private func failure() -> PersonalDataError { PersonalDataError("クリップボード履歴を読み書きできません（SQLite \(sqlite3_errcode(db))）") }
}
