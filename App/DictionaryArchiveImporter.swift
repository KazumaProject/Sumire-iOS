import Foundation
import SumireCore

struct DictionaryImportOutcome: Identifiable, Sendable {
    let id = UUID()
    let succeeded: Bool
    let message: String
    let convertedFiles: [String]
    let storedLegacyAggregateIDs: [String]
    let preservedUnclassifiedCategoryIDs: [String]
    let skippedGroups: [String]
    let diagnostics: [String]

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, message: message, convertedFiles: [], storedLegacyAggregateIDs: [],
             preservedUnclassifiedCategoryIDs: [], skippedGroups: [], diagnostics: [])
    }
}

struct DictionaryArchiveImportConversion: Sendable {
    let outputDirectory: URL
    let importedFiles: [String: URL]
    let legacyAggregateOverlays: [DictionaryCategoryCatalog.LegacyAggregateID: URL]
    let convertedFiles: [String]
    let skippedGroups: [String]
    let diagnostics: [String]

    init(outputDirectory: URL,
         importedFiles: [String: URL],
         legacyAggregateOverlays: [DictionaryCategoryCatalog.LegacyAggregateID: URL],
         convertedFiles: [String],
         skippedGroups: [String] = [],
         diagnostics: [String] = []) {
        self.outputDirectory = outputDirectory
        self.importedFiles = importedFiles
        self.legacyAggregateOverlays = legacyAggregateOverlays
        self.convertedFiles = convertedFiles
        self.skippedGroups = skippedGroups
        self.diagnostics = diagnostics
    }

    init(report: DictionarySourceImportReport) {
        self.init(outputDirectory: report.outputDirectory,
                  importedFiles: report.importedFiles,
                  legacyAggregateOverlays: report.legacyAggregateOverlays,
                  convertedFiles: report.convertedFiles,
                  skippedGroups: report.skippedGroups,
                  diagnostics: report.diagnostics)
    }
}

/// Coordinates conversion, native validation, and atomic generation publication.
/// The converter and validator seams keep this app-level transaction testable without
/// requiring a signed App Group or changing the keyboard's offline runtime path.
enum DictionaryArchiveImporter {
    typealias Converter = (URL, URL, DictionarySourceArchiveConverter.CategoryInterpretation) throws
        -> DictionaryArchiveImportConversion
    typealias Validator = (URL) throws -> Void

    static func perform(
        archive: URL,
        sharedContainer: URL,
        categoryInterpretation: DictionarySourceArchiveConverter.CategoryInterpretation,
        storeImportMode: DictionaryGenerationStore.ImportMode,
        bundledSupport: URL?,
        converter: Converter? = nil,
        validator: Validator? = nil
    ) -> DictionaryImportOutcome {
        let store = DictionaryGenerationStore(
            directory: sharedContainer.appendingPathComponent("Sumire/Dictionaries", isDirectory: true))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sumire-dictionary-source-\(UUID().uuidString)", isDirectory: true)
        let convert = converter ?? { source, destination, interpretation in
            let report = try DictionarySourceArchiveConverter.convert(
                archiveAt: source, into: destination, categoryInterpretation: interpretation)
            return DictionaryArchiveImportConversion(report: report)
        }
        let validate = validator ?? Self.validateNativeDictionaries

        do {
            let report = try convert(archive, staging, categoryInterpretation)
            defer { try? FileManager.default.removeItem(at: report.outputDirectory) }

            guard let bundledSupport else {
                throw ImportError(message: "取り込みに必要な同梱の補助辞書が見つかりません")
            }
            var base: URL?
            let loadedCandidates = store.loadCandidates()
            let storedCandidates = loadedCandidates.map(\.directory)
            // Release leaves require the release taxonomy. Typed legacy overlays
            // are stored in a separate namespace. Verified release generations
            // may use them only when every leaf of their family is selected.
            let releaseCandidates = loadedCandidates
                .filter(\.hasVerifiedReleaseMarker)
                .map(\.directory)
            let hasReleaseCategoryImports = report.importedFiles.keys.contains { file in
                guard file.hasSuffix(".sud") else { return false }
                return DictionaryCategoryCatalog.idSet.contains(String(file.dropLast(4)))
            }
            let needsReleaseBase = categoryInterpretation == .releaseLeaf && hasReleaseCategoryImports
            let baseCandidates = needsReleaseBase ? releaseCandidates + [bundledSupport] : storedCandidates + [bundledSupport]
            for candidate in baseCandidates {
                do {
                    try validate(candidate)
                    base = candidate
                    break
                } catch { continue }
            }
            guard let base else {
                throw ImportError(message: "変換の基準となる辞書が見つかりません")
            }
            let loaded = try store.publish(
                importedFiles: report.importedFiles,
                from: base,
                supportFallback: bundledSupport,
                legacyAggregateOverlays: report.legacyAggregateOverlays,
                importMode: storeImportMode
            ) { directory in try validate(directory) }
            guard let current = store.loadCurrent(), current.generation == loaded.generation else {
                throw ImportError(message: "公開した辞書世代を再読込できませんでした")
            }
            let importedReleaseLeafIDs = report.importedFiles.keys.compactMap { file -> String? in
                guard file.hasSuffix(".sud") else { return nil }
                let id = String(file.dropLast(4))
                return DictionaryCategoryCatalog.idSet.contains(id) ? id : nil
            }
            if !importedReleaseLeafIDs.isEmpty {
                let selection = current.resolveSourceSelection(for: importedReleaseLeafIDs, allowingLegacyAggregates: false)
                guard current.hasVerifiedReleaseMarker,
                      Set(selection.releaseLeafIDs).isSuperset(of: importedReleaseLeafIDs),
                      selection.unavailableCategoryIDs.isEmpty else {
                    throw ImportError(message: "公開した分類辞書を世代から検証できませんでした")
                }
            }
            let incomingOverlayIDs = Set(report.legacyAggregateOverlays.keys)
            let persistedOverlayIDs = Set(current.legacyAggregateOverlayIDs)
            guard incomingOverlayIDs.isSubset(of: persistedOverlayIDs) else {
                throw ImportError(message: "旧分類集約辞書を世代へ保存できませんでした")
            }
            let message: String
            if incomingOverlayIDs.isEmpty {
                if loaded.preservedUnclassifiedCategoryIDs.isEmpty {
                    message = "検証済みの辞書世代を有効化しました（\(loaded.generation)）。"
                } else {
                    message = "新分類の辞書世代を有効化しました（\(loaded.generation)）。分類未判定の既存辞書は別領域に保持し、変換には使っていません。"
                }
            } else if current.hasCurrentVerifiedReleaseProvenance {
                message = "辞書世代を保存しました（\(loaded.generation)）。旧分類集約辞書は、対応する新分類をすべて選択した場合に変換に使います。一部だけ選択した場合は新分類の辞書を使います。"
            } else {
                message = "辞書世代を保存しました（\(loaded.generation)）。旧分類集約辞書は型付きで保存しましたが、この世代は新分類の認証がないため変換には使われません。"
            }
            return DictionaryImportOutcome(
                succeeded: true,
                message: message,
                convertedFiles: report.importedFiles.keys.sorted(),
                storedLegacyAggregateIDs: report.legacyAggregateOverlays.keys.map(\.rawValue).sorted(),
                preservedUnclassifiedCategoryIDs: loaded.preservedUnclassifiedCategoryIDs,
                skippedGroups: report.skippedGroups,
                diagnostics: report.diagnostics)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func validateNativeDictionaries(at directory: URL) throws {
        let hasEnglish = FileManager.default.fileExists(atPath: directory.appendingPathComponent("english.sud").path)
        let hasEnglishReading = FileManager.default.fileExists(atPath: directory.appendingPathComponent("english_reading.sud").path)
        let categoryIDs = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker).path)
            ? DictionaryCategoryCatalog.ids
            : nil
        var rejected = Set<URL>()
        let opened = try NativeDictionaryEngineOpener.open(directories: [directory], mask: 0x3fff_ffff,
            english: hasEnglish, englishReading: hasEnglishReading, rejecting: &rejected,
            categoryIDs: categoryIDs)
        sumire_engine_close(opened.engine)
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
