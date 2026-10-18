import Foundation
import CZipSupport

/// Read-only ZIP container for the containing app's dictionary importer.
/// It never derives an output path from an archive entry name.
public struct DictionaryZipArchive {
    public struct Limits {
        public var archiveBytes: Int = 512 * 1024 * 1024
        public var entryBytes: Int = 512 * 1024 * 1024
        public var totalBytes: Int = 2 * 1024 * 1024 * 1024
        public var entries: Int = 4096
        public init() {}
    }
    public struct Entry: Equatable {
        public let name: String
        public let uncompressedBytes: Int
        public let isDirectory: Bool
        fileprivate let start: Int
        fileprivate let compressedBytes: Int
        fileprivate let method: UInt16
        fileprivate let crc: UInt32
    }
    public let entries: [Entry]
    private let bytes: Data

    public init(url: URL, limits: Limits = Limits()) throws {
        guard url.isFileURL else { throw PersonalDataError("辞書ZIPはローカルファイルを選んでください") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limits.archiveBytes else { throw PersonalDataError("辞書ZIPの容量が上限を超えています") }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }
    public init(data: Data, limits: Limits = Limits()) throws {
        guard limits.archiveBytes >= 22, limits.entryBytes >= 0, limits.totalBytes >= 0,
              limits.entries >= 0, data.count <= limits.archiveBytes, data.count >= 22 else {
            throw PersonalDataError("辞書ZIPの容量または上限設定が不正です")
        }
        // Data may be a slice with a nonzero startIndex.
        let data = Data(data)
        func bad() -> PersonalDataError { PersonalDataError("辞書ZIPが壊れているか、未対応の形式です") }
        func u16(_ p: Int) throws -> UInt16 {
            guard p >= 0, p <= data.count - 2 else { throw bad() }
            return UInt16(data[p]) | UInt16(data[p + 1]) << 8
        }
        func u32(_ p: Int) throws -> UInt32 {
            UInt32(try u16(p)) | UInt32(try u16(p + 2)) << 16
        }
        var end: Int?
        for p in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(p) == 0x06054b50, p + 22 + Int(try u16(p + 20)) == data.count { end = p; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == u16(end + 10) else { throw bad() }
        let count = Int(try u16(end + 10)), centralSize = Int(try u32(end + 12))
        let central = Int(try u32(end + 16))
        guard count != 65535, count <= limits.entries, central <= end,
              centralSize == end - central else { throw bad() }
        var result: [Entry] = [], names = Set<String>(), ranges: [Range<Int>] = []
        var offset = central, total = 0
        for _ in 0..<count {
            guard offset <= end - 46, try u32(offset) == 0x02014b50,
                  try u16(offset + 6) <= 20, try u16(offset + 34) == 0 else { throw bad() }
            let flags = try u16(offset + 8), method = try u16(offset + 10)
            let crc = try u32(offset + 16), packed = Int(try u32(offset + 20)), unpacked = Int(try u32(offset + 24))
            let nameLength = Int(try u16(offset + 28)), extraLength = Int(try u16(offset + 30))
            let commentLength = Int(try u16(offset + 32)), local = Int(try u32(offset + 42))
            let recordSize = 46 + nameLength + extraLength + commentLength
            guard recordSize <= end - offset, nameLength > 0, nameLength <= 4096,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  method == 8 || flags & 6 == 0,
                  packed != Int(UInt32.max), unpacked <= limits.entryBytes,
                  unpacked <= limits.totalBytes - total,
                  (try u32(offset + 38) >> 16) & 0xf000 != 0xa000 else { throw bad() }
            let rawName = data.subdata(in: offset + 46..<offset + 46 + nameLength)
            guard let name = String(data: rawName, encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { throw bad() }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.dropLast().contains(where: { $0.isEmpty }),
                  !components.contains("."), !components.contains(".."), names.insert(name).inserted else { throw bad() }
            guard local <= central - 30, try u32(local) == 0x04034b50,
                  try u16(local + 4) <= 20, try u16(local + 6) == flags,
                  try u16(local + 8) == method, Int(try u16(local + 26)) == nameLength else { throw bad() }
            let start = local + 30 + nameLength + Int(try u16(local + 28))
            guard start <= central, packed <= central - start,
                  data.subdata(in: local + 30..<local + 30 + nameLength) == rawName else { throw bad() }
            var finish = start + packed
            if flags & 8 == 0 {
                guard try u32(local + 14) == crc, Int(try u32(local + 18)) == packed,
                      Int(try u32(local + 22)) == unpacked else { throw bad() }
            } else {
                guard (try u32(local + 14) == 0 || u32(local + 14) == crc),
                      (try u32(local + 18) == 0 || Int(u32(local + 18)) == packed),
                      (try u32(local + 22) == 0 || Int(u32(local + 22)) == unpacked) else { throw bad() }
                // Descriptor lengths come from the central directory, never a scan
                // for a signature inside compressed bytes.
                func descriptor(_ p: Int) throws -> Bool {
                    guard p <= central - 12 else { return false }
                    return try u32(p) == crc && Int(u32(p + 4)) == packed && Int(u32(p + 8)) == unpacked
                }
                if try descriptor(finish) { finish += 12 }
                else if finish <= central - 16, try u32(finish) == 0x08074b50, try descriptor(finish + 4) { finish += 16 }
                else { throw bad() }
            }
            let directory = name.hasSuffix("/")
            guard !directory || (unpacked == 0 && crc == 0),
                  method != 0 || packed == unpacked else { throw bad() }
            if directory {
                let valid = data.withUnsafeBytes { raw in
                    sumire_zip_validate(raw.bindMemory(to: UInt8.self).baseAddress?.advanced(by: start),
                                        packed, method, 0, 0)
                }
                guard valid == 0 else { throw bad() }
            }
            total += unpacked; ranges.append(local..<finish)
            result.append(Entry(name: name, uncompressedBytes: unpacked, isDirectory: directory,
                                start: start, compressedBytes: packed, method: method, crc: crc))
            offset += recordSize
        }
        guard offset == end else { throw bad() }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for i in 1..<max(1, sorted.count) where sorted[i - 1].upperBound > sorted[i].lowerBound { throw bad() }
        self.bytes = data; self.entries = result
    }
    /// The destination must not exist. A CRC/size/decompression/write error
    /// removes the newly created file; existing files are never overwritten.
    public func extract(_ entry: Entry, to destination: URL) throws {
        guard destination.isFileURL, !entry.isDirectory, entries.contains(entry) else {
            throw PersonalDataError("辞書ZIPの展開要求が不正です")
        }
        let result = bytes.withUnsafeBytes { raw in
            destination.withUnsafeFileSystemRepresentation { path in
                sumire_zip_extract(raw.bindMemory(to: UInt8.self).baseAddress?.advanced(by: entry.start),
                                   entry.compressedBytes, entry.method, UInt64(entry.uncompressedBytes), entry.crc, path)
            }
        }
        guard result == 0 else { throw PersonalDataError("辞書ZIPを展開できません（検証エラー \(result)）") }
    }
}
