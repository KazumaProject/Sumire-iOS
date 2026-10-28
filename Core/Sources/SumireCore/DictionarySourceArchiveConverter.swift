import Foundation

/// A converted, private staging directory plus an inspectable account of archive
/// entries that were ignored, unsupported, unknown, or incomplete.
public struct DictionarySourceImportReport {
    public let outputDirectory: URL
    /// Flat, release-taxonomy-compatible files suitable for `DictionaryGenerationStore.publish`.
    public let importedFiles: [String: URL]
    /// Old category-family dictionaries kept separate from same-named release leaves.
    public let legacyAggregateOverlays: [DictionaryCategoryCatalog.LegacyAggregateID: URL]
    /// Relative paths for every converted file inside `outputDirectory`.
    public let convertedFiles: [String]
    public let skippedGroups: [String]
    public let diagnostics: [String]
    public let entries: [DictionaryArchivePlan.EntryResult]
}

/// Converts a user-selected Android dictionary ZIP on the containing app side.
/// The destination must be new; it is removed if any recognized complete group
/// fails validation or conversion, so callers never observe partial output.
public enum DictionarySourceArchiveConverter {
    public enum CategoryInterpretation: Equatable, Sendable {
        /// Preserve the existing release-leaf import behavior.
        case releaseLeaf
        /// Treat exact pinned legacy family IDs as typed aggregate overlays.
        /// Release-only category paths are rejected rather than guessed from a raw name.
        case legacyAggregate
    }

    public static func convert(archiveAt archiveURL: URL, into destination: URL,
                               categoryInterpretation: CategoryInterpretation = .releaseLeaf) throws -> DictionarySourceImportReport {
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw PersonalDataError("辞書の一時保存先は新規のローカルフォルダにしてください")
        }

        let archive = try DictionaryZipArchive(url: archiveURL)
        let plan = try DictionaryArchivePlan(entryNames: archive.entries.map(\.name))
        if let unsafe = plan.entryResults.first(where: {
            if case .unsafe = $0.resolution { return true }
            return false
        }) {
            throw PersonalDataError("辞書ZIPのパスが安全ではありません: \(unsafe.entryName)")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let sourceTemporaryDirectory = destination.appendingPathComponent(".source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceTemporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sourceTemporaryDirectory) }

        let archiveEntries = Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.name, $0) })
        var diagnostics = plan.entryResults.compactMap { result -> String? in
            switch result.resolution {
            case .unsupported(let reason): return "\(result.entryName): \(reason)"
            case .unknown(let reason): return "\(result.entryName): \(reason)"
            case .ignored: return "\(result.entryName): macOS付加情報などのため無視"
            case .mapped, .unsafe: return nil
            }
        }
        var skipped = Set<String>()
        var converted: [String] = []
        var importedFiles: [String: URL] = [:]
        var legacyAggregateOverlays: [DictionaryCategoryCatalog.LegacyAggregateID: URL] = [:]

        let common = plan.groups.first { $0.group == .common }
        let posTable: [DictionaryPrimitiveArray]?
        if let common, common.canValidate {
            let entries = Dictionary(uniqueKeysWithValues: common.entries.map { ($0.key.role, $0) })
            let tableEntry = try required(.posTable, from: entries)
            let matrixEntry = try required(.connection, from: entries)
            let table = try readArrays(tableEntry, from: archive, indexedBy: archiveEntries,
                                       temporaryDirectory: sourceTemporaryDirectory, kinds: [.shorts, .shorts],
                                       diagnostics: &diagnostics)
            let matrix = try readPayload(matrixEntry, from: archive, indexedBy: archiveEntries,
                                         temporaryDirectory: sourceTemporaryDirectory, diagnostics: &diagnostics)
            let connection = try ConnectionSourceValidation.validate(posTable: table, matrix: matrix)
            let output = destination.appendingPathComponent("connection.sud")
            try SumireConnectionSourceConverter.write(connection, to: output)
            converted.append("connection.sud")
            importedFiles["connection.sud"] = output
            posTable = table
        } else if let common {
            skipped.insert(common.group.id)
            diagnostics.append("common: \(groupProblem(common))")
            posTable = nil
        } else {
            posTable = nil
        }

        for group in plan.groups where group.group != .common {
            if case .category(let id) = group.group,
               categoryInterpretation == .legacyAggregate,
               !DictionaryCategoryCatalog.legacyIDs.contains(id) {
                throw PersonalDataError("旧分類辞書の集約IDとして扱えない分類パスです: \(id)")
            }
            guard group.canValidate else {
                skipped.insert(group.group.id)
                diagnostics.append("\(group.group.id): \(groupProblem(group))")
                continue
            }
            let name: String
            switch group.group {
            case .system: name = "system"
            case .category(let id): name = id
            case .auxiliary(let id): name = id
            case .english: name = "english"
            case .englishReading: name = "english_reading"
            case .readingCorrection: name = "reading_correction"
            case .common: continue
            }
            let entries = Dictionary(uniqueKeysWithValues: group.entries.map { ($0.key.role, $0) })

            let source: ValidatedDictionarySource
            if group.group == .english {
                let reading = try readArrays(required(.reading, from: entries), from: archive,
                                             indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                             kinds: [.longs, .longs, .characters, .ints], diagnostics: &diagnostics)
                let surface = try readArrays(required(.word, from: entries), from: archive,
                                             indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                             kinds: [.longs, .longs, .characters], diagnostics: &diagnostics)
                let tokens = try readArrays(required(.token, from: entries), from: archive,
                                            indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                            kinds: [.shorts, .ints, .longs], diagnostics: &diagnostics)
                source = try DictionarySourceValidation.validate(reading: reading, surface: surface, tokens: tokens,
                                                                 isEnglish: true, posTableCount: 0)
            } else {
                guard let posTable else {
                    skipped.insert(group.group.id)
                    diagnostics.append("\(group.group.id): 共通POS表・接続行列がないため安全に変換できません")
                    continue
                }
                let reading = try readArrays(required(.yomi, from: entries), from: archive,
                                             indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                             kinds: [.longs, .longs, .characters, .ints], diagnostics: &diagnostics)
                let surface = try readArrays(required(.tango, from: entries), from: archive,
                                             indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                             kinds: [.longs, .longs, .characters], diagnostics: &diagnostics)
                let tokens = try readArrays(required(.token, from: entries), from: archive,
                                            indexedBy: archiveEntries, temporaryDirectory: sourceTemporaryDirectory,
                                            kinds: [.shorts, .shorts, .ints, .longs], diagnostics: &diagnostics)
                source = try DictionarySourceValidation.validate(reading: reading, surface: surface, tokens: tokens,
                                                                 posTableCount: posTable[0].count)
            }

            let legacyAggregateID: DictionaryCategoryCatalog.LegacyAggregateID?
            if case .category(let id) = group.group,
               categoryInterpretation == .legacyAggregate {
                legacyAggregateID = DictionaryCategoryCatalog.LegacyAggregateID(rawValue: id)
            } else {
                legacyAggregateID = nil
            }
            let relativeOutputPath = legacyAggregateID.map { "legacy_aggregates/\($0.rawValue).sud" } ?? (name + ".sud")
            let output = destination.appendingPathComponent(relativeOutputPath)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SumireDictionarySourceConverter.write(source, to: output)
            converted.append(relativeOutputPath)
            if let legacyAggregateID {
                legacyAggregateOverlays[legacyAggregateID] = output
            } else {
                importedFiles[relativeOutputPath] = output
            }
        }

        guard !converted.isEmpty else { throw PersonalDataError("変換できる辞書グループがありません") }
        completed = true
        return DictionarySourceImportReport(outputDirectory: destination,
                                            importedFiles: importedFiles,
                                            legacyAggregateOverlays: legacyAggregateOverlays,
                                            convertedFiles: converted.sorted(),
                                            skippedGroups: skipped.sorted(), diagnostics: diagnostics,
                                            entries: plan.entryResults)
    }

    private static func required(_ role: DictionaryArchivePlan.Role,
                                 from entries: [DictionaryArchivePlan.Role: DictionaryArchivePlan.MappedEntry]) throws -> DictionaryArchivePlan.MappedEntry {
        guard let entry = entries[role] else { throw PersonalDataError("辞書ZIPの必須項目がありません: \(role.rawValue)") }
        return entry
    }

    private static func groupProblem(_ group: DictionaryArchivePlan.GroupPlan) -> String {
        var parts: [String] = []
        if !group.missingRoles.isEmpty {
            parts.append("不足項目 " + group.missingRoles.map(\.rawValue).joined(separator: ", "))
        }
        for duplicate in group.duplicates {
            parts.append("\(duplicate.key.role.rawValue)の重複 (\(duplicate.entryNames.joined(separator: ", ")))")
        }
        return parts.isEmpty ? "ZIP内で同じ役割の項目が重複しています" : parts.joined(separator: "; ")
    }

    private static func readArrays(_ mapped: DictionaryArchivePlan.MappedEntry, from archive: DictionaryZipArchive,
                                   indexedBy entries: [String: DictionaryZipArchive.Entry], temporaryDirectory: URL,
                                   kinds: [DictionaryPrimitiveKind], diagnostics: inout [String]) throws -> [DictionaryPrimitiveArray] {
        try DictionaryJavaArrays.read(readPayload(mapped, from: archive, indexedBy: entries,
                                                  temporaryDirectory: temporaryDirectory,
                                                  diagnostics: &diagnostics), kinds: kinds)
    }

    private static func readPayload(_ mapped: DictionaryArchivePlan.MappedEntry, from archive: DictionaryZipArchive,
                                    indexedBy entries: [String: DictionaryZipArchive.Entry], temporaryDirectory: URL,
                                    diagnostics: inout [String]) throws -> Data {
        guard let entry = entries[mapped.entryName] else { throw PersonalDataError("辞書ZIP項目が見つかりません: \(mapped.entryName)") }
        let outerURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outerURL) }
        try archive.extract(entry, to: outerURL)
        guard mapped.container == .nestedZIP else {
            return try Data(contentsOf: outerURL, options: .mappedIfSafe)
        }

        let nested = try DictionaryZipArchive(url: outerURL)
        diagnostics.append(contentsOf: nested.entries.filter { $0.isDirectory || isMetadata($0.name) }
            .map { "\(mapped.entryName)!/\($0.name): macOS付加情報またはディレクトリのため無視" })
        let payloads = nested.entries.filter { !$0.isDirectory && !isMetadata($0.name) }
        guard payloads.count == 1, let payload = payloads.first else {
            throw PersonalDataError("内側の辞書ZIPにはデータ項目が1件必要です: \(mapped.entryName)")
        }
        let payloadURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        try nested.extract(payload, to: payloadURL)
        return try Data(contentsOf: payloadURL, options: .mappedIfSafe)
    }

    private static func isMetadata(_ name: String) -> Bool {
        let parts = name.split(separator: "/").map { $0.lowercased() }
        guard let basename = parts.last else { return false }
        return parts.contains("__macosx") || basename == ".ds_store" || basename.hasPrefix("._")
    }
}
