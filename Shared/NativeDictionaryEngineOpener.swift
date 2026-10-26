import Foundation
import SumireCore
#if canImport(SumireCAPI)
import SumireCAPI
#endif

struct OpenedNativeDictionaryEngine {
    let engine: OpaquePointer
    let directory: URL
    let unavailableCategoryIDs: [String]
}

enum NativeDictionaryEngineOpener {
    /// Opens the first usable immutable generation. A failed native load is
    /// remembered for the process lifetime, then recovery tries the previous
    /// generation and the bundled baseline in order.
    static func open(directories: [URL], mask: UInt32, english: Bool, englishReading: Bool,
                     rejecting rejectedDirectories: inout Set<URL>, categoryIDs: [String]? = nil) throws -> OpenedNativeDictionaryEngine {
        let candidates = directories.map(\.standardizedFileURL)
            .filter { !rejectedDirectories.contains($0) }
        guard !candidates.isEmpty else {
            throw NativeDictionaryOpenError(message: "変換辞書が見つかりません。読みは保持しています")
        }

        var lastOpenError: String?
        for directory in candidates {
            var engine: OpaquePointer?
            var error = [CChar](repeating: 0, count: 1024)
            let status: Int32
            let flags: UInt32 = (english ? 1 : 0) | (englishReading ? 2 : 0)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path) {
                let selected = categoryIDs ?? DictionaryCategoryCatalog.expanded(legacyMask: mask)
                let existing = DictionaryCategoryCatalog.normalize(selected).filter {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".sud").path)
                }
                let strings = existing.map { strdup($0) }
                defer { strings.forEach { free($0) } }
                let pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } }
                status = pointers.withUnsafeBufferPointer {
                    sumire_engine_open_with_category_ids(directory.path, $0.baseAddress, $0.count, flags, &engine, &error, error.count)
                }
            } else {
                let legacyMask = categoryIDs.map { DictionaryCategoryCatalog.legacyMask(for: $0, directory: directory) } ?? mask
                status = sumire_engine_open_with_dictionaries(directory.path, legacyMask,
                    flags, &engine, &error, error.count)
            }
            if status == 0, let engine {
                let selected = categoryIDs ?? DictionaryCategoryCatalog.expanded(legacyMask: mask)
                let release = FileManager.default.fileExists(atPath: directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path)
                let unavailable = selected.filter { id in
                    if release { return !FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".sud").path) }
                    guard let category = DictionaryCategoryCatalog.categories.first(where: { $0.id == id }) else { return true }
                    return !DictionaryCategoryCatalog.legacyIDs.contains(id) || !category.legacyFamilies.contains { family in
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent(family + ".sud").path)
                    }
                }
                return OpenedNativeDictionaryEngine(engine: engine, directory: directory, unavailableCategoryIDs: unavailable)
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
