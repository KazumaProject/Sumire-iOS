import Foundation
import CryptoKit
import Darwin

/// Stores immutable native-dictionary generations behind an atomic pointer.
/// The containing app writes a generation; the keyboard extension can read the
/// current one without mutating the shared container.
public struct DictionaryGenerationStore {
    public struct Loaded {
        public let directory: URL
        public let generation: String
        public let recoveredPrevious: Bool
    }
    private struct Pointer: Codable {
        let formatVersion: Int
        let generation: String
        let manifestSHA256: String
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case generation
            case manifestSHA256 = "manifest_sha256"
        }
    }
    private struct Manifest: Codable {
        let formatVersion: Int
        let generation: String
        let sourceRevision: String
        let importedFiles: [String]
        let outputSHA256: [String: String]
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case generation
            case sourceRevision = "source_revision"
            case importedFiles = "imported_files"
            case outputSHA256 = "output_sha256"
        }
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var currentPointer: URL { directory.appendingPathComponent("current.json") }
    private var previousPointer: URL { directory.appendingPathComponent("previous.json") }
    private static let knownFiles = Set((DictionaryArchivePlan.categoryIDs + [
        "system", "english", "english_reading", "connection", "reading_correction"
    ]).map { $0 + ".sud" })

    /// Reads only pointer/manifest metadata and verifies all referenced files
    /// exist as regular files. Native file checksums are verified by the C++
    /// loader when it maps a selected dictionary.
    public func loadCurrent() -> Loaded? {
        if let loaded = try? load(currentPointer, recoveredPrevious: false) { return loaded }
        return try? load(previousPointer, recoveredPrevious: true)
    }

    /// Returns valid pointer targets in recovery order. The keyboard tries each
    /// immutable generation with the native loader, which verifies every selected
    /// dictionary section before it replaces an existing conversion session.
    public func loadCandidates() -> [Loaded] {
        var candidates: [Loaded] = []
        if let current = try? load(currentPointer, recoveredPrevious: false) {
            candidates.append(current)
        }
        if let previous = try? load(previousPointer, recoveredPrevious: true),
           !candidates.contains(where: { $0.generation == previous.generation }) {
            candidates.append(previous)
        }
        return candidates
    }

    /// Copies a trusted base dictionary set, overlays the validated import
    /// outputs, and changes current.json only after the complete generation and
    /// its manifest have been written and synced.
    @discardableResult
    public func publish(importedFiles: [String: URL], from baseDirectory: URL,
                        validate: ((URL) throws -> Void)? = nil) throws -> Loaded {
        guard directory.isFileURL, baseDirectory.isFileURL,
              importedFiles.keys.allSatisfy(Self.knownFiles.contains) else {
            throw PersonalDataError("辞書世代の保存先または取り込みファイル名が不正です")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PersonalDataError("辞書世代の保存先がフォルダではありません")
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let generation = UUID().uuidString.lowercased()
        let name = "generation-" + generation
        let final = directory.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: final, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? manager.removeItem(at: final) }
        }

        var totalBytes: Int64 = 0
        let importedNames = Set(importedFiles.keys)
        let filesToCopy = Self.knownFiles.sorted().compactMap { file -> (String, URL)? in
            guard !importedNames.contains(file) else { return nil }
            let source = baseDirectory.appendingPathComponent(file)
            return manager.fileExists(atPath: source.path) ? (file, source) : nil
        }
        for (file, source) in filesToCopy {
            try Self.copyRegularFile(source, to: final.appendingPathComponent(file),
                                     totalBytes: &totalBytes)
        }
        for (file, source) in importedFiles.sorted(by: { $0.key < $1.key }) {
            let destination = final.appendingPathComponent(file)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try Self.copyRegularFile(source, to: destination, totalBytes: &totalBytes)
        }

        guard manager.fileExists(atPath: final.appendingPathComponent("system.sud").path),
              manager.fileExists(atPath: final.appendingPathComponent("connection.sud").path) else {
            throw PersonalDataError("基準辞書にシステム辞書または接続辞書がありません")
        }

        var hashes: [String: String] = [:]
        for file in Self.knownFiles.sorted() {
            let url = final.appendingPathComponent(file)
            guard manager.fileExists(atPath: url.path) else { continue }
            hashes[file] = try Self.sha256(of: url)
            try Self.synchronize(url)
        }
        let manifest = Manifest(formatVersion: 1, generation: generation,
                                sourceRevision: "unknown-or-mixed",
                                importedFiles: importedFiles.keys.sorted(), outputSHA256: hashes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: final.appendingPathComponent("manifest.json"), options: .atomic)
        try Self.synchronize(final.appendingPathComponent("manifest.json"))
        try? Self.synchronize(final)
        // Validate the complete immutable generation before publishing its pointer.
        // A native-loader failure leaves the existing current generation untouched.
        try validate?(final)
        let pointer = Pointer(formatVersion: 1, generation: name,
                              manifestSHA256: Self.digest(manifestData))
        let pointerData = try encoder.encode(pointer)

        let previous = (try? readPointer(currentPointer)) ?? (try? readPointer(previousPointer))
        if let previous {
            try encoder.encode(previous).write(to: previousPointer, options: .atomic)
            try Self.synchronize(previousPointer)
        }
        try pointerData.write(to: currentPointer, options: .atomic)
        published = true
        try? Self.synchronize(currentPointer)
        try? Self.synchronize(directory)

        Self.removeUnreferencedGenerations(in: directory, keeping: [name, previous?.generation].compactMap { $0 })
        return Loaded(directory: final, generation: name, recoveredPrevious: false)
    }

    private func load(_ pointerURL: URL, recoveredPrevious: Bool) throws -> Loaded {
        let pointer = try readPointer(pointerURL)
        let target = directory.appendingPathComponent(pointer.generation, isDirectory: true)
        return Loaded(directory: target, generation: pointer.generation, recoveredPrevious: recoveredPrevious)
    }

    private func readPointer(_ url: URL) throws -> Pointer {
        let manager = FileManager.default
        let pointerAttributes = try manager.attributesOfItem(atPath: url.path)
        guard pointerAttributes[.type] as? FileAttributeType == .typeRegular,
              let pointerSize = pointerAttributes[.size] as? NSNumber, pointerSize.intValue <= 4096 else {
            throw PersonalDataError("辞書世代のポインタが不正です")
        }
        let pointer = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: url))
        guard pointer.formatVersion == 1,
              let id = UUID(uuidString: String(pointer.generation.dropFirst("generation-".count))),
              pointer.generation == "generation-" + id.uuidString.lowercased(),
              Self.isSHA256(pointer.manifestSHA256) else {
            throw PersonalDataError("辞書世代のポインタ形式が未対応です")
        }
        let target = directory.appendingPathComponent(pointer.generation, isDirectory: true)
        let targetAttributes = try manager.attributesOfItem(atPath: target.path)
        guard targetAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw PersonalDataError("辞書世代フォルダがありません")
        }
        let manifestURL = target.appendingPathComponent("manifest.json")
        let manifestAttributes = try manager.attributesOfItem(atPath: manifestURL.path)
        guard manifestAttributes[.type] as? FileAttributeType == .typeRegular,
              let manifestSize = manifestAttributes[.size] as? NSNumber, manifestSize.intValue <= 1_048_576 else {
            throw PersonalDataError("辞書世代マニフェストが大きすぎます")
        }
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard Self.digest(manifestData) == pointer.manifestSHA256 else {
            throw PersonalDataError("辞書世代マニフェストのチェックサムが一致しません")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion == 1, manifest.generation == String(pointer.generation.dropFirst("generation-".count)),
              manifest.outputSHA256.keys.allSatisfy(Self.knownFiles.contains),
              manifest.outputSHA256.values.allSatisfy(Self.isSHA256),
              manifest.importedFiles.allSatisfy(Self.knownFiles.contains),
              manifest.outputSHA256["system.sud"] != nil, manifest.outputSHA256["connection.sud"] != nil else {
            throw PersonalDataError("辞書世代マニフェストの形式が不正です")
        }
        for file in manifest.outputSHA256.keys {
            let attributes = try manager.attributesOfItem(atPath: target.appendingPathComponent(file).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PersonalDataError("辞書世代ファイルがありません: \(file)")
            }
        }
        return pointer
    }

    private static func copyRegularFile(_ source: URL, to destination: URL,
                                        totalBytes: inout Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= 1_073_741_824 else {
            throw PersonalDataError("辞書世代の入力ファイルが通常ファイルでないか大きすぎます")
        }
        let (sum, overflow) = totalBytes.addingReportingOverflow(size.int64Value)
        guard !overflow, sum <= 2_147_483_648 else { throw PersonalDataError("辞書世代の合計容量が上限を超えています") }
        try FileManager.default.copyItem(at: source, to: destination)
        totalBytes = sum
    }

    private static func removeUnreferencedGenerations(in root: URL, keeping names: [String]) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                                                                          includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let keep = Set(names)
        for child in children where child.lastPathComponent.hasPrefix("generation-") && !keep.contains(child.lastPathComponent) {
            guard let isDirectory = try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        digest(try Data(contentsOf: url, options: .mappedIfSafe))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }
    private static func synchronize(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        let descriptor = open(url.path, isDirectory ? O_RDONLY : O_RDWR)
        guard descriptor >= 0 else { throw PersonalDataError("辞書世代の同期対象を開けません") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PersonalDataError("辞書世代をディスクへ同期できません") }
    }
}
