import Foundation
import CryptoKit
import Darwin

/// Stores immutable native-dictionary generations behind an atomic pointer.
/// The containing app writes a generation; the keyboard extension can read the
/// current one without mutating the shared container.
public struct DictionaryGenerationStore {
    public enum ImportMode: Equatable, Sendable {
        /// Compatibility for existing callers that publish pre-classified files.
        case legacyCompatible
        /// Files were interpreted as release-leaf IDs by the archive converter.
        case releaseLeaf
        /// Old family dictionaries are stored only under their typed overlay IDs.
        case typedLegacyAggregate
    }

    public struct Loaded {
        public struct LegacyAggregateSource: Equatable, Sendable {
            public let id: DictionaryCategoryCatalog.LegacyAggregateID
            public let fileURL: URL
        }

        /// Typed source request consumed by the native opener. It identifies
        /// release leaves and aggregate files separately; selection itself does
        /// not load or convert either source.
        public struct SourceSelection: Equatable, Sendable {
            public let releaseLeafIDs: [String]
            public let legacyAggregateSources: [LegacyAggregateSource]
            public let unavailableCategoryIDs: [String]
        }

        public let directory: URL
        public let generation: String
        public let recoveredPrevious: Bool
        /// True only when the release marker is a checksum-matched manifest member.
        public let hasVerifiedReleaseMarker: Bool
        /// Old aggregate dictionaries retained beside a dictionary generation.
        /// The native opener uses them only through the complete-family resolver.
        public let legacyAggregateOverlayIDs: [DictionaryCategoryCatalog.LegacyAggregateID]
        fileprivate let legacyAggregateOverlaySHA256: [DictionaryCategoryCatalog.LegacyAggregateID: String]
        fileprivate let releaseLeafSHA256: [String: String]
        /// Category-named files carried forward from an unmarked generation.
        /// Their taxonomy is not inferable from the old manifest, so they remain
        /// preserved but inactive until explicitly re-imported with known provenance.
        public let preservedUnclassifiedCategoryIDs: [String]
        /// Flat category files inferred from a pre-marker generation. These remain
        /// in their original location until a release-taxonomy transition quarantines them.
        public let unclassifiedLegacyRootCategoryIDs: [String]
        fileprivate let unclassifiedCategorySources: [String: URL]

        /// Resolves selected taxonomy IDs against this already-verified immutable
        /// generation. Only a release-marked generation can supply release leaves
        /// or typed aggregate overlays; ambiguous pre-marker files remain inactive.
        public func resolveSourceSelection(for selectedIDs: [String], allowingLegacyAggregates: Bool = true) -> SourceSelection {
            let requested = DictionaryCategoryCatalog.normalize(selectedIDs)
            let requestedSet = Set(requested)
            let knownCategoryIDs = Set(DictionaryCategoryCatalog.ids)
            let unknownIDs = Set(selectedIDs).subtracting(knownCategoryIDs).sorted()
            let allRequestedIDs = requested + unknownIDs
            guard hasVerifiedReleaseMarker else {
                return SourceSelection(releaseLeafIDs: [], legacyAggregateSources: [],
                                      unavailableCategoryIDs: allRequestedIDs)
            }

            func isRegularFile(_ url: URL) -> Bool {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return false
                }
                return attributes[.type] as? FileAttributeType == .typeRegular
            }

            let selectedFamilies = Set(DictionaryCategoryCatalog.categories
                .filter { requestedSet.contains($0.id) }
                .flatMap(\.legacyFamilies))
            // Import validation checks the newly published leaf bytes, independently
            // of the optional aggregate-substitution plan used by the native opener.
            let eligibleOverlayIDs = allowingLegacyAggregates ? legacyAggregateOverlayIDs : []
            let completeFamilyCandidates = eligibleOverlayIDs.filter { id in
                guard selectedFamilies.contains(id.rawValue) else { return false }
                let familyLeaves = DictionaryCategoryCatalog.categories
                    .filter { $0.legacyFamilies.contains(id.rawValue) }
                return !familyLeaves.isEmpty && familyLeaves.allSatisfy { requestedSet.contains($0.id) }
            }
            // Recheck only overlays that could participate in this selection. Generations
            // are immutable after publication, but this prevents a replaced file from being
            // planned for the native consumer after the pointer was loaded.
            let availableAggregates = Set(completeFamilyCandidates.filter { id in
                let url = directory.appendingPathComponent("legacy_aggregates/\(id.rawValue).sud")
                guard isRegularFile(url),
                      let expected = legacyAggregateOverlaySHA256[id],
                      let actual = try? DictionaryGenerationStore.sha256(of: url) else {
                    return false
                }
                return actual == expected
            })
            let resolved = DictionaryCategoryCatalog.resolveLegacyOverlaySelection(
                selectedIDs: requested,
                availableLegacyAggregateIDs: availableAggregates
            )
            let aggregateSources = resolved.legacyAggregateIDs.compactMap { id -> LegacyAggregateSource? in
                guard availableAggregates.contains(id) else { return nil }
                return LegacyAggregateSource(
                    id: id,
                    fileURL: directory.appendingPathComponent("legacy_aggregates/\(id.rawValue).sud")
                )
            }
            let aggregateIDs = Set(aggregateSources.map(\.id))
            let aggregateCoveredLeafIDs = Set(DictionaryCategoryCatalog.categories.compactMap { category -> String? in
                guard !category.legacyFamilies.isEmpty,
                      Set(category.legacyFamilies).isSubset(of: aggregateIDs.map(\.rawValue)) else {
                    return nil
                }
                return category.id
            })
            let releaseLeafIDs = resolved.releaseLeafIDs.filter { id in
                let url = directory.appendingPathComponent(id + ".sud")
                guard isRegularFile(url),
                      let expected = releaseLeafSHA256[id + ".sud"],
                      let actual = try? DictionaryGenerationStore.sha256(of: url) else {
                    return false
                }
                return actual == expected
            }
            let covered = Set(releaseLeafIDs).union(aggregateCoveredLeafIDs)
            let unavailable = requested.filter { !covered.contains($0) } + unknownIDs
            return SourceSelection(releaseLeafIDs: releaseLeafIDs,
                                   legacyAggregateSources: aggregateSources,
                                   unavailableCategoryIDs: unavailable)
        }
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
    private struct VerifiedPointer {
        let pointer: Pointer
        let hasVerifiedReleaseMarker: Bool
        let legacyAggregateOverlayIDs: [DictionaryCategoryCatalog.LegacyAggregateID]
        let legacyAggregateOverlaySHA256: [DictionaryCategoryCatalog.LegacyAggregateID: String]
        let releaseLeafSHA256: [String: String]
        let preservedUnclassifiedCategoryIDs: [String]
        let unclassifiedLegacyRootCategoryIDs: [String]
        let unclassifiedCategorySources: [String: URL]
    }
    private struct Manifest: Codable {
        let formatVersion: Int
        let generation: String
        let sourceRevision: String
        let importedFiles: [String]
        let outputSHA256: [String: String]
        let legacyAggregateOverlayIDs: [String]?
        let preservedUnclassifiedCategoryIDs: [String]?
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case generation
            case sourceRevision = "source_revision"
            case importedFiles = "imported_files"
            case outputSHA256 = "output_sha256"
            case legacyAggregateOverlayIDs = "legacy_aggregate_overlay_ids"
            case preservedUnclassifiedCategoryIDs = "preserved_unclassified_category_ids"
        }
        init(formatVersion: Int, generation: String, sourceRevision: String,
             importedFiles: [String], outputSHA256: [String: String],
             legacyAggregateOverlayIDs: [String], preservedUnclassifiedCategoryIDs: [String]) {
            self.formatVersion = formatVersion
            self.generation = generation
            self.sourceRevision = sourceRevision
            self.importedFiles = importedFiles
            self.outputSHA256 = outputSHA256
            self.legacyAggregateOverlayIDs = legacyAggregateOverlayIDs
            self.preservedUnclassifiedCategoryIDs = preservedUnclassifiedCategoryIDs
        }
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var currentPointer: URL { directory.appendingPathComponent("current.json") }
    private var previousPointer: URL { directory.appendingPathComponent("previous.json") }
    private static let releaseReplacementFiles = Set((DictionaryCategoryCatalog.ids + [
        "system", "english", "english_reading", "connection", "reading_correction",
        "single_kanji", "emoji", "emoticon", "symbol"
    ]).map { $0 + ".sud" })
    private static let releaseCategoryFiles = Set(DictionaryCategoryCatalog.ids.map { $0 + ".sud" })
    // Older, unmarked generations can still receive legacy family filenames.
    private static let replacementFiles = Set((DictionaryArchivePlan.categoryIDs + DictionaryCategoryCatalog.ids + [
        "system", "english", "english_reading", "connection", "reading_correction",
        "single_kanji", "emoji", "emoticon", "symbol"
    ]).map { $0 + ".sud" })
    // Support assets survive publication independently of archive replacements.
    private static let supportGroups = [
        ["standalone.sud"], ["reading_correction.sud"],
        ["system_ngram.dat", "system_ngram_unigram.dat"],
        ["mozc/segmenter.dat", "mozc/node_attribute_by_lid.dat"],
        ["single_kanji.sud", "emoji.sud", "emoticon.sud", "symbol.sud"]
    ]
    private static let supportFiles = Set(supportGroups.flatMap { $0 }).union([DictionaryCategoryCatalog.releaseMarker])
    private static let legacyAggregateDirectory = "legacy_aggregates"
    private static let unclassifiedCategoryDirectory = "unclassified_categories"
    private static let legacyAggregateIDs = Set(DictionaryCategoryCatalog.legacyIDs.map {
        DictionaryCategoryCatalog.LegacyAggregateID(rawValue: $0)
    })
    private static let legacyAggregateRootFiles = Set(DictionaryCategoryCatalog.legacyIDs.map { $0 + ".sud" })
    private static func legacyAggregateFile(_ id: DictionaryCategoryCatalog.LegacyAggregateID) -> String {
        "\(legacyAggregateDirectory)/\(id.rawValue).sud"
    }
    private static func unclassifiedCategoryFile(_ id: String) -> String {
        "\(unclassifiedCategoryDirectory)/\(id).sud"
    }
    private static let knownFiles = replacementFiles.union(supportFiles).union(
        Set(DictionaryCategoryCatalog.legacyIDs.map {
            "\(legacyAggregateDirectory)/\($0).sud"
        })
    ).union(Set(DictionaryCategoryCatalog.legacyIDs.map {
        "\(unclassifiedCategoryDirectory)/\($0).sud"
    }))

    /// Verifies pointer/manifest metadata and referenced regular files. The C++
    /// loader verifies selected native dictionaries. Verify typed overlays'
    /// recorded hashes here before the opener can select them.
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
    /// its manifest have been written and synced. Missing support groups can be
    /// restored from the trusted bundled fallback without replacing base user
    /// dictionaries. Partial groups are rejected rather than mixed silently.
    /// On a marked release generation, `importedFiles` names are release output IDs.
    /// Legacy family aggregates must be supplied separately with typed IDs. Overlapping
    /// raw names are therefore valid release IDs here, never an aggregate identity.
    /// Typed overlays can be stored beside either generation taxonomy, but only
    /// verified release generations may select them for the native opener. Callers importing
    /// converter output must pass its interpretation so release leaves cannot overwrite
    /// an unmarked legacy generation merely because their filenames overlap.
    @discardableResult
    public func publish(importedFiles: [String: URL], from baseDirectory: URL, supportFallback: URL? = nil,
                        legacyAggregateOverlays: [DictionaryCategoryCatalog.LegacyAggregateID: URL] = [:],
                        importMode: ImportMode = .legacyCompatible,
                        validate: ((URL) throws -> Void)? = nil) throws -> Loaded {
        guard directory.isFileURL, baseDirectory.isFileURL,
              importedFiles.keys.allSatisfy(Self.replacementFiles.contains) else {
            throw PersonalDataError("辞書世代の保存先または取り込みファイル名が不正です")
        }
        let manager = FileManager.default
        try Self.requireDirectory(baseDirectory)
        let existingGenerations = loadCandidates()
        let storedBaseGeneration = existingGenerations.first {
            $0.directory.standardizedFileURL == baseDirectory.standardizedFileURL
        }
        let isBundledBootstrap = storedBaseGeneration == nil &&
            supportFallback?.standardizedFileURL == baseDirectory.standardizedFileURL
        let releaseMarkerSource = try Self.existingFile(DictionaryCategoryCatalog.releaseMarker, in: baseDirectory)
        let hasVerifiedReleaseMarker = storedBaseGeneration?.hasVerifiedReleaseMarker == true
        let hasTrustedReleaseMarker = hasVerifiedReleaseMarker || (isBundledBootstrap && releaseMarkerSource != nil)
        let importsReleaseCategories = importedFiles.keys.contains {
            Self.releaseCategoryFiles.contains($0)
        }
        let incomingOverlayIDs = Set(legacyAggregateOverlays.keys)
        guard incomingOverlayIDs.isSubset(of: Self.legacyAggregateIDs) else {
            throw PersonalDataError("旧分類辞書の集約IDが分類カタログにありません")
        }
        switch importMode {
        case .legacyCompatible:
            break
        case .releaseLeaf:
            guard legacyAggregateOverlays.isEmpty,
                  importedFiles.keys.allSatisfy(Self.releaseReplacementFiles.contains) else {
                throw PersonalDataError("release分類の取り込みにはrelease辞書IDだけを指定してください")
            }
            guard hasTrustedReleaseMarker || isBundledBootstrap || !importsReleaseCategories else {
                throw PersonalDataError("release分類の取り込みにはrelease世代または同梱辞書が必要です")
            }
        case .typedLegacyAggregate:
            let forbiddenFlatCategories = Self.releaseCategoryFiles.union(Self.legacyAggregateRootFiles)
            let untypedCategoryFiles = Set(importedFiles.keys).intersection(forbiddenFlatCategories).sorted()
            guard untypedCategoryFiles.isEmpty else {
                throw PersonalDataError("分類辞書は旧分類集約モードで通常世代へ取り込めません: " + untypedCategoryFiles.joined(separator: ", "))
            }
        }
        let publishedLegacyOverlays: [DictionaryCategoryCatalog.LegacyAggregateID]
        let retainedLegacyOverlays: Set<DictionaryCategoryCatalog.LegacyAggregateID>
        if hasTrustedReleaseMarker {
            guard importedFiles.keys.allSatisfy(Self.releaseReplacementFiles.contains) else {
                let legacyOnlyFiles = Set(DictionaryArchivePlan.categoryIDs
                    .filter { !DictionaryCategoryCatalog.idSet.contains($0) }
                    .map { $0 + ".sud" })
                let untypedLegacyFiles = Set(importedFiles.keys).intersection(legacyOnlyFiles).sorted()
                if !untypedLegacyFiles.isEmpty {
                    throw PersonalDataError("新分類辞書にない旧集約IDは型付きで取り込む必要があります: " + untypedLegacyFiles.joined(separator: ", "))
                }
                throw PersonalDataError("release世代にはrelease辞書IDのみ取り込めます")
            }
        }
        var retainedOverlaySources: [DictionaryCategoryCatalog.LegacyAggregateID: URL] = [:]
        for generation in existingGenerations {
            for id in generation.legacyAggregateOverlayIDs where retainedOverlaySources[id] == nil {
                let file = Self.legacyAggregateFile(id)
                guard let source = try Self.existingFile(file, in: generation.directory) else {
                    throw PersonalDataError("保存済みの旧分類辞書が見つかりません: \(id.rawValue)")
                }
                retainedOverlaySources[id] = source
            }
        }
        retainedLegacyOverlays = Set(retainedOverlaySources.keys).subtracting(incomingOverlayIDs)
        publishedLegacyOverlays = (retainedLegacyOverlays.union(incomingOverlayIDs)).sorted { $0.rawValue < $1.rawValue }
        var retainedUnclassifiedCategorySources: [String: URL] = [:]
        for generation in existingGenerations {
            for (id, source) in generation.unclassifiedCategorySources where retainedUnclassifiedCategorySources[id] == nil {
                retainedUnclassifiedCategorySources[id] = source
            }
        }
        let publishesReleaseTaxonomy = hasTrustedReleaseMarker ||
            (importMode == .releaseLeaf && importsReleaseCategories && isBundledBootstrap)
        let publishedUnclassifiedCategoryIDs = publishesReleaseTaxonomy
            ? retainedUnclassifiedCategorySources.keys.sorted()
            : []
        if let supportFallback {
            guard supportFallback.isFileURL else { throw PersonalDataError("補助辞書の保存先が不正です") }
            try Self.requireDirectory(supportFallback)
        }
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
        var sources: [String: URL] = [:]
        var unclassifiedCategorySources: [String: URL] = [:]
        var overlaySources: [String: URL] = [:]
        for file in Self.replacementFiles.subtracting(Self.supportFiles) where !importedNames.contains(file) {
            let source = try Self.existingFile(file, in: baseDirectory)
            if let source { sources[file] = source }
        }
        for group in Self.supportGroups {
            let existing = try group.map { try Self.existingFile($0, in: baseDirectory) }
            let present = existing.compactMap { $0 }.count
            guard present == 0 || present == group.count else {
                throw PersonalDataError("基準辞書の補助資産が一部しかありません")
            }
            let selected: [URL?]
            if present == group.count { selected = existing }
            else if let supportFallback,
                    supportFallback.standardizedFileURL != baseDirectory.standardizedFileURL {
                selected = try group.map { try Self.existingFile($0, in: supportFallback) }
                guard selected.allSatisfy({ $0 != nil }) else {
                    throw PersonalDataError("同梱の補助辞書が不足しています")
                }
            } else { selected = existing }
            for (file, source) in zip(group, selected) where !importedNames.contains(file) {
                if let source { sources[file] = source }
            }
        }
        if hasTrustedReleaseMarker, let marker = releaseMarkerSource {
            sources[DictionaryCategoryCatalog.releaseMarker] = marker
        }
        for id in retainedLegacyOverlays {
            let file = Self.legacyAggregateFile(id)
            guard let source = retainedOverlaySources[id] else {
                throw PersonalDataError("保存済みの旧分類辞書が見つかりません: \(id.rawValue)")
            }
            overlaySources[file] = source
        }
        for (id, source) in legacyAggregateOverlays {
            overlaySources[Self.legacyAggregateFile(id)] = source
        }
        for id in publishedUnclassifiedCategoryIDs {
            guard let source = retainedUnclassifiedCategorySources[id] else {
                throw PersonalDataError("分類を判定できない既存辞書が見つかりません: \(id)")
            }
            unclassifiedCategorySources[Self.unclassifiedCategoryFile(id)] = source
        }
        for (file, source) in sources.sorted(by: { $0.key < $1.key }) {
            let destination = final.appendingPathComponent(file)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.copyRegularFile(source, to: destination, totalBytes: &totalBytes)
        }
        for (file, source) in importedFiles.sorted(by: { $0.key < $1.key }) {
            let destination = final.appendingPathComponent(file)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try Self.copyRegularFile(source, to: destination, totalBytes: &totalBytes)
        }
        for (file, source) in overlaySources.sorted(by: { $0.key < $1.key }) {
            let destination = final.appendingPathComponent(file)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.copyRegularFile(source, to: destination, totalBytes: &totalBytes)
        }
        for (file, source) in unclassifiedCategorySources.sorted(by: { $0.key < $1.key }) {
            let destination = final.appendingPathComponent(file)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.copyRegularFile(source, to: destination, totalBytes: &totalBytes)
        }
        if importMode == .releaseLeaf && importsReleaseCategories && !hasTrustedReleaseMarker {
            let markerURL = final.appendingPathComponent(DictionaryCategoryCatalog.releaseMarker)
            try Data().write(to: markerURL, options: .atomic)
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
        if manager.fileExists(atPath: final.appendingPathComponent("mozc").path) {
            try Self.synchronize(final.appendingPathComponent("mozc"))
        }
        let manifest = Manifest(formatVersion: 1, generation: generation,
                                sourceRevision: "unknown-or-mixed",
                                importedFiles: importedFiles.keys.sorted(), outputSHA256: hashes,
                                legacyAggregateOverlayIDs: publishedLegacyOverlays.map(\.rawValue),
                                preservedUnclassifiedCategoryIDs: publishedUnclassifiedCategoryIDs)
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

        let previous = (try? readPointer(currentPointer).pointer) ?? (try? readPointer(previousPointer).pointer)
        if let previous {
            try encoder.encode(previous).write(to: previousPointer, options: .atomic)
            try Self.synchronize(previousPointer)
        }
        try pointerData.write(to: currentPointer, options: .atomic)
        published = true
        try? Self.synchronize(currentPointer)
        try? Self.synchronize(directory)

        Self.removeUnreferencedGenerations(in: directory, keeping: [name, previous?.generation].compactMap { $0 })
        return Loaded(directory: final, generation: name, recoveredPrevious: false,
                      hasVerifiedReleaseMarker: hashes[DictionaryCategoryCatalog.releaseMarker] != nil,
                      legacyAggregateOverlayIDs: publishedLegacyOverlays,
                      legacyAggregateOverlaySHA256: Dictionary(uniqueKeysWithValues:
                        publishedLegacyOverlays.compactMap { id in
                            hashes[Self.legacyAggregateFile(id)].map { (id, $0) }
                        }),
                      releaseLeafSHA256: hashes.filter { Self.releaseCategoryFiles.contains($0.key) },
                      preservedUnclassifiedCategoryIDs: publishedUnclassifiedCategoryIDs,
                      unclassifiedLegacyRootCategoryIDs: [],
                      unclassifiedCategorySources: Dictionary(uniqueKeysWithValues:
                        publishedUnclassifiedCategoryIDs.map { id in
                            (id, final.appendingPathComponent(Self.unclassifiedCategoryFile(id)))
                        }))
    }

    private func load(_ pointerURL: URL, recoveredPrevious: Bool) throws -> Loaded {
        let verified = try readPointer(pointerURL)
        let pointer = verified.pointer
        let target = directory.appendingPathComponent(pointer.generation, isDirectory: true)
        return Loaded(directory: target, generation: pointer.generation, recoveredPrevious: recoveredPrevious,
                      hasVerifiedReleaseMarker: verified.hasVerifiedReleaseMarker,
                      legacyAggregateOverlayIDs: verified.legacyAggregateOverlayIDs,
                      legacyAggregateOverlaySHA256: verified.legacyAggregateOverlaySHA256,
                      releaseLeafSHA256: verified.releaseLeafSHA256,
                      preservedUnclassifiedCategoryIDs: verified.preservedUnclassifiedCategoryIDs,
                      unclassifiedLegacyRootCategoryIDs: verified.unclassifiedLegacyRootCategoryIDs,
                      unclassifiedCategorySources: verified.unclassifiedCategorySources)
    }

    private func readPointer(_ url: URL) throws -> VerifiedPointer {
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
        let legacyAggregateOverlayRawValues = manifest.legacyAggregateOverlayIDs ?? []
        let legacyAggregateOverlayIDs = legacyAggregateOverlayRawValues.map {
            DictionaryCategoryCatalog.LegacyAggregateID(rawValue: $0)
        }
        let preservedUnclassifiedCategoryRawValues = manifest.preservedUnclassifiedCategoryIDs ?? []
        let unclassifiedCategoryIDs = Set(preservedUnclassifiedCategoryRawValues)
        guard manifest.formatVersion == 1, manifest.generation == String(pointer.generation.dropFirst("generation-".count)),
              manifest.outputSHA256.keys.allSatisfy(Self.knownFiles.contains),
              manifest.outputSHA256.values.allSatisfy(Self.isSHA256),
              manifest.importedFiles.allSatisfy(Self.replacementFiles.contains),
              Set(legacyAggregateOverlayRawValues).count == legacyAggregateOverlayRawValues.count,
              Set(legacyAggregateOverlayIDs).isSubset(of: Self.legacyAggregateIDs),
              Set(preservedUnclassifiedCategoryRawValues).count == preservedUnclassifiedCategoryRawValues.count,
              unclassifiedCategoryIDs.isSubset(of: Set(DictionaryCategoryCatalog.legacyIDs)),
              legacyAggregateOverlayIDs.allSatisfy({
                  let file = Self.legacyAggregateFile($0)
                  return manifest.outputSHA256[file] != nil
              }),
              manifest.outputSHA256["system.sud"] != nil, manifest.outputSHA256["connection.sud"] != nil else {
            throw PersonalDataError("辞書世代マニフェストの形式が不正です")
        }
        var verifiedFiles: [String: URL] = [:]
        for file in manifest.outputSHA256.keys {
            guard let url = try Self.existingFile(file, in: target) else {
                throw PersonalDataError("辞書世代ファイルがありません: \(file)")
            }
            verifiedFiles[file] = url
        }
        for id in legacyAggregateOverlayIDs {
            let file = Self.legacyAggregateFile(id)
            guard let expected = manifest.outputSHA256[file], let url = verifiedFiles[file],
                  try Self.sha256(of: url) == expected else {
                throw PersonalDataError("保存された旧分類辞書のチェックサムが一致しません: \(id.rawValue)")
            }
        }
        let releaseMarkerFile = DictionaryCategoryCatalog.releaseMarker
        let hasVerifiedReleaseMarker: Bool
        if let expected = manifest.outputSHA256[releaseMarkerFile],
           let markerURL = verifiedFiles[releaseMarkerFile] {
            guard try Self.sha256(of: markerURL) == expected else {
                throw PersonalDataError("辞書世代の分類マーカーのチェックサムが一致しません")
            }
            hasVerifiedReleaseMarker = true
        } else {
            hasVerifiedReleaseMarker = false
        }
        var unclassifiedCategorySources: [String: URL] = [:]
        for id in preservedUnclassifiedCategoryRawValues {
            let file = Self.unclassifiedCategoryFile(id)
            guard let expected = manifest.outputSHA256[file], let url = verifiedFiles[file],
                  try Self.sha256(of: url) == expected else {
                throw PersonalDataError("分類未判定の既存辞書のチェックサムが一致しません: \(id)")
            }
            unclassifiedCategorySources[id] = url
        }
        // Before the release marker was introduced, the manifest recorded flat
        // category filenames but not their taxonomy. Treat these bytes as opaque
        // sources: they may be legacy aggregates or newer release leaves.
        var unclassifiedLegacyRootCategoryIDs: [String] = []
        if !hasVerifiedReleaseMarker {
            for id in DictionaryCategoryCatalog.legacyIDs {
                let file = id + ".sud"
                guard manifest.outputSHA256[file] != nil,
                      let url = try Self.existingFile(file, in: target) else { continue }
                unclassifiedLegacyRootCategoryIDs.append(id)
                if unclassifiedCategorySources[id] == nil { unclassifiedCategorySources[id] = url }
            }
        }
        return VerifiedPointer(pointer: pointer,
                              hasVerifiedReleaseMarker: hasVerifiedReleaseMarker,
                              legacyAggregateOverlayIDs: legacyAggregateOverlayIDs.sorted { $0.rawValue < $1.rawValue },
                              legacyAggregateOverlaySHA256: Dictionary(uniqueKeysWithValues:
                                legacyAggregateOverlayIDs.compactMap { id in
                                    manifest.outputSHA256[Self.legacyAggregateFile(id)].map { (id, $0) }
                                }),
                              releaseLeafSHA256: manifest.outputSHA256.filter {
                                  Self.releaseCategoryFiles.contains($0.key)
                              },
                              preservedUnclassifiedCategoryIDs: preservedUnclassifiedCategoryRawValues.sorted(),
                              unclassifiedLegacyRootCategoryIDs: unclassifiedLegacyRootCategoryIDs.sorted(),
                              unclassifiedCategorySources: unclassifiedCategorySources)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PersonalDataError("辞書フォルダが通常のフォルダではありません")
        }
    }

    private static func existingFile(_ file: String, in root: URL) throws -> URL? {
        let manager = FileManager.default
        let url = root.appendingPathComponent(file)
        var parent = root
        for component in file.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            do { try requireDirectory(parent) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        }
        do {
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw PersonalDataError("辞書資産が通常ファイルではありません: \(file)")
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        return url
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
