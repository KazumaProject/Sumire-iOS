import XCTest
@testable import SumireCore

final class CustomKeyboardLibraryTests: XCTestCase {
    func testGeneratedIdentitiesSurviveSaveAndInvalidAppendIsAtomic() throws {
        let name = "CustomKeyboardLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let json = #"[{"layout":{"name":"test","rowCount":1,"columnCount":1},"keysWithFlicks":[{"key":{"label":"あ","action":"InputText:あ"},"flicks":[{"flickDirection":"UP","actionType":"INPUT_TEXT","actionValue":"う"}]}]}]"#
        let imported = try CustomLayoutImportPreview.parse(Data(json.utf8)).layouts
        var library = CustomKeyboardLibrary()
        try library.append(imported)
        library.activeID = imported[0].id
        try library.save(defaults: defaults)
        let restored = try CustomKeyboardLibrary.load(defaults: UserDefaults(suiteName: name)!)
        let layout = try XCTUnwrap(restored.layouts().first)
        XCTAssertEqual(layout.id, imported[0].id)
        XCTAssertEqual(layout.placements[0].id, imported[0].placements[0].id)
        XCTAssertEqual(layout.placements[0].source["flicks"], imported[0].placements[0].source["flicks"])
        let previous = library
        XCTAssertThrowsError(try library.append(imported))
        XCTAssertEqual(library, previous)
        library.activeID = "missing"
        XCTAssertThrowsError(try library.save(defaults: defaults))
        XCTAssertEqual(try CustomKeyboardLibrary.load(defaults: defaults), previous)
        library = previous
        try library.remove(id: imported[0].id)
        XCTAssertNil(library.activeID)
        XCTAssertTrue(try library.layouts().isEmpty)
    }
}
