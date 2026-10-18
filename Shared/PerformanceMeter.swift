import Foundation
import os
import Darwin

/// No input text is recorded. Samples are local, bounded, and process-specific.
final class PerformanceMeter {
    struct Summary {
        let count: Int
        let p50: Double
        let p95: Double
        let maximum: Double
        let footprintMiB: Double
    }
    static let shared = PerformanceMeter()
    private let lock = NSLock()
    private var samples: [Double] = []
    private let log = OSLog(subsystem: "com.kazumaproject.sumire", category: .pointsOfInterest)

    func measure<T>(_ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Input processing", signpostID: id)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            lock.lock()
            if samples.count >= 1024 { samples.removeFirst() }
            samples.append(elapsed)
            lock.unlock()
            os_signpost(.end, log: log, name: "Input processing", signpostID: id)
        }
        return try body()
    }
    func summary() -> Summary {
        lock.lock()
        let sorted = samples.sorted()
        lock.unlock()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))]
        }
        return Summary(count: sorted.count, p50: percentile(0.5), p95: percentile(0.95), maximum: sorted.last ?? 0, footprintMiB: Self.footprint())
    }
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
