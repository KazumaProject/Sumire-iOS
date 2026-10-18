import XCTest
@testable import SumireCore

final class ReadOnlySettingsDefaultsTests: XCTestCase {
    func testAllReaderPathsUseOnlySnapshotAndMutationsNeverForward() {
        let snapshot = ReadOnlySettingsDefaults()
        let unrelatedName = "SnapshotIsolationTests." + UUID().uuidString
        let unrelated = UserDefaults(suiteName: unrelatedName)!
        defer { unrelated.removePersistentDomain(forName: unrelatedName) }
        unrelated.set("original", forKey: "isolation")
        let registration = unrelated.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary
        let url = URL(fileURLWithPath: "/tmp/snapshot-fixture")
        let fixture: [String: Any] = ["string": "abc", "number": 12, "decimal": 1.25,
            "truth": true, "numericString": "17", "boolString": "YES", "data": Data([1, 2]),
            "array": [1, 2], "strings": ["a", "b"], "dictionary": ["a": 2], "url": url]
        snapshot.replace(with: fixture)
        XCTAssertEqual(snapshot.string(forKey: "string"), "abc")
        XCTAssertEqual(snapshot.string(forKey: "number"), "12")
        XCTAssertEqual(snapshot.integer(forKey: "number"), 12)
        XCTAssertEqual(snapshot.integer(forKey: "numericString"), 17)
        XCTAssertEqual(snapshot.double(forKey: "decimal"), 1.25)
        XCTAssertEqual(snapshot.float(forKey: "decimal"), 1.25)
        XCTAssertTrue(snapshot.bool(forKey: "truth"))
        XCTAssertTrue(snapshot.bool(forKey: "boolString"))
        XCTAssertEqual(snapshot.data(forKey: "data"), Data([1, 2]))
        XCTAssertEqual(snapshot.array(forKey: "array") as? [Int], [1, 2])
        XCTAssertEqual(snapshot.stringArray(forKey: "strings"), ["a", "b"])
        XCTAssertEqual(snapshot.dictionary(forKey: "dictionary") as? [String: Int], ["a": 2])
        XCTAssertEqual(snapshot.url(forKey: "url"), url)
        XCTAssertEqual(snapshot.value(forKey: "string") as? String, "abc")
        XCTAssertNil(snapshot.object(forKey: "isolation"))
        XCTAssertEqual(snapshot.integer(forKey: "missing"), 0)
        XCTAssertFalse(snapshot.bool(forKey: "missing"))
        snapshot.set("new", forKey: "string")
        snapshot.set(2, forKey: "number")
        snapshot.set(Float(2), forKey: "decimal")
        snapshot.set(Double(3), forKey: "decimal")
        snapshot.set(false, forKey: "truth")
        snapshot.set(URL(fileURLWithPath: "/tmp/other"), forKey: "url")
        snapshot.setValue("new", forKey: "string")
        snapshot.removeObject(forKey: "string")
        snapshot.register(defaults: ["isolation": "polluted"])
        snapshot.setPersistentDomain(["isolation": "polluted"], forName: unrelatedName)
        snapshot.removePersistentDomain(forName: unrelatedName)
        snapshot.setVolatileDomain(["isolation": "polluted"], forName: UserDefaults.registrationDomain)
        snapshot.removeVolatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertTrue(snapshot.synchronize())
        XCTAssertEqual(snapshot.dictionaryRepresentation() as NSDictionary, fixture as NSDictionary)
        XCTAssertEqual(unrelated.string(forKey: "isolation"), "original")
        XCTAssertEqual(unrelated.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary, registration)
        snapshot.replace(with: ["replacement": 3])
        XCTAssertNil(snapshot.string(forKey: "string"))
        XCTAssertEqual(snapshot.integer(forKey: "replacement"), 3)
    }
}
