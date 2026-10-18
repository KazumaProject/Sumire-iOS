import Foundation

/// A converted, private staging directory plus an inspectable account of archive
/// entries that were ignored, unsupported, unknown, or incomplete.
public struct DictionarySourceImportReport {
    public let outputDirectory: URL
    public let convertedFiles: [String]
    public let skippedGroups: [String]
    public let diagnostics: [String]
    public let entries: [DictionaryArchivePlan.EntryResult]
}

/// Converts a user-selected Android dictionary ZIP on the containing app side.
/// The destination must be new; it is removed if any recognized complete group
/// fails validation or conversion, so callers never observe partial output.
public enum DictionarySourceArchiveConverter {
    public static func convert(archiveAt archiveURL: URL, into destination: URL) throws -> DictionarySourceImportReport {
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
            try SumireConnectionSourceConverter.write(connection, to: destination.appendingPathComponent("connection.sud"))
            converted.append("connection.sud")
            posTable = table
        } else if let common {
            skipped.insert(common.group.id)
            diagnostics.append("common: \(groupProblem(common))")
            posTable = nil
        } else {
            posTable = nil
        }

        for group in plan.groups where group.group != .common {
            guard group.canValidate else {
                skipped.insert(group.group.id)
                diagnostics.append("\(group.group.id): \(groupProblem(group))")
                continue
            }
            let name: String
            switch group.group {
            case .system: name = "system"
            case .category(let id): name = id
            case .english: name = "english"
            case .englishReading: name = "english_reading"
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

            try SumireDictionarySourceConverter.write(source, to: destination.appendingPathComponent(name + ".sud"))
            converted.append(name + ".sud")
        }

        guard !converted.isEmpty else { throw PersonalDataError("変換できる辞書グループがありません") }
        completed = true
        return DictionarySourceImportReport(outputDirectory: destination, convertedFiles: converted.sorted(),
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
