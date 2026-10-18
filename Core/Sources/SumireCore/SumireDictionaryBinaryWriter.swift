import Foundation
import CZipSupport

/// Writes the read-only dictionary container consumed by ConversionCore.
/// Source arrays stay in their existing buffers; the writer streams sections
/// to an explicitly selected new file instead of building a second full file
/// image in memory.
public enum SumireDictionaryBinaryWriter {
    public enum Kind: UInt32 {
        case dictionary = 1
        case connection = 2
        case standalone = 3

        fileprivate var sectionCount: Int {
            switch self {
            case .dictionary: 10
            case .connection: 7
            case .standalone: 2
            }
        }
    }

    /// Creates `destination` exclusively. The parent directory must already
    /// be a private staging directory owned by the caller. Archive entry names
    /// must never be used to choose this URL.
    public static func write(kind: Kind, dimension: UInt32 = 0, sections: [Data], to destination: URL) throws {
        guard destination.isFileURL, sections.count == kind.sectionCount,
              (kind == .connection ? dimension > 0 : dimension == 0) else {
            throw PersonalDataError("辞書ファイルの種類、次元、またはセクション数が不正です")
        }
        let code = withPointers(to: sections, at: 0, collected: []) { pointers in
            let nativePointers = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: sections.count)
            let lengths = UnsafeMutablePointer<UInt64>.allocate(capacity: sections.count)
            defer {
                nativePointers.deallocate()
                lengths.deallocate()
            }
            for index in sections.indices {
                nativePointers[index] = pointers[index]
                lengths[index] = UInt64(sections[index].count)
            }
            return destination.standardizedFileURL.path.withCString { path in
                sumire_dictionary_write(path, kind.rawValue, dimension, UInt32(sections.count),
                                        UnsafePointer(nativePointers), UnsafePointer(lengths))
            }
        }
        guard code == 0 else {
            let message: String
            switch code {
            case 2: message = "辞書ファイルのメタデータ領域を確保できません"
            case 3: message = "辞書ファイルの新規作成に失敗しました"
            case 4: message = "辞書ファイルの書き込みまたは同期に失敗しました"
            default: message = "辞書ファイルの範囲またはサイズが不正です"
            }
            throw PersonalDataError(message)
        }
    }

    private static func withPointers<Result>(
        to sections: [Data],
        at index: Int,
        collected: [UnsafePointer<UInt8>?],
        body: ([UnsafePointer<UInt8>?]) throws -> Result
    ) rethrows -> Result {
        guard index < sections.count else { return try body(collected) }
        return try sections[index].withUnsafeBytes { bytes in
            try withPointers(to: sections, at: index + 1,
                             collected: collected + [bytes.bindMemory(to: UInt8.self).baseAddress],
                             body: body)
        }
    }
}
