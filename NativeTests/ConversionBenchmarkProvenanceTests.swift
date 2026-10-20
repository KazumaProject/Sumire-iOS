import XCTest
import CryptoKit

final class ConversionBenchmarkProvenanceTests: XCTestCase {
    func testNestedScoringFilesAreHashedAndMismatchRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mozc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3])
        let path = "mozc/segmenter.dat"
        try payload.write(to: root.appendingPathComponent(path))
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = try JSONSerialization.data(withJSONObject: ["output_sha256": [path: digest]])
        try manifest.write(to: root.appendingPathComponent("manifest.json"))
        let value = try ConversionBenchmarkProvenance.collect(directory: root)
        XCTAssertEqual((value["dictionary_file_sha256"] as? [String: String])?[path], digest)
        XCTAssertEqual((value["dictionary_file_bytes"] as? [String: UInt64])?[path], 3)
        try Data([9]).write(to: root.appendingPathComponent(path))
        XCTAssertThrowsError(try ConversionBenchmarkProvenance.collect(directory: root))
    }

    func testManifestTraversalAndEscapingSymlinkAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside.dat", "/absolute.dat", "mozc//segmenter.dat", "mozc/./segmenter.dat", "mozc\\segmenter.dat"] {
            let manifest = try JSONSerialization.data(withJSONObject: ["output_sha256": [path: String(repeating: "0", count: 64)]])
            try manifest.write(to: root.appendingPathComponent("manifest.json"))
            XCTAssertThrowsError(try ConversionBenchmarkProvenance.collect(directory: root), path)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        let manifest = try JSONSerialization.data(withJSONObject: ["output_sha256": ["escape/outside.dat": String(repeating: "0", count: 64)]])
        try manifest.write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ConversionBenchmarkProvenance.collect(directory: root))
    }
}
