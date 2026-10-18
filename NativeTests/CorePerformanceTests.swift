import XCTest
import Darwin
import CryptoKit

final class CorePerformanceTests: XCTestCase {
    func testUnicodeEnglishUppercaseWithBundledDictionary() throws {
        let directory = Bundle.main.bundleURL.appendingPathComponent("PlugIns/SumireKeyboard.appex/cli-english-v1")
        var error = [CChar](repeating: 0, count: 1024)
        var engine: OpaquePointer?
        XCTAssertEqual(sumire_engine_open_with_dictionaries(directory.path, 0, 1, &engine, &error, error.count), 0, String(cString: error))
        guard let engine else { return }
        defer { sumire_engine_close(engine) }
        var session: OpaquePointer?
        XCTAssertEqual(sumire_session_create(engine, &session, &error, error.count), 0)
        guard let session else { return }
        defer { sumire_session_destroy(session) }
        var result: OpaquePointer?
        let status = "POKÉ".utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
            var request = sumire_request(generation: 1, reading: bytes.baseAddress,
                reading_bytes: bytes.count - 1, edit_start_utf16: 0,
                candidate_count: 20, max_states: 200000, flags: 2)
            return sumire_session_update(session, &request, &result, &error, error.count)
        }
        XCTAssertEqual(status, 0, String(cString: error))
        guard let result else { return }
        defer { sumire_result_destroy(result) }
        var surfaces: [String] = []
        for index in 0..<sumire_result_count(result) {
            var candidate = sumire_candidate()
            XCTAssertEqual(sumire_result_candidate(result, index, &candidate), 0)
            XCTAssertEqual(candidate.length_utf16, 4)
            let bytes = UnsafeRawPointer(candidate.text.data!).assumingMemoryBound(to: UInt8.self)
            surfaces.append(String(decoding: UnsafeBufferPointer(start: bytes, count: candidate.text.size), as: UTF8.self))
        }
        XCTAssertTrue(surfaces.contains("POKÉMON"), "\(surfaces)")
        XCTAssertFalse(surfaces.contains("POKéMON"))
        for (index, input) in ["É", "é", "ß", "ᾀ"].enumerated() {
            var fallback: OpaquePointer?
            let status = input.utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
                var request = sumire_request(generation: UInt64(index + 2), reading: bytes.baseAddress,
                    reading_bytes: bytes.count - 1, edit_start_utf16: 0,
                    candidate_count: 20, max_states: 200000, flags: 2)
                return sumire_session_update(session, &request, &fallback, &error, error.count)
            }
            XCTAssertEqual(status, 0, String(cString: error))
            guard let fallback else { return }
            defer { sumire_result_destroy(fallback) }
            let expected = [["É", "É", "É"], ["é", "É", "É"], ["ß", "ß", "SS"], ["ᾀ", "ᾈ", "ἈΙ"]][index]
            XCTAssertEqual(sumire_result_count(fallback), expected.count)
            for item in 0..<expected.count {
                var candidate = sumire_candidate()
                XCTAssertEqual(sumire_result_candidate(fallback, item, &candidate), 0)
                let bytes = UnsafeRawPointer(candidate.text.data!).assumingMemoryBound(to: UInt8.self)
                XCTAssertEqual(String(decoding: UnsafeBufferPointer(start: bytes, count: candidate.text.size), as: UTF8.self), expected[item])
                XCTAssertEqual(candidate.length_utf16, 1)
                if index == 0 && item == 0 { XCTAssertEqual(candidate.score, 8500) }
            }
        }
    }

    func testReleaseDictionaryLifecycleFootprint() throws {
        #if DEBUG
        throw XCTSkip("Run this benchmark with -configuration Release")
        #else
        let directory = Bundle.main.bundleURL.appendingPathComponent("PlugIns/SumireKeyboard.appex/cli-english-v1")
        var cycles: [[String: Any]] = []
        let baseline = try footprint()
        for cycle in 0..<10 {
            var error = [CChar](repeating: 0, count: 1024)
            var engine: OpaquePointer?
            XCTAssertEqual(sumire_engine_open_with_dictionaries(directory.path, 0x3fff_ffff, 3, &engine, &error, error.count), 0, String(cString: error))
            guard let engine else { return }
            var session: OpaquePointer?
            let opened = try footprint()
            let created = sumire_session_create(engine, &session, &error, error.count)
            // Session retains the mappings independently of the public engine handle.
            sumire_engine_close(engine)
            XCTAssertEqual(created, 0, String(cString: error))
            guard let session else { return }
            var result: OpaquePointer?
            let status = "とうきょうえき".utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
                var request = sumire_request(generation: 1, reading: bytes.baseAddress,
                    reading_bytes: bytes.count - 1, edit_start_utf16: 0,
                    candidate_count: 20, max_states: 200000, flags: 12)
                return sumire_session_update(session, &request, &result, &error, error.count)
            }
            XCTAssertEqual(status, 0, String(cString: error))
            let converted = try footprint()
            let cacheBeforePurge = sumire_session_cache_bytes(session)
            sumire_session_purge_cache(session)
            XCTAssertEqual(sumire_session_cache_bytes(session), 0)
            sumire_session_destroy(session)
            guard let result else { return }
            // Results own their strings even after the session and mappings close.
            var candidate = sumire_candidate()
            XCTAssertEqual(sumire_result_candidate(result, 0, &candidate), 0)
            XCTAssertGreaterThan(candidate.text.size, 0)
            sumire_result_destroy(result)
            cycles.append(["cycle": cycle, "opened_mib": opened, "converted_mib": converted,
                           "closed_mib": try footprint(), "cache_before_purge_bytes": cacheBeforePurge])
        }
        let report: [String: Any] = [
            "scope": "Release C ABI containing-app test host; sampled lifecycle memory, not extension memory",
            "baseline_mib": baseline, "cycles": cycles, "conversion_flags": 12,
            "provenance": try ConversionBenchmarkProvenance.collect(directory: directory),
            "dictionary_configuration": "system + 30 categories + English words + English readings",
            "note": "Allocator retention and host activity may affect closed footprint; no OS peak or leak claim"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "release-dictionary-lifecycle.json"; attachment.lifetime = .keepAlways
        add(attachment)
        print("SUMIRE_DICTIONARY_LIFECYCLE baseline_mib=\(baseline) cycles=\(cycles)")
        #endif
    }

    func testReleaseCoreWithAllDictionaries() throws {
        try runReleaseCoreWithAllDictionaries(prediction: true)
    }

    func testReleaseCoreLegacyOptionsWithAllDictionaries() throws {
        try runReleaseCoreWithAllDictionaries(prediction: false)
    }

    private func runReleaseCoreWithAllDictionaries(prediction: Bool) throws {
        #if DEBUG
        throw XCTSkip("Run this benchmark with -configuration Release")
        #else
        let directory = Bundle.main.bundleURL.appendingPathComponent("PlugIns/SumireKeyboard.appex/cli-english-v1")
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let provenance = try ConversionBenchmarkProvenance.collect(directory: directory)
        let japaneseFlags: UInt32 = prediction ? 12 : 4
        let omissionFlags: UInt32 = japaneseFlags | 1
        var error = [CChar](repeating: 0, count: 1024)
        var engine: OpaquePointer?
        let start = ProcessInfo.processInfo.systemUptime
        let opened = sumire_engine_open_with_dictionaries(directory.path, 0x3fff_ffff, 3, &engine, &error, error.count)
        XCTAssertEqual(opened, 0, String(cString: error))
        guard let engine else { return }
        defer { sumire_engine_close(engine) }
        let openMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var session: OpaquePointer?
        XCTAssertEqual(sumire_session_create(engine, &session, &error, error.count), 0)
        guard let session else { return }
        defer { sumire_session_destroy(session) }
        let cases: [(String, UInt32)] = [
            ("あ", japaneseFlags), ("あい", japaneseFlags), ("にほんご", japaneseFlags), ("とうきょうえき", japaneseFlags),
            ("きょうはいいてんきですね", japaneseFlags), (String(repeating: "あ", count: 32), japaneseFlags),
            ("かつこう", omissionFlags), ("とうきよう", omissionFlags),
            ("a", 2), ("hel", 2), ("iph", 2), ("computer", 2)
        ]
        let warmups = 24, trials = 240
        var samples: [[String: Any]] = []
        var measuredFootprints: [Double] = []
        for index in 0..<(warmups + trials) {
            let item = cases[index % cases.count]
            var result: OpaquePointer?
            let wallStart = ProcessInfo.processInfo.systemUptime
            let status = item.0.utf8CString.withUnsafeBufferPointer { bytes -> Int32 in
                var request = sumire_request(generation: UInt64(index + 1), reading: bytes.baseAddress,
                    reading_bytes: bytes.count - 1, edit_start_utf16: 0,
                    candidate_count: 20, max_states: 200000, flags: item.1)
                return sumire_session_update(session, &request, &result, &error, error.count)
            }
            let wall = (ProcessInfo.processInfo.systemUptime - wallStart) * 1000
            XCTAssertEqual(status, 0, String(cString: error))
            guard let result else { return }
            var metrics = sumire_metrics()
            XCTAssertEqual(sumire_result_metrics(result, &metrics), 0)
            XCTAssertEqual(metrics.complete, 1, "Incomplete search: \(item.0)")
            if index >= warmups {
                let memory = try footprint()
                measuredFootprints.append(memory)
                samples.append(["case": index % cases.count, "core_ms": metrics.conversion_ms,
                                "c_abi_wall_ms": wall, "footprint_mib": memory,
                                "candidate_count": sumire_result_count(result),
                                "cache_bytes": sumire_session_cache_bytes(session)])
            }
            sumire_result_destroy(result)
        }
        func quantile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[Int(ceil(Double(sorted.count) * p)) - 1]
        }
        var groups: [String: Any] = [:]
        for (name, flags) in [("japanese", japaneseFlags), ("omission", omissionFlags), ("english", 2)] {
            let values = samples.filter { cases[$0["case"] as! Int].1 == flags }.map { $0["core_ms"] as! Double }
            groups[name] = ["trials": values.count, "p95_ms": quantile(values, 0.95), "p99_ms": quantile(values, 0.99)]
        }
        let report: [String: Any] = [
            "scope": "Release C ABI in containing-app test host; not keyboard extension or touch-to-frame",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "provenance": provenance, "japanese_prediction": prediction,
            "primary_nbest_limit": 20, "state_limit": 200000,
            "swift_bunsetsu_projection": false, "category_mask": "0x3fffffff", "dictionary_flags": 3,
            "cache_scope": "Retained C++ workspace capacity only; excludes results, Swift objects, mappings and temporary prediction storage",
            "warmup_calls": warmups, "measured_calls": trials, "engine_open_ms_single_sample": openMilliseconds,
            "dictionary_manifest": try JSONSerialization.jsonObject(with: manifest),
            "cases": cases.map { ["reading": $0.0, "flags": $0.1, "utf16_units": $0.0.utf16.count] },
            "groups": groups, "sampled_max_footprint_mib": measuredFootprints.max()!,
            "process_lifetime_peak_mib": Double(try XCTUnwrap(ProcessMemory.sample()).lifetimePeakBytes) / 1_048_576,
            "memory_scope": "Sampled after each update while result is retained; not continuous peak measurement",
            "samples": samples
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = prediction ? "release-core-prediction-all-dictionaries.json" : "release-core-legacy-options-all-dictionaries.json"; attachment.lifetime = .keepAlways
        add(attachment)
        print("SUMIRE_CORE_CACHE max_bytes=\(samples.compactMap { $0["cache_bytes"] as? Int }.max() ?? 0)")
        print("SUMIRE_CORE_BENCHMARK \(groups) sampled_max_footprint_mib=\(measuredFootprints.max()!) lifetime_peak_mib=\(Double(try XCTUnwrap(ProcessMemory.sample()).lifetimePeakBytes) / 1_048_576)")
        #endif
    }

    private func footprint() throws -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: "task_info", code: Int(status)) }
        return Double(info.phys_footprint) / 1_048_576
    }
}


/// Hashing deliberately precedes timing: these are warm-file-cache benchmarks,
/// never claims about OS cold pages, extension startup or touch-to-frame time.
enum ConversionBenchmarkProvenance {
    static func collect(directory: URL) throws -> [String: Any] {
        let revision = Bundle.main.object(forInfoDictionaryKey: "SumireBenchmarkRevision") as? String ?? ""
        guard revision.count == 40 else {
            throw NSError(domain: "SumireBenchmark", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Build with INFOPLIST_KEY_SumireBenchmarkRevision=<40-character source commit>"])
        }
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sud" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var hashes: [String: String] = [:]
        var sizes: [String: UInt64] = [:]
        for file in files {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            var size: UInt64 = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hash.update(data: data)
                size += UInt64(data.count)
            }
            hashes[file.lastPathComponent] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            sizes[file.lastPathComponent] = size
        }
        return ["source_revision": revision,
                "dictionary_manifest": try JSONSerialization.jsonObject(with: manifest),
                "manifest_sha256": SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined(),
                "dictionary_file_sha256": hashes, "dictionary_file_bytes": sizes,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "file_cache_condition": "All dictionary files hashed before measured setup; OS cache not cold",
                "configuration": "Release", "network": "No network operations"]
    }
}
