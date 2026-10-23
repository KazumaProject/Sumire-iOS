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
        let labels = Self.categoryLabels.filter { classifiedCategories.contains($0.0) }.map(\.1)
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
                presentationKind: first.presentationKind, classifiedCategories: categories)
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
         presentationKind: PresentationKind = .none, classifiedCategories: [String] = []) {
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
    }
}
struct ConversionResponse {
    let generation: UInt64
    let candidates: [ConversionCandidate]
    let elapsedMilliseconds: Double
    let complete: Bool
    let warning: String?
}

/// All native handles are confined to this queue. Results are copied to Swift
/// before the C snapshot is released; the main thread never observes C pointers.
final class ConversionService {
    private let queue = DispatchQueue(label: "sumire.conversion", qos: .userInitiated)
    private let state = NativeState()
    private let pending = PendingRequest()
    private let directoryOverride: URL?
    private var cachedDictionaryDirectories: [URL]?
    private var lastDictionaryRefresh = 0.0
    private var englishReadingEnabled = true
    private var categoryMask: UInt32
    private var personal = PersonalLexicon()
    private var learningURL: URL?

    init(categoryMask: UInt32 = 0) {
        self.directoryOverride = nil
        self.categoryMask = categoryMask
    }
    init(directory: URL?, categoryMask: UInt32 = 0) {
        self.directoryOverride = directory
        self.categoryMask = categoryMask
    }
    private static var activeDictionaries: [URL] {
        var directories = PersonalDataLocation.readableDictionaryGenerations().map(\.directory)
        if let bundledDictionary, !directories.contains(bundledDictionary) {
            directories.append(bundledDictionary)
        }
        return directories
    }
    // Called only on the serial conversion queue. Avoid resolving App Group
    // metadata on the keyboard's main thread for every keystroke.
    private func resolveActiveDictionaries() -> [URL] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDictionaryRefresh < 0.5 { return cachedDictionaryDirectories ?? [] }
        lastDictionaryRefresh = now
        cachedDictionaryDirectories = Self.activeDictionaries
        return cachedDictionaryDirectories ?? []
    }
    static var bundledDictionary: URL? {
        let bundle = Bundle.main.bundleURL
        let locations = ["standard-mozc-scoring-auxiliary-correction-english", "standard-mozc-scoring-auxiliary-english", "cli-priority-v1", "cli-english-v1"].flatMap { name in
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
            state.learning = nil; state.learningURL = nil; state.learningFailure = nil
            do {
                try localReset?.apply()
                state.learningURL = url
            } catch { state.learningFailure = "学習データの削除を再試行します: " + error.localizedDescription }
        }
    }
    func setLearningPaused(_ paused: Bool) {
        let state = state
        queue.async { state.learningPaused = paused }
    }
    func convert(_ reading: String, generation: UInt64, editStart: Int, omission: Bool = false, english: Bool = false,
                 includeBunsetsu: Bool = false, bunsetsuSearch: Bool = false,
                 completion: @escaping (Result<ConversionResponse, Error>) -> Void) {
        let state = state, directoryOverride = directoryOverride
        let mask = categoryMask, englishReading = englishReadingEnabled
        let pending = pending, ticket = pending.advance()
        queue.async {
            guard pending.isCurrent(ticket) else { return }
            let directories = directoryOverride.map { [$0] } ?? self.resolveActiveDictionaries()
            ProcessMemory.record("conversion.begin")
            defer { ProcessMemory.record("conversion.end") }
            let response: Result<ConversionResponse, Error>
            do {
                try state.open(directories: directories, mask: mask, english: english, englishReading: englishReading)
                let warnings = [try state.prepareLearning(reading: reading),
                    !english && !state.standaloneAvailable ? "優先候補辞書がありません。新しい辞書世代への更新が必要です" : nil].compactMap { $0 }
                let warning = warnings.isEmpty ? nil : warnings.joined(separator: " / ")
                var error = [CChar](repeating: 0, count: 1024)
                var result: OpaquePointer?
                let flags: UInt32
                if english { flags = 2 }
                else { flags = (omission ? 1 : 0) | (bunsetsuSearch ? 16 : 12) }
                let status = reading.utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
                    var request = sumire_request(generation: generation, reading: bytes.baseAddress,
                                                 reading_bytes: bytes.count - 1,
                                                 edit_start_utf16: UInt32(max(0, editStart)),
                                                 candidate_count: 20, max_states: 200_000, flags: flags)
                    return sumire_session_update(state.session, &request, &result, &error, error.count)
                }
                guard status == 0, let result else { throw NativeError(String(cString: error)) }
                defer { sumire_result_destroy(result) }
                var metrics = sumire_metrics()
                guard sumire_result_metrics(result, &metrics) == 0 else { throw NativeError("変換結果の計測情報が不正です") }
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
                    for segmentIndex in 0..<candidate.segment_count {
                        var segment = sumire_segment()
                        guard sumire_result_segment(result, index, segmentIndex, &segment) == 0 else { throw NativeError("候補範囲が不正です") }
                        if includeBunsetsu || bunsetsuSearch {
                            tokens.append(BunsetsuToken(
                                readingRange: NSRange(location: Int(segment.start_utf16), length: Int(segment.length_utf16)),
                                text: Self.copy(segment.text)))
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
                                                          classifiedCategories: classifiedCategories))
                }
                candidates = ConversionCandidate.mergedForDisplay(candidates)
                state.lastReading = reading
                state.lastCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
                response = .success(ConversionResponse(generation: metrics.generation, candidates: candidates,
                                                       elapsedMilliseconds: metrics.conversion_ms, complete: metrics.complete != 0, warning: warning))
            } catch { response = .failure(error) }
            DispatchQueue.main.async { completion(response) }
        }
    }
    func commit(generation: UInt64, candidate: UInt64, learn: Bool, onNotice: @escaping (String) -> Void) {
        let state = state
        queue.async {
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_session_commit(state.session, generation, candidate, &error, error.count) == 0,
                  learn, !state.learningPaused, state.learningURL != nil, let store = state.learning,
                  let selected = state.lastCandidates[candidate],
                  let range = Range(selected.range, in: state.lastReading) else { return }
            do {
                try store.record(reading: String(state.lastReading[range]), text: selected.text)
                DispatchQueue.main.async { onNotice("学習しました") }
            }
            catch { let message = error.localizedDescription; DispatchQueue.main.async { onNotice(message) } }
        }
    }
    func reset() {
        _ = pending.advance()
        let state = state
        queue.async {
            sumire_session_reset(state.session)
            state.lastReading = ""
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
        var learning: LearningStore?
        var learningFailure: String?
        var standaloneAvailable = false
        var lastReading = ""
        var lastCandidates: [UInt64: ConversionCandidate] = [:]
        private var openedDirectory: URL?
        // Generations are immutable. Once a native open rejects one, skip it for
        // this process and try the previous pointer or bundled baseline.
        private var rejectedDirectories = Set<URL>()
        private var openedMask: UInt32?
        private var openedEnglishReading: Bool?
        func prepareLearning(reading: String) throws -> String? {
            var entries: [LearningStore.Entry] = []
            if let url = learningURL, learningFailure == nil {
                do {
                    if learning == nil { learning = try LearningStore(url: url) }
                    entries = try learning!.candidates(reading: reading)
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
            let status = bytes.withUnsafeBufferPointer { buffer in
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
            guard status == 0 else { throw NativeError(String(cString: error)) }
            return learningFailure
        }
        private var englishLoaded = false
        func open(directories: [URL], mask: UInt32, english: Bool, englishReading: Bool) throws {
            let candidates = directories.map(\.standardizedFileURL).filter { !rejectedDirectories.contains($0) }
            let requestedDirectory = candidates.first
            let sameConfiguration = session != nil && openedDirectory == requestedDirectory &&
                openedMask == mask && openedEnglishReading == englishReading
            if sameConfiguration && (!english || englishLoaded) { return }
            if session != nil { close() }
            let opened = try NativeDictionaryEngineOpener.open(directories: candidates, mask: mask,
                english: english, englishReading: englishReading, rejecting: &rejectedDirectories)
            defer { sumire_engine_close(opened.engine) }
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_session_create(opened.engine, &session, &error, error.count) == 0 else {
                throw NativeError(String(cString: error))
            }
            standaloneAvailable = sumire_engine_has_standalone_priority(opened.engine) != 0
            do {
                try installPersonal()
                openedDirectory = opened.directory
                openedMask = mask
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
            lastCandidates.removeAll(keepingCapacity: false)
            standaloneAvailable = false
            englishLoaded = false
            openedDirectory = nil
            openedMask = nil
            openedEnglishReading = nil
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
