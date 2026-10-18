import XCTest
@testable import SumireCore

final class MaterialContentColorsTests: XCTestCase {
    private struct Oracle: Decodable {
        let oracle: String
        let sourceJarSHA256: String
        let roles: [String]
        let cases: [Case]
        struct Case: Decodable {
            let seed: String
            let dark: Bool
            let contrast: Double
            let argb: [String]
        }
    }

    func testExactARGBMatchesAndroidMaterial113JavaOracle() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MaterialContentJava113", withExtension: "json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        XCTAssertEqual(oracle.oracle, "com.google.android.material:material:1.13.0")
        XCTAssertEqual(oracle.sourceJarSHA256, "7b8a89701918165bfa45e9137e07192c02ac85a8d52bbf16b3dec0c329a76045")
        XCTAssertEqual(oracle.roles, ["surface", "surfaceContainer", "surfaceContainerLow", "surfaceContainerHigh",
                                     "surfaceContainerHighest", "surfaceVariant", "onSurface", "secondaryContainer",
                                     "onSecondaryContainer", "primary", "onPrimary"])
        XCTAssertEqual(oracle.cases.count, 128)
        for item in oracle.cases {
            let seed = try XCTUnwrap(UInt32(item.seed, radix: 16))
            let colors = MaterialContentColors.resolve(seedARGB: seed, dark: item.dark, contrastLevel: item.contrast)
            let actual = [colors.surface, colors.surfaceContainer, colors.surfaceContainerLow,
                          colors.surfaceContainerHigh, colors.surfaceContainerHighest, colors.surfaceVariant,
                          colors.onSurface, colors.secondaryContainer, colors.onSecondaryContainer, colors.primary, colors.onPrimary]
            XCTAssertEqual(actual, item.argb.compactMap { UInt32($0, radix: 16) },
                           "seed=\(item.seed) dark=\(item.dark) contrast=\(item.contrast)")
        }
    }

    func testCacheAndContrastNormalizationAreStableAcrossConcurrentClients() {
        let expected = MaterialContentColors.resolve(seedARGB: 0xff67_50a4, dark: false)
        XCTAssertEqual(MaterialContentColors.resolve(seedARGB: 0x0067_50a4, dark: false, contrastLevel: .nan), expected)
        XCTAssertEqual(MaterialContentColors.resolve(seedARGB: 0xff67_50a4, dark: false, contrastLevel: 10),
                       MaterialContentColors.resolve(seedARGB: 0xff67_50a4, dark: false, contrastLevel: 1))
        // Exercise bounded-cache eviction while multiple clients request themes.
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            _ = MaterialContentColors.resolve(seedARGB: UInt32(index * 31337), dark: index % 2 == 0)
            XCTAssertEqual(MaterialContentColors.resolve(seedARGB: 0xff67_50a4, dark: false), expected)
        }
    }

    func testPinnedVendorNoticesAreBundledAndReadableOffline() throws {
        let notice = try String(contentsOf: XCTUnwrap(MaterialColorUtilitiesNotice.attributionURL), encoding: .utf8)
        let license = try String(contentsOf: XCTUnwrap(MaterialColorUtilitiesNotice.licenseURL), encoding: .utf8)
        XCTAssertTrue(notice.contains("dd62982dfdefdfc9232ce8d76e122fb1c6d188ae"))
        XCTAssertTrue(notice.contains("unmodified"))
        XCTAssertTrue(license.contains("Apache License"))
        XCTAssertTrue(license.contains("Version 2.0"))
    }
}
