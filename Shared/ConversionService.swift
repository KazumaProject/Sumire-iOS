import Foundation
import Darwin
import os
import SumireCore

struct ConversionCandidate {
    let id: UInt64
    let text: String
    let score: Int64
    let range: NSRange
    let dictionaries: [String]
    /// Owned Swift values projected from this candidate's path only. Ranges are
    /// UTF-16 offsets within the consumed reading (currently a prefix at zero).
    let bunsetsu: [BunsetsuSegment]

    init(id: UInt64, text: String, score: Int64, range: NSRange,
         dictionaries: [String], bunsetsu: [BunsetsuSegment] = []) {
        self.id = id
        self.text = text
        self.score = score
        self.range = range
        self.dictionaries = dictionaries
        self.bunsetsu = bunsetsu
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
    private let directory: URL?
    private var englishReadingEnabled = true
    private var categoryMask: UInt32
    private var personal = PersonalLexicon()
    private var learningURL: URL?

    init(directory: URL? = ConversionService.bundledDictionary, categoryMask: UInt32 = 0) {
        self.directory = directory
        self.categoryMask = categoryMask
    }
    static var bundledDictionary: URL? {
        let bundle = Bundle.main.bundleURL
        let locations = ["standard-mozc-scoring-auxiliary-english", "cli-priority-v1", "cli-english-v1"].flatMap { name in
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
    func convert(_ reading: String, generation: UInt64, editStart: Int, omission: Bool = false, english: Bool = false,
                 includeBunsetsu: Bool = false, bunsetsuSearch: Bool = false,
                 completion: @escaping (Result<ConversionResponse, Error>) -> Void) {
        let state = state, directory = directory, mask = categoryMask, englishReading = englishReadingEnabled
        let pending = pending, ticket = pending.advance()
        queue.async {
            guard pending.isCurrent(ticket) else { return }
            ProcessMemory.record("conversion.begin")
            defer { ProcessMemory.record("conversion.end") }
            let response: Result<ConversionResponse, Error>
            do {
                try state.open(directory: directory, mask: mask, english: english, englishReading: englishReading)
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
                    for categoryIndex in 0..<sumire_result_category_count(result, index) {
                        var category = sumire_string()
                        guard sumire_result_category(result, index, categoryIndex, &category) == 0 else {
                            throw NativeError("候補の辞書分類が不正です")
                        }
                        let name = Self.copy(category)
                        if !dictionaries.contains(name) { dictionaries.append(name) }
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
                                                          dictionaries: dictionaries, bunsetsu: bunsetsu))
                }
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
                  learn, state.learningURL != nil, let store = state.learning,
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
        var learning: LearningStore?
        var learningFailure: String?
        var standaloneAvailable = false
        var lastReading = ""
        var lastCandidates: [UInt64: ConversionCandidate] = [:]
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
        func open(directory: URL?, mask: UInt32, english: Bool, englishReading: Bool) throws {
            if session != nil && (!english || englishLoaded) { return }
            if session != nil { close() }
            guard let directory else { throw NativeError("変換辞書が見つかりません。読みは保持しています") }
            var engine: OpaquePointer?
            var error = [CChar](repeating: 0, count: 1024)
            guard sumire_engine_open_with_dictionaries(directory.path, mask, (english ? 1 : 0) | (englishReading ? 2 : 0), &engine, &error, error.count) == 0, let engine else {
                throw NativeError(String(cString: error))
            }
            standaloneAvailable = sumire_engine_has_standalone_priority(engine) != 0
            defer { sumire_engine_close(engine) }
            guard sumire_session_create(engine, &session, &error, error.count) == 0 else { throw NativeError(String(cString: error)) }
            do { try installPersonal(); englishLoaded = english } catch { close(); throw error }
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
            englishLoaded = false
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
