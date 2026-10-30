import Foundation
import SumireCore
#if canImport(SumireCAPI)
import SumireCAPI
#endif

/// A bare bundle/fixture directory has no authority to activate stored overlays.
/// Store-loaded records retain the pointer/manifest provenance needed by the resolver.
struct NativeDictionaryEngineSource {
    let directory: URL
    let generation: DictionaryGenerationStore.Loaded?
    init(directory: URL) { self.directory = directory.standardizedFileURL; generation = nil }
    init(generation: DictionaryGenerationStore.Loaded) {
        directory = generation.directory.standardizedFileURL
        self.generation = generation
    }
}

struct OpenedNativeDictionaryEngine {
    let engine: OpaquePointer
    let directory: URL
    let unavailableCategoryIDs: [String]
}

enum NativeDictionaryEngineOpener {
    /// Opens the first usable immutable generation. A failed native load is
    /// remembered for the process lifetime, then recovery tries the previous
    /// generation and the bundled baseline in order.
    private static func nativeLegacyMask(for ids: [String], directory: URL) -> UInt32 {
        // Core settings use Android/archive family order; the pre-existing C
        // ABI uses category_name(i) order. Translate names at this boundary,
        // preserving both contracts rather than treating their bits as equal.
        let coreMask = DictionaryCategoryCatalog.legacyMask(for: ids, directory: directory)
        let families = Set(DictionaryCategoryCatalog.legacyIDs.enumerated().compactMap {
            coreMask & (UInt32(1) << $0.offset) != 0 ? $0.element : nil
        })
        var nativeMask: UInt32 = 0
        for index in 0..<sumire_category_count() {
            if let name = sumire_category_name(index), families.contains(String(cString: name)) {
                nativeMask |= UInt32(1) << index
            }
        }
        return nativeMask
    }

    static func open(directories: [URL], mask: UInt32, english: Bool, englishReading: Bool,
                     rejecting rejectedDirectories: inout Set<URL>, categoryIDs: [String]? = nil) throws -> OpenedNativeDictionaryEngine {
        try open(sources: directories.map { NativeDictionaryEngineSource(directory: $0) },
                 mask: mask, english: english, englishReading: englishReading,
                 rejecting: &rejectedDirectories, categoryIDs: categoryIDs)
    }

    static func open(sources: [NativeDictionaryEngineSource], mask: UInt32, english: Bool, englishReading: Bool,
                     rejecting rejectedDirectories: inout Set<URL>, categoryIDs: [String]? = nil) throws -> OpenedNativeDictionaryEngine {
        let candidates = sources.filter { !rejectedDirectories.contains($0.directory) }
        guard !candidates.isEmpty else {
            throw NativeDictionaryOpenError(message: "変換辞書が見つかりません。読みは保持しています")
        }
        var lastOpenError: String?
        let selected = categoryIDs ?? DictionaryCategoryCatalog.expanded(legacyMask: mask)
        for source in candidates {
            let directory = source.directory
            var engine: OpaquePointer?
            var error = [CChar](repeating: 0, count: 1024)
            let status: Int32
            let flags: UInt32 = (english ? 1 : 0) | (englishReading ? 2 : 0)
            let markerExists = FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path)
            let unavailable: [String]
            if let generation = source.generation, generation.hasVerifiedReleaseMarker {
                let selection = generation.resolveSourceSelection(for: selected)
                let requests: [(UInt32, String)] = selection.releaseLeafIDs.map {
                    (UInt32(SUMIRE_DICTIONARY_SOURCE_RELEASE_LEAF), $0)
                } + selection.legacyAggregateSources.map {
                    (UInt32(SUMIRE_DICTIONARY_SOURCE_LEGACY_AGGREGATE), $0.id.rawValue)
                }
                let strings = requests.map { strdup($0.1) }
                defer { strings.forEach { free($0) } }
                let records = requests.enumerated().map { index, item in
                    sumire_dictionary_source(kind: item.0,
                        id: strings[index].map { UnsafePointer<CChar>($0) })
                }
                status = records.withUnsafeBufferPointer {
                    sumire_engine_open_with_sources(directory.path, $0.baseAddress, $0.count,
                        flags, &engine, &error, error.count)
                }
                unavailable = selection.unavailableCategoryIDs
            } else if markerExists {
                // A stored generation cannot acquire release authority from an
                // unmanifested marker. Bare bundled/validation directories load
                // only explicit release leaves and never activate typed overlays.
                if source.generation != nil {
                    rejectedDirectories.insert(directory)
                    lastOpenError = "辞書世代の分類マーカーが認証されていません"
                    continue
                }
                let existing = DictionaryCategoryCatalog.normalize(selected).filter {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".sud").path)
                }
                let strings = existing.map { strdup($0) }
                defer { strings.forEach { free($0) } }
                let pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } }
                status = pointers.withUnsafeBufferPointer {
                    sumire_engine_open_with_category_ids(directory.path, $0.baseAddress, $0.count,
                        flags, &engine, &error, error.count)
                }
                unavailable = selected.filter { !existing.contains($0) }
            } else {
                let legacyMask = categoryIDs.map { nativeLegacyMask(for: $0, directory: directory) } ?? mask
                status = sumire_engine_open_with_dictionaries(directory.path, legacyMask,
                    flags, &engine, &error, error.count)
                unavailable = selected.filter { id in
                    guard let category = DictionaryCategoryCatalog.categories.first(where: { $0.id == id }) else { return true }
                    return !DictionaryCategoryCatalog.legacyIDs.contains(id) || !category.legacyFamilies.contains { family in
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent(family + ".sud").path)
                    }
                }
            }
            if status == 0, let engine {
                return OpenedNativeDictionaryEngine(engine: engine, directory: directory,
                    unavailableCategoryIDs: unavailable)
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
