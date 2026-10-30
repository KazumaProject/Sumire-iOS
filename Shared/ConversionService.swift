import Foundation
import Darwin
import os
import SumireCore

struct ConversionCandidate {
    enum PresentationKind: UInt32 { case none = 0, halfWidth = 1, fullWidth = 2, numericSymbol = 3 }
    let id: UInt64
    let text: String
    let score: Int64
    let range: NSRange
    let dictionaries: [String]
    let rawText: String?
    let correctedReading: String?
    let isReadingPrefix: Bool
    let textMacroID: String?
    let presentationKind: PresentationKind
    let classifiedCategories: [String]
    let leftID: Int16?
    let rightID: Int16?
    var displayAnnotation: String? {
        let badge: String
        if let correctedReading, !correctedReading.isEmpty { badge = "[読] " + correctedReading }
        else if isReadingPrefix { badge = "[部]" }
        else {
            switch presentationKind {
            case .none: badge = ""
            case .halfWidth: badge = "[半]"
            case .fullWidth: badge = "[全]"
            case .numericSymbol:
                let units = Array(text.utf16)
                if (1...2).contains(units.count), units.allSatisfy(Self.halfWidthNumericSymbol) { badge = "[半]" }
                else if (1...2).contains(units.count), units.allSatisfy(Self.fullWidthNumericSymbol) { badge = "[全]" }
                else { badge = "" }
            }
        }
        let legacy = Set(Self.categoryLabels.map(\.0))
        // Keep source identities typed; only the user-visible family label is shared.
        let displayCategoryIDs = classifiedCategories.map { id -> String in
            let prefix = "legacy_aggregates/"
            guard id.hasPrefix(prefix) else { return id }
            let family = String(id.dropFirst(prefix.count))
            return legacy.contains(family) ? family : id
        }
        let labels = Self.categoryLabels.filter { displayCategoryIDs.contains($0.0) }.map(\.1) +
            displayCategoryIDs.filter { !legacy.contains($0) }.map { DictionaryCategoryCatalog.label(for: $0) }
        let categoryBadge = labels.isEmpty ? "" : "[" + labels.joined(separator: "・") + "]"
        let value = [badge, categoryBadge].filter { !$0.isEmpty }.joined(separator: " ")
        return value.isEmpty ? nil : value
    }
    // Pinned df1f383 ClassifiedDictionaries order and Japanese label resources.
    private static let categoryLabels: [(String, String)] = [
        ("person", "人名"), ("character", "キャラクター"), ("mythological_figure", "神話・伝承"),
        ("place", "地名"), ("address", "住所"), ("station", "駅・停留所"), ("facility", "施設"),
        ("transport_route", "交通路線"), ("organization", "組織"), ("lineage", "家系・氏族"),
        ("product", "商品・サービス"), ("vehicle", "車両・船舶"), ("event", "イベント・事件"),
        ("award", "賞"), ("agreement", "条約・協定"), ("initiative", "事業・キャンペーン"),
        ("term", "用語"), ("work_franchise", "作品シリーズ"), ("work_manga", "漫画"),
        ("work_anime", "アニメ"), ("work_film", "映画"), ("work_program", "番組"),
        ("work_book", "書籍"), ("work_game", "ゲーム"), ("work_music", "音楽"),
        ("work_stage", "舞台"), ("work_periodical", "定期刊行物"), ("work_other", "その他作品"),
        ("kampo", "漢方・生薬"), ("medical", "医療")]
    private static func halfWidthNumericSymbol(_ unit: UInt16) -> Bool {
        (0x20...0x40).contains(unit) || (0x5b...0x60).contains(unit) || (0x7b...0x7e).contains(unit)
    }
    private static func fullWidthNumericSymbol(_ unit: UInt16) -> Bool {
        unit == 0x3000 || (0xff01...0xff20).contains(unit) || (0xff3b...0xff40).contains(unit) || (0xff5b...0xff5e).contains(unit)
    }
    /// Match the pinned Android display merger: raw UTF-16 identity, first
    /// candidate behavior/order, and classified labels from equal commits.
    /// Swift String equality folds canonical equivalents; Kotlin does not.
    static func mergedForDisplay(_ candidates: [ConversionCandidate]) -> [ConversionCandidate] {
        var positions: [[UInt16]: Int] = [:]
        var merged: [ConversionCandidate] = []
        merged.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = Array((candidate.rawText ?? candidate.text).utf16)
            guard let index = positions[key] else {
                positions[key] = merged.count
                merged.append(candidate)
                continue
            }
            let first = merged[index]
            guard first.text.utf16.elementsEqual(candidate.text.utf16) else { continue }
            var categories = first.classifiedCategories
            for name in candidate.classifiedCategories where !categories.contains(name) {
                categories.append(name)
            }
            // Preserve legacy provenance-label aggregation independently from
            // Android's classified badge set. These are not path segments.
            var dictionaries = first.dictionaries
            for name in candidate.dictionaries where !dictionaries.contains(name) {
                dictionaries.append(name)
            }
            guard categories != first.classifiedCategories || dictionaries != first.dictionaries else { continue }
            merged[index] = ConversionCandidate(id: first.id, text: first.text,
                score: first.score, range: first.range, dictionaries: dictionaries,
                bunsetsu: first.bunsetsu, rawText: first.rawText,
                correctedReading: first.correctedReading, isReadingPrefix: first.isReadingPrefix,
                textMacroID: first.textMacroID,
                presentationKind: first.presentationKind, classifiedCategories: categories,
                leftID: first.leftID, rightID: first.rightID)
        }
        return merged
    }
    /// Owned Swift values projected from this candidate's path only. Ranges are
    /// UTF-16 offsets within the consumed reading (currently a prefix at zero).
    let bunsetsu: [BunsetsuSegment]

    init(id: UInt64, text: String, score: Int64, range: NSRange,
         dictionaries: [String], bunsetsu: [BunsetsuSegment] = [],
         rawText: String? = nil, correctedReading: String? = nil, isReadingPrefix: Bool = false,
         textMacroID: String? = nil,
         presentationKind: PresentationKind = .none, classifiedCategories: [String] = [],
         leftID: Int16? = nil, rightID: Int16? = nil) {
        self.id = id
        self.text = text
        self.score = score
        self.range = range
        self.dictionaries = dictionaries
        self.bunsetsu = bunsetsu
        self.rawText = rawText
        self.correctedReading = correctedReading
        self.isReadingPrefix = isReadingPrefix
        self.textMacroID = textMacroID
        self.presentationKind = presentationKind
        self.classifiedCategories = classifiedCategories
        self.leftID = leftID
        self.rightID = rightID
    }
}
struct ConversionResponse {
    let generation: UInt64
    let candidates: [ConversionCandidate]
    let elapsedMilliseconds: Double
    let complete: Bool
    let warning: String?
    let bunsetsuSnapshot: BunsetsuConversionSnapshot?
    let orderedDisplayIdentities: [BunsetsuCandidateDisplayIdentity]

    init(generation: UInt64, candidates: [ConversionCandidate], elapsedMilliseconds: Double,
         complete: Bool, warning: String?, bunsetsuSnapshot: BunsetsuConversionSnapshot? = nil) {
        self.generation = generation
        self.candidates = candidates
        self.elapsedMilliseconds = elapsedMilliseconds
        self.complete = complete
        self.warning = warning
        self.bunsetsuSnapshot = bunsetsuSnapshot
        self.orderedDisplayIdentities = candidates.map {
            BunsetsuCandidateDisplayIdentity(surface: $0.text, readingUTF16Length: $0.range.length)
        }
    }
}

/// All native handles are confined to this queue. Results are copied to Swift
/// before the C snapshot is released; the main thread never observes C pointers.
final class ConversionService {
    private let queue = DispatchQueue(label: "sumire.conversion", qos: .userInitiated)
    private let state = NativeState()
    private let pending = PendingRequest()
    private let learningConfiguration = PendingRequest()
    private var learnMixedSymbolsAndNumbers = true
    private let sourceOverride: [NativeDictionaryEngineSource]?
    private var cachedDictionarySources: [NativeDictionaryEngineSource]?
    private var lastDictionaryRefresh = 0.0
    private var englishReadingEnabled = true
    private var predictionSettings = JapanesePredictionSettings()
    private var categoryIDs: [String]?
    private var categoryMask: UInt32
    private var personal = PersonalLexicon()
    private var learningURL: URL?

    init(categoryMask: UInt32 = 0) {
        self.sourceOverride = nil
        self.categoryMask = categoryMask
    }
    init(directory: URL?, categoryMask: UInt32 = 0) {
        self.sourceOverride = directory.map { [NativeDictionaryEngineSource(directory: $0)] }
        self.categoryMask = categoryMask
    }
    init(sources: [NativeDictionaryEngineSource], categoryMask: UInt32 = 0) {
        self.sourceOverride = sources
        self.categoryMask = categoryMask
    }
    private static var activeDictionarySources: [NativeDictionaryEngineSource] {
        var sources = PersonalDataLocation.readableDictionaryGenerations()
            .map { NativeDictionaryEngineSource(generation: $0) }
        if let bundledDictionary, !sources.contains(where: { $0.directory == bundledDictionary }) {
            sources.append(NativeDictionaryEngineSource(directory: bundledDictionary))
        }
        return sources
    }
    // Called only on the serial conversion queue. Keep the verified generation
    // record, not only its URL, while avoiding main-thread App Group reads.
    private func resolveActiveDictionaries() -> [NativeDictionaryEngineSource] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDictionaryRefresh < 0.5 { return cachedDictionarySources ?? [] }
        lastDictionaryRefresh = now
        cachedDictionarySources = Self.activeDictionarySources
        return cachedDictionarySources ?? []
    }
    static var bundledDictionary: URL? {
        let bundle = Bundle.main.bundleURL
        let locations = ["dictionary-v1.7.277", "standard-mozc-scoring-auxiliary-correction-english", "standard-mozc-scoring-auxiliary-english", "cli-priority-v1", "cli-english-v1"].flatMap { name in
            [bundle.appendingPathComponent(name, isDirectory: true),
             bundle.appendingPathComponent("PlugIns/SumireKeyboard.appex/" + name, isDirectory: true)]
        }
        return locations.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("system.sud").path) }
    }
    func setEnglishReading(_ enabled: Bool) {
        guard englishReadingEnabled != enabled else { return }
        englishReadingEnabled = enabled
        _ = pending.advance()
        let state = state
        queue.async { state.close() }
    }
    func setCategories(_ mask: UInt32) {
        guard categoryMask != mask else { return }
        categoryMask = mask
        _ = pending.advance()
        let state = state
        queue.async { state.close() }
    }
    func setCategoryIDs(_ ids: [String]?) {
        let ids = ids.map(DictionaryCategoryCatalog.normalize)
        guard categoryIDs != ids else { return }
        categoryIDs = ids
        _ = pending.advance()
        let state = state
        queue.async { state.close() }
    }
    func setPredictionSettings(_ settings: JapanesePredictionSettings) {
        guard predictionSettings != settings else { return }
        predictionSettings = settings
        _ = pending.advance()
        let state = state
        queue.async { state.lastGeneration = nil }
    }
    func setPersonal(_ value: PersonalLexicon) {
        guard value != personal else { return }
        personal = value
        _ = pending.advance()
        let state = state
        queue.async { state.close(); state.personal = value }
    }
    func setLearning(url: URL?, localReset: LocalDataReset? = nil) {
        guard learningURL != url || localReset != nil else { return }
        learningURL = url
        _ = pending.advance()
        let state = state
        queue.async {
            state.cancelLearning()
            state.learning = nil; state.learningURL = nil; state.learningFailure = nil
            do {
                try localReset?.apply()
                state.learningURL = url
            } catch { state.learningFailure = "学習データの削除を再試行します: " + error.localizedDescription }
        }
    }
    func setLearnMixedSymbolsAndNumbers(_ enabled: Bool) {
        guard enabled != learnMixedSymbolsAndNumbers else { return }
        learnMixedSymbolsAndNumbers = enabled
        _ = learningConfiguration.advance()
        _ = pending.advance()
        let state = state
        queue.async {
            state.cancelLearning()
            state.learnMixedSymbolsAndNumbers = enabled
            state.lastGeneration = nil
        }
    }
    func setLearningPaused(_ paused: Bool) {
        let state = state
        queue.async { state.learningPaused = paused; if paused { state.cancelLearning() } }
    }
    func convert(_ reading: String, generation: UInt64, editStart: Int, omission: Bool = false, english: Bool = false,
                 includeBunsetsu: Bool = false, bunsetsuSearch: Bool = false,
                 completion: @escaping (Result<ConversionResponse, Error>) -> Void) {
        let state = state, sourceOverride = sourceOverride
        let mask = categoryMask, englishReading = englishReadingEnabled
        let predictionSettings = predictionSettings, categoryIDs = categoryIDs
        let pending = pending, ticket = pending.advance()
        queue.async {
            guard pending.isCurrent(ticket) else { return }
            let sources = sourceOverride ?? self.resolveActiveDictionaries()
            ProcessMemory.record("conversion.begin")
            defer { ProcessMemory.record("conversion.end") }
            let response: Result<ConversionResponse, Error>
            do {
                try state.open(sources: sources, mask: mask, english: english, englishReading: englishReading, categoryIDs: categoryIDs)
                try state.setPredictionSettings(predictionSettings)
                let warnings = [try state.prepareLearning(reading: reading, english: english),
                    state.unavailableCategoryIDs.isEmpty ? nil : "この辞書世代では選択した分類の一部が未提供、または旧分類単位で適用されます（\(state.unavailableCategoryIDs.count)分類）",
                    !english && !state.standaloneAvailable ? "優先候補辞書がありません。新しい辞書世代への更新が必要です" : nil].compactMap { $0 }
                let warning = warnings.isEmpty ? nil : warnings.joined(separator: " / ")
                var error = [CChar](repeating: 0, count: 1024)
                var result: OpaquePointer?
                let flags: UInt32
                if english { flags = 2 }
                else { flags = (omission ? 1 : 0) | (bunsetsuSearch ? 16 : 12) }
                // UI composition and bunsetsu loads have different generation
                // domains; the C session requires one strictly increasing one.
                state.nativeGeneration += 1
                let nativeGeneration = state.nativeGeneration
                let status = reading.utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
                    var request = sumire_request(generation: nativeGeneration, reading: bytes.baseAddress,
                                                 reading_bytes: bytes.count - 1,
                                                 edit_start_utf16: UInt32(max(0, editStart)),
                                                 candidate_count: 20, max_states: 200_000, flags: flags)
                    return sumire_session_update(state.session, &request, &result, &error, error.count)
                }
                guard status == 0, let result else { throw NativeError(String(cString: error)) }
                defer { sumire_result_destroy(result) }
                var metrics = sumire_metrics()
                guard sumire_result_metrics(result, &metrics) == 0 else { throw NativeError("変換結果の計測情報が不正です") }
                let ownedSnapshot = (includeBunsetsu || bunsetsuSearch)
                    ? try Self.copyBunsetsuSnapshot(result, reading: reading, generation: generation) : nil
                var candidates: [ConversionCandidate] = []
                for index in 0..<sumire_result_count(result) {
                    var candidate = sumire_candidate()
                    guard sumire_result_candidate(result, index, &candidate) == 0 else { throw NativeError("候補を取得できません") }
                    let text = Self.copy(candidate.text)
                    var raw = sumire_string(), corrected = sumire_string()
                    guard sumire_result_reading_correction(result, index, &raw, &corrected) == 0 else {
                        throw NativeError("読み訂正情報を取得できません")
                    }
                    let rawText = Self.copy(raw), correctedReading = Self.copy(corrected)
                    var candidateFlags: UInt32 = 0
                    guard sumire_result_candidate_flags(result, index, &candidateFlags) == 0 else {
                        throw NativeError("候補の種類を取得できませんでした")
                    }
                    var kind: UInt32 = 0
                    guard sumire_result_candidate_presentation_kind(result, index, &kind) == 0,
                          let presentationKind = ConversionCandidate.PresentationKind(rawValue: kind) else {
                        throw NativeError("候補の表示情報が不正です")
                    }
                    let range = NSRange(location: Int(candidate.start_utf16), length: Int(candidate.length_utf16))
                    // Auxiliary and predicted entries can be malformed for this
                    // input range. They must not make the complete conversion fail
                    // or expose a candidate that cannot be committed safely.
                    guard range.location == 0, range.length > 0,
                          let consumedRange = Range(range, in: reading) else { continue }
                    var dictionaries: [String] = []
                    var tokens: [BunsetsuToken] = []
                    var leftID: Int16?, rightID: Int16?
                    for segmentIndex in 0..<candidate.segment_count {
                        var segment = sumire_segment()
                        guard sumire_result_segment(result, index, segmentIndex, &segment) == 0 else { throw NativeError("候補範囲が不正です") }
                        var nativeLeft: UInt16 = 0, nativeRight: UInt16 = 0
                        guard sumire_result_segment_context_ids(result, index, segmentIndex,
                            &nativeLeft, &nativeRight) == 0 else { throw NativeError("候補接続IDを取得できません") }
                        if segmentIndex == 0 { leftID = Int16(bitPattern: nativeLeft) }
                        rightID = Int16(bitPattern: nativeRight)
                        if includeBunsetsu || bunsetsuSearch {
                            tokens.append(BunsetsuToken(
                                readingRange: NSRange(location: Int(segment.start_utf16), length: Int(segment.length_utf16)),
                                text: Self.copy(segment.text), leftID: Int16(bitPattern: nativeLeft),
                                rightID: Int16(bitPattern: nativeRight)))
                        }
                        let name = Self.copy(segment.dictionary)
                        if !dictionaries.contains(name) { dictionaries.append(name) }
                    }
                    var classifiedCategories: [String] = []
                    for categoryIndex in 0..<sumire_result_category_count(result, index) {
                        var category = sumire_string()
                        guard sumire_result_category(result, index, categoryIndex, &category) == 0 else {
                            throw NativeError("候補の辞書分類が不正です")
                        }
                        let name = Self.copy(category)
                        if !classifiedCategories.contains(name) { classifiedCategories.append(name) }
                    }
                    var bunsetsu: [BunsetsuSegment] = []
                    if includeBunsetsu || bunsetsuSearch {
                        var boundaries: [Int] = []
                        for boundaryIndex in 0..<sumire_result_bunsetsu_count(result, index) {
                            var offset: UInt32 = 0
                            guard sumire_result_bunsetsu_boundary(result, index, boundaryIndex, &offset) == 0 else {
                                throw NativeError("文節の範囲が不正です")
                            }
                            boundaries.append(Int(offset))
                        }
                        // Partial matches project only their consumed prefix. A completion
                        // spans the typed prefix, not the longer predicted reading.
                        // All text is owned before the native snapshot is destroyed.
                        if !tokens.isEmpty {
                            bunsetsu = (try? BunsetsuProjection.project(
                                reading: String(reading[consumedRange]), candidate: text,
                                tokens: tokens, boundaries: boundaries)) ?? []
                        }
                    }
                    candidates.append(ConversionCandidate(id: candidate.candidate_id, text: text,
                                                          score: candidate.score, range: range,
                                                          dictionaries: dictionaries, bunsetsu: bunsetsu,
                                                          rawText: rawText.isEmpty ? nil : rawText,
                                                          correctedReading: correctedReading.isEmpty ? nil : correctedReading,
                                                          isReadingPrefix: candidateFlags & UInt32(SUMIRE_CANDIDATE_READING_PREFIX) != 0,
                                                          presentationKind: presentationKind,
                                                          classifiedCategories: classifiedCategories,
                                                          leftID: leftID, rightID: rightID))
                }
                candidates = ConversionCandidate.mergedForDisplay(candidates)
                state.lastGeneration = generation
                state.lastCandidateOrder = candidates.map(\.id)
                state.lastReading = reading
                state.lastCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
                response = .success(ConversionResponse(generation: generation, candidates: candidates,
                                                       elapsedMilliseconds: metrics.conversion_ms, complete: metrics.complete != 0, warning: warning,
                                                       bunsetsuSnapshot: ownedSnapshot))
            } catch { response = .failure(error) }
            DispatchQueue.main.async { completion(response) }
        }
    }
    /// Copy all native indexes before display merging and before result destruction.
    /// An explicitly empty mapping differs from a missing mapping.
    private static func copyBunsetsuSnapshot(_ result: OpaquePointer, reading: String,
                                            generation: UInt64) throws -> BunsetsuConversionSnapshot {
        func boundaries(_ count: Int, _ read: (Int, UnsafeMutablePointer<UInt32>) -> Int32) throws -> [Int] {
            try (0..<count).map { index in
                var offset: UInt32 = 0
                guard read(index, &offset) == 0 else { throw NativeError("文節境界を取得できません") }
                return Int(offset)
            }
        }
        let patterns = try (0..<sumire_result_bunsetsu_split_pattern_count(result)).map { pattern in
            try boundaries(sumire_result_bunsetsu_split_pattern_boundary_count(result, pattern)) {
                sumire_result_bunsetsu_split_pattern_boundary(result, pattern, $0, $1)
            }
        }
        let primary = try boundaries(sumire_result_primary_bunsetsu_boundary_count(result)) {
            sumire_result_primary_bunsetsu_boundary(result, $0, $1)
        }
        let candidates = try (0..<sumire_result_count(result)).map { index -> BunsetsuSnapshotCandidate in
            var row = sumire_candidate()
            var hasMapping: Int32 = 0
            guard sumire_result_candidate(result, index, &row) == 0,
                  sumire_result_candidate_has_bunsetsu_split_pattern(result, index, &hasMapping) == 0 else {
                throw NativeError("文節候補を取得できません")
            }
            let tokens = try (0..<row.segment_count).map { tokenIndex -> BunsetsuToken in
                var token = sumire_segment()
                guard sumire_result_segment(result, index, tokenIndex, &token) == 0 else {
                    throw NativeError("文節候補経路を取得できません")
                }
                var left: UInt16 = 0, right: UInt16 = 0
                guard sumire_result_segment_context_ids(result, index, tokenIndex, &left, &right) == 0 else {
                    throw NativeError("文節接続IDを取得できません")
                }
                return BunsetsuToken(readingRange: NSRange(location: Int(token.start_utf16), length: Int(token.length_utf16)),
                    text: copy(token.text), leftID: Int16(bitPattern: left), rightID: Int16(bitPattern: right))
            }
            let mapped: [Int]? = hasMapping == 0 ? nil : try boundaries(sumire_result_bunsetsu_count(result, index)) {
                sumire_result_bunsetsu_boundary(result, index, $0, $1)
            }
            return BunsetsuSnapshotCandidate(nativeIndex: index, candidateID: row.candidate_id, score: row.score,
                identity: BunsetsuCandidateDisplayIdentity(surface: copy(row.text), readingUTF16Length: Int(row.length_utf16)),
                tokenPath: tokens.isEmpty ? nil : tokens, mappedSplitPositions: mapped,
                leftID: tokens.first?.leftID, rightID: tokens.last?.rightID)
        }
        return BunsetsuConversionSnapshot(requestGeneration: generation, reading: reading,
            splitPatterns: patterns, primarySplitPositions: primary, candidates: candidates)
    }

    /// Compatibility entry point for consumers committing a whole native result.
    func commit(generation: UInt64, candidate: UInt64, learn: Bool, onNotice: @escaping (String) -> Void) {
        enqueueCommit(generation: generation, candidate: candidate, rank: nil, input: nil,
                      remaining: nil, expected: nil, learnFirst: learn, enabled: learn, onNotice: onNotice)
    }

    func commitSelection(generation: UInt64, candidate: ConversionCandidate, rank: Int,
                         input: String, remaining: String, learnFirst: Bool,
                         onNotice: @escaping (String) -> Void) {
        enqueueCommit(generation: generation, candidate: candidate.id, rank: rank, input: input,
                      remaining: remaining, expected: candidate, learnFirst: learnFirst,
                      enabled: true, onNotice: onNotice)
    }

    private func enqueueCommit(generation: UInt64, candidate: UInt64, rank: Int?, input: String?,
                               remaining: String?, expected: ConversionCandidate?, learnFirst: Bool,
                               enabled: Bool, onNotice: @escaping (String) -> Void) {
        let state = state, configuration = learningConfiguration
        let ticket = configuration.current()
        queue.async {
            guard configuration.isCurrent(ticket), state.lastGeneration == generation,
                  let selected = state.lastCandidates[candidate], selected.range.location == 0,
                  let range = Range(selected.range, in: state.lastReading),
                  let nativeRank = state.lastCandidateOrder.firstIndex(of: candidate),
                  rank == nil || rank == nativeRank,
                  input == nil || state.lastReading.utf16.elementsEqual(input!.utf16),
                  expected == nil || (expected!.range == selected.range &&
                    expected!.text.utf16.elementsEqual(selected.text.utf16) && expected!.score == selected.score)
            else { state.cancelLearning(); return }
            let tail = String(state.lastReading[range.upperBound...])
            guard remaining == nil || tail.utf16.elementsEqual(remaining!.utf16) else {
                state.cancelLearning(); return
            }
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_session_commit(state.session, state.nativeGeneration, candidate, &error, error.count) == 0 else {
                state.cancelLearning(); return
            }
            guard enabled else { state.cancelLearning(); return }
            state.appendLearning([LearningFragment(reading: String(state.lastReading[range]),
                output: selected.text, candidateScore: Int32(clamping: selected.score),
                candidateIndex: Int32(clamping: nativeRank), leftID: selected.leftID, rightID: selected.rightID)],
                input: state.lastReading, remaining: remaining ?? "", learnFirst: learnFirst, onNotice: onNotice)
        }
    }

    /// Bunsetsu references can outlive the latest native result. Only the owned
    /// and current Surface plan is used; no old native candidate ID is committed.
    func commitLearningPlan(_ plan: BunsetsuFocusedPrefixCommitPlan, learnFirst: Bool,
                            onNotice: @escaping (String) -> Void) {
        let state = state, configuration = learningConfiguration
        let ticket = configuration.current()
        queue.async {
            guard configuration.isCurrent(ticket) else { state.cancelLearning(); return }
            state.appendLearning(plan.learningFragments.map {
                LearningFragment(reading: $0.reading, output: $0.output,
                    candidateScore: $0.candidateScore, candidateIndex: $0.candidateIndex,
                    leftID: $0.leftID, rightID: $0.rightID, explicitlySelected: $0.explicitlySelected)
            }, input: plan.learningReading, remaining: plan.nextComposingInput,
               learnFirst: learnFirst, onNotice: onNotice)
        }
    }

    func cancelLearning() { let state = state; queue.async { state.cancelLearning() } }
    func appendLearningInput(from input: String, to updated: String) {
        let state = state
        queue.async {
            guard state.learningRemainder?.utf16.elementsEqual(input.utf16) == true,
                  state.learningSession.adoptAppendedRemainder(updated) else {
                state.cancelLearning(); return
            }
            state.learningRemainder = updated
        }
    }
    func synchronizeLearning(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }
    func reset() {
        _ = pending.advance()
        let state = state
        queue.async {
            sumire_session_reset(state.session)
            state.lastReading = ""
            state.lastGeneration = nil
            state.lastCandidateOrder = []
            state.lastCandidates.removeAll(keepingCapacity: false)
        }
    }
    func purgeCache() {
        let state = state
        queue.async { sumire_session_purge_cache(state.session) }
    }
    private static func copy(_ string: sumire_string) -> String {
        guard let bytes = string.data, string.size > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: string.size), as: UTF8.self)
    }
    private struct NativeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    // Superseded work waiting on the serial queue is skipped before opening the
    // dictionary or constructing a lattice. An in-flight result is still checked
    // against the UI composition generation before it can update marked text.
    private final class PendingRequest {
        private let lock = NSLock()
        private var ticket: UInt64 = 0
        func advance() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            ticket &+= 1
            return ticket
        }
        func current() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return ticket
        }
        func isCurrent(_ value: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return ticket == value
        }
    }
    private final class NativeState {
        var session: OpaquePointer?
        var personal = PersonalLexicon()
        var learningURL: URL?
        var learningPaused = false
        var learnMixedSymbolsAndNumbers = true
        var learning: LearningStore?
        var learningFailure: String?
        var standaloneAvailable = false
        var lastReading = ""
        var nativeGeneration: UInt64 = 0
        var lastGeneration: UInt64?
        var lastCandidateOrder: [UInt64] = []
        var learningSession = ConversionLearningSession()
        var learningRemainder: String?
        var lastCandidates: [UInt64: ConversionCandidate] = [:]
        private var openedDirectory: URL?
        // Generations are immutable. Once a native open rejects one, skip it for
        // this process and try the previous pointer or bundled baseline.
        private var rejectedDirectories = Set<URL>()
        var unavailableCategoryIDs: [String] = []
        private var openedCategoryIDs: [String]?
        private var openedMask: UInt32?
        private var openedEnglishReading: Bool?
        private var appliedPredictionSettings: JapanesePredictionSettings?
        func cancelLearning() { learningSession.cancel(); learningRemainder = nil }
        func appendLearning(_ fragments: [LearningFragment], input: String, remaining: String,
                            learnFirst: Bool, onNotice: @escaping (String) -> Void) {
            guard !learningPaused, let url = learningURL else { cancelLearning(); return }
            guard learningSession.append(fragments, from: input, remainingInput: remaining) else {
                cancelLearning(); return
            }
            learningRemainder = remaining
            guard remaining.isEmpty else { return }
            let records = learningSession.finish(learnFirstCandidate: learnFirst,
                timestamp: Int64(Date().timeIntervalSince1970 * 1_000))
            learningRemainder = nil
            do {
                if learning == nil { learning = try LearningStore(url: url) }
                let eligible = records.filter { LearningEligibilityPolicy.isEligible(input: $0.input,
                    output: $0.output, allowJapaneseWithSymbolsAndNumbers: learnMixedSymbolsAndNumbers) }
                try learning?.upsertLearningEntries(eligible)
                if !eligible.isEmpty { DispatchQueue.main.async { onNotice("学習しました") } }
            } catch {
                learningFailure = error.localizedDescription
                DispatchQueue.main.async { onNotice(error.localizedDescription) }
            }
        }
        func prepareLearning(reading: String, english: Bool) throws -> String? {
            var entries: [LearningStore.Entry] = []
            // Android pauses writes, not learned suggestions (IMEService
            // learnedRepositoryForSuggestion / isLearningWriteEnabled).
            if let url = learningURL {
                do {
                    if learning == nil { learning = try LearningStore(url: url) }
                    entries = try english ? learning!.candidates(reading: reading) :
                        learning!.entriesForConversion(reading: reading).filter {
                            LearningEligibilityPolicy.isEligible(input: $0.reading, output: $0.text,
                                allowJapaneseWithSymbolsAndNumbers: true)
                        }
                    learningFailure = nil
                } catch { learningFailure = error.localizedDescription }
            }
            var bytes: [CChar] = []
            var offsets: [(Int, Int, Int, Int)] = []
            for entry in entries {
                let start = bytes.count
                bytes += entry.reading.utf8.map { CChar(bitPattern: $0) }
                let middle = bytes.count
                bytes += entry.text.utf8.map { CChar(bitPattern: $0) }
                offsets.append((start, middle - start, middle, bytes.count - middle))
            }
            var error = [CChar](repeating: 0, count: 1024)
            let status = bytes.withUnsafeBufferPointer { buffer -> Int32 in
                if english {
                    // Preserve the existing English exact/frequency overlay.
                    let records = entries.enumerated().map { index, entry in
                        let range = offsets[index]
                        return sumire_personal_entry(
                            reading: sumire_string(data: buffer.baseAddress?.advanced(by: range.0), size: range.1),
                            text: sumire_string(data: buffer.baseAddress?.advanced(by: range.2), size: range.3),
                            context_id: 0, score: -20000 - Int32(min(100, entry.count)) * 100, kind: 2)
                    }
                    return records.withUnsafeBufferPointer {
                        sumire_session_set_learning(session, $0.baseAddress, $0.count, &error, error.count)
                    }
                }
                let records = entries.enumerated().map { index, entry in
                    let range = offsets[index]
                    // Fixed Android GraphBuilder: each missing endpoint uses
                    // 1851 independently. The C API checks the actual matrix;
                    // neither this fallback nor failure rewrites stored nils.
                    return sumire_learning_entry(
                        reading: sumire_string(data: buffer.baseAddress?.advanced(by: range.0), size: range.1),
                        text: sumire_string(data: buffer.baseAddress?.advanced(by: range.2), size: range.3),
                        left_id: UInt16(bitPattern: entry.leftID ?? 1851),
                        right_id: UInt16(bitPattern: entry.rightID ?? 1851), score: entry.score)
                }
                return records.withUnsafeBufferPointer {
                    sumire_session_set_learning_entries(session, $0.baseAddress, $0.count, &error, error.count)
                }
            }
            if status != 0 {
                let message = String(cString: error)
                // An invalid replacement intentionally leaves the old C overlay
                // intact. Clear it before any conversion can see stale rows.
                guard sumire_session_set_learning_entries(session, nil, 0, &error, error.count) == 0 else {
                    throw NativeError(String(cString: error))
                }
                learningFailure = message
            }
            return learningFailure
        }
        private var englishLoaded = false
        func setPredictionSettings(_ settings: JapanesePredictionSettings) throws {
            guard appliedPredictionSettings != settings else { return }
            guard let session else { throw NativeError("変換セッションがありません") }
            let aggressiveness: UInt32
            switch settings.aggressiveness {
            case .conservative: aggressiveness = 0
            case .standard: aggressiveness = 1
            case .aggressive: aggressiveness = 2
            }
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_session_set_prediction_config(session, UInt32(settings.lookaheadCharacterCount),
                                                         aggressiveness, &error, error.count) == 0 else {
                throw NativeError(String(cString: error))
            }
            appliedPredictionSettings = settings
        }

        func open(sources: [NativeDictionaryEngineSource], mask: UInt32, english: Bool, englishReading: Bool, categoryIDs: [String]? = nil) throws {
            let candidates = sources.filter { !rejectedDirectories.contains($0.directory) }
            let requestedDirectory = candidates.first?.directory
            let sameConfiguration = session != nil && openedDirectory == requestedDirectory &&
                openedMask == mask && openedEnglishReading == englishReading && openedCategoryIDs == categoryIDs
            if sameConfiguration && (!english || englishLoaded) { return }
            if session != nil { close() }
            let opened = try NativeDictionaryEngineOpener.open(sources: candidates, mask: mask,
                english: english, englishReading: englishReading, rejecting: &rejectedDirectories, categoryIDs: categoryIDs)
            defer { sumire_engine_close(opened.engine) }
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_session_create(opened.engine, &session, &error, error.count) == 0 else {
                throw NativeError(String(cString: error))
            }
            standaloneAvailable = sumire_engine_has_standalone_priority(opened.engine) != 0
            do {
                try installPersonal()
                unavailableCategoryIDs = opened.unavailableCategoryIDs
                openedDirectory = opened.directory
                openedMask = mask
                openedCategoryIDs = categoryIDs
                openedEnglishReading = englishReading
                englishLoaded = english
            } catch { close(); throw error }
        }
        private func installPersonal() throws {
            try personal.validate()
            let entries = personal.words + personal.templates
            var bytes: [CChar] = []
            var ranges: [(Int, Int, Int, Int)] = []
            for entry in entries {
                let reading = entry.reading.utf8.map { CChar(bitPattern: $0) }
                let text = entry.word.utf8.map { CChar(bitPattern: $0) }
                let start = bytes.count
                bytes.append(contentsOf: reading)
                bytes.append(contentsOf: text)
                ranges.append((start, reading.count, start + reading.count, text.count))
            }
            var error = [CChar](repeating: 0, count: 1024)
            let status = bytes.withUnsafeBufferPointer { buffer in
                let records = entries.enumerated().map { index, entry in
                    let range = ranges[index]
                    return sumire_personal_entry(
                        reading: sumire_string(data: buffer.baseAddress?.advanced(by: range.0), size: range.1),
                        text: sumire_string(data: buffer.baseAddress?.advanced(by: range.2), size: range.3),
                        context_id: index < personal.words.count ? UInt32(sumire_context_id_for_pos(Int32(entry.posIndex))) : 0,
                        score: Int32(entry.posScore), kind: index < personal.words.count ? 0 : 1)
                }
                return records.withUnsafeBufferPointer {
                    sumire_session_set_personal(session, $0.baseAddress, $0.count, &error, error.count)
                }
            }
            guard status == 0 else { throw NativeError(String(cString: error)) }
        }
        func close() {
            sumire_session_destroy(session)
            session = nil
            lastReading = ""
            lastGeneration = nil
            lastCandidateOrder = []
            lastCandidates.removeAll(keepingCapacity: false)
            standaloneAvailable = false
            englishLoaded = false
            openedDirectory = nil
            unavailableCategoryIDs = []
            openedMask = nil
            openedCategoryIDs = nil
            openedEnglishReading = nil
            appliedPredictionSettings = nil
        }
        deinit { close() }
    }
}

/// Process-level accounting, not dictionary mapped bytes or device RAM usage.
/// The kernel peak is lifetime-wide; it cannot be attributed to one conversion.
enum ProcessMemory {
    struct Sample {
        let footprintBytes: UInt64
        let lifetimePeakBytes: UInt64
    }
    static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Sample(footprintBytes: info.phys_footprint,
                      lifetimePeakBytes: UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
    #if SUMIRE_MEMORY_DIAGNOSTICS
    // Diagnostic builds only; bounded local file, no reading or candidate content.
    private struct Record: Encodable {
        let phase: String
        let uptime: Double
        let pid: Int32
        let footprint_bytes: UInt64
        let lifetime_peak_bytes: UInt64
    }
    private static let diagnosticQueue = DispatchQueue(label: "sumire.memory.diagnostics")
    private static var recordsWritten = 0 // Confined to diagnosticQueue.
    #endif
    static func record(_ phase: String) {
        #if SUMIRE_MEMORY_DIAGNOSTICS
        guard let value = sample() else { return }
        let record = Record(phase: phase, uptime: ProcessInfo.processInfo.systemUptime,
                            pid: ProcessInfo.processInfo.processIdentifier,
                            footprint_bytes: value.footprintBytes, lifetime_peak_bytes: value.lifetimePeakBytes)
        diagnosticQueue.async {
            do {
                let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("sumire-memory.jsonl")
                if recordsWritten % 2048 == 0 { try Data().write(to: url, options: .atomic) }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                var data = try JSONEncoder().encode(record); data.append(10)
                try file.write(contentsOf: data)
                recordsWritten += 1
            } catch {
                Logger(subsystem: "com.kazumaproject.sumire.memory", category: "process").error("Memory diagnostics write failed")
            }
        }
        Logger(subsystem: "com.kazumaproject.sumire.memory", category: "process").notice(
            "phase=\(phase, privacy: .public) footprint_bytes=\(value.footprintBytes) lifetime_peak_bytes=\(value.lifetimePeakBytes)")
        #endif
    }
}
