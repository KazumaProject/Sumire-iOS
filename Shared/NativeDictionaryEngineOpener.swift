import Foundation
#if canImport(SumireCAPI)
import SumireCAPI
#endif

struct OpenedNativeDictionaryEngine {
    let engine: OpaquePointer
    let directory: URL
}

enum NativeDictionaryEngineOpener {
    /// Opens the first usable immutable generation. A failed native load is
    /// remembered for the process lifetime, then recovery tries the previous
    /// generation and the bundled baseline in order.
    static func open(directories: [URL], mask: UInt32, english: Bool, englishReading: Bool,
                     rejecting rejectedDirectories: inout Set<URL>) throws -> OpenedNativeDictionaryEngine {
        let candidates = directories.map(\.standardizedFileURL)
            .filter { !rejectedDirectories.contains($0) }
        guard !candidates.isEmpty else {
            throw NativeDictionaryOpenError(message: "変換辞書が見つかりません。読みは保持しています")
        }

        var lastOpenError: String?
        for directory in candidates {
            var engine: OpaquePointer?
            var error = [CChar](repeating: 0, count: 1024)
            let status = sumire_engine_open_with_dictionaries(directory.path, mask,
                (english ? 1 : 0) | (englishReading ? 2 : 0), &engine, &error, error.count)
            if status == 0, let engine {
                return OpenedNativeDictionaryEngine(engine: engine, directory: directory)
            }
            rejectedDirectories.insert(directory)
            lastOpenError = String(cString: error)
        }
        throw NativeDictionaryOpenError(message: lastOpenError ?? "有効な辞書世代がありません。読みは保持しています")
    }
}

private struct NativeDictionaryOpenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
