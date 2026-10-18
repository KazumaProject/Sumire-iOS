import XCTest

/// Containing-app measurements of the production Swift service. These tests do
/// not establish extension footprint, cold OS pages, or touch-to-frame latency.
final class ConversionServicePerformanceTests: XCTestCase {
    func testReleaseServiceAllDictionariesBunsetsuOff() throws { try run(includeBunsetsu: false) }
    func testReleaseServiceAllDictionariesBunsetsuOn() throws { try run(includeBunsetsu: true) }

    private func run(includeBunsetsu: Bool) throws {
        #if DEBUG
        throw XCTSkip("Run this benchmark with -configuration Release")
        #else
        let directory = try XCTUnwrap(ConversionService.bundledDictionary)
        let provenance = try ConversionBenchmarkProvenance.collect(directory: directory)
        let service = ConversionService(directory: directory, categoryMask: 0x3fff_ffff)
        let cases: [(String, Bool, Bool)] = [
            ("あ", false, false), ("あい", false, false), ("にほんご", false, false),
            ("とうきょうえき", false, false), ("きょうはいいてんきですね", false, false),
            (String(repeating: "あ", count: 32), false, false),
            ("かつこう", true, false), ("とうきよう", true, false),
            ("a", false, true), ("hel", false, true), ("iph", false, true), ("computer", false, true)]
        let warmups = 24, trials = 240
        var generation: UInt64 = 0
        func sample(_ reading: String, omission: Bool, english: Bool) throws -> [String: Any] {
            generation += 1
            let completed = expectation(description: "Service benchmark conversion")
            var values: [String: Any]?
            var failure: Error?
            let start = ProcessInfo.processInfo.systemUptime
            service.convert(reading, generation: generation, editStart: 0, omission: omission,
                            english: english, includeBunsetsu: includeBunsetsu) { response in
                let wall = (ProcessInfo.processInfo.systemUptime - start) * 1000
                do {
                    let result = try response.get()
                    XCTAssertTrue(result.complete)
                    XCTAssertNil(result.warning)
                    let memory = try XCTUnwrap(ProcessMemory.sample())
                    // Retain scalar measurements only. Service itself still owns
                    // the latest candidates as it does in normal keyboard use.
                    values = ["core_ms": result.elapsedMilliseconds, "service_wall_ms": wall,
                              "footprint_mib": Double(memory.footprintBytes) / 1_048_576,
                              "process_lifetime_peak_mib": Double(memory.lifetimePeakBytes) / 1_048_576,
                              "candidate_count": result.candidates.count,
                              "bunsetsu_count": result.candidates.reduce(0) { $0 + $1.bunsetsu.count }]
                } catch { failure = error }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 30)
            if let failure { throw failure }
            return try XCTUnwrap(values)
        }
        // Separate actual lazy-loading states from steady all-33-dictionary calls.
        let initialJapanese = try sample("にほんご", omission: false, english: false)
        let firstEnglish = try sample("hel", omission: false, english: true)
        var samples: [[String: Any]] = []
        for index in 0..<(warmups + trials) {
            let item = cases[index % cases.count]
            var value = try sample(item.0, omission: item.1, english: item.2)
            if index >= warmups {
                value["case"] = index % cases.count
                value["mode"] = item.2 ? "english" : (item.1 ? "omission" : "japanese")
                samples.append(value)
            }
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[Int(ceil(Double(sorted.count) * p)) - 1]
        }
        var groups: [String: Any] = [:]
        for mode in ["japanese", "omission", "english"] {
            let group = samples.filter { $0["mode"] as? String == mode }
            var summary: [String: Any] = ["trials": group.count]
            for metric in ["core_ms", "service_wall_ms", "footprint_mib"] {
                let values = group.map { $0[metric] as! Double }
                summary[metric] = ["p95": percentile(values, 0.95), "p99": percentile(values, 0.99), "max": values.max()!]
            }
            groups[mode] = summary
        }
        let report: [String: Any] = [
            "scope": "Release production ConversionService in containing-app test host, not extension or touch-to-frame",
            "provenance": provenance, "include_bunsetsu": includeBunsetsu,
            "flags": [12, 13, 2], "primary_nbest_limit": 20, "state_limit": 200000,
            "category_mask": "0x3fffffff", "english_reading": true, "learning": false, "personal_entries": 0,
            "steady_dictionary_configuration": "system + 30 categories + English words + English readings (33)",
            "initial_japanese_32_dictionary_sample": initialJapanese,
            "first_english_reopen_33_dictionary_sample": firstEnglish,
            "startup_scope": "Single session-first samples; dictionary files were prehashed, not cold OS cache or startup p95",
            "warmup_calls": warmups, "measured_calls": trials,
            "cases": cases.map { ["reading": $0.0, "utf16_units": $0.0.utf16.count, "omission": $0.1, "english": $0.2] },
            "memory_scope": "Sample at completion with latest candidates retained; includes host/Swift/C++; not continuous peak; lifetime peak spans test process",
            "cache_scope": "No private workspace byte estimate; measure process footprint including Swift metadata",
            "groups": groups, "samples": samples]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = includeBunsetsu ? "release-service-bunsetsu-on.json" : "release-service-bunsetsu-off.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SUMIRE_SERVICE_BENCHMARK bunsetsu=\(includeBunsetsu) groups=\(groups)")
        #endif
    }
}
