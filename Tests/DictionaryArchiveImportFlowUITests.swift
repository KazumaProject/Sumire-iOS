import XCTest

final class DictionaryArchiveImportFlowUITests: XCTestCase {
    // The UI import uses the pinned v1.7.277 support generation, whose native
    // connection.sud has 12,033 POS mappings. Keep its fixture table compatible
    // so the release dictionaries copied from that generation pass native checks.
    private static let bundledPositionCount = 12_033

    private enum FixtureKind {
        case shorts, ints, longs, characters

        var descriptor: String {
            switch self {
            case .shorts: "[S"
            case .ints: "[I"
            case .longs: "[J"
            case .characters: "[C"
            }
        }

        var serialVersionUID: UInt64 {
            switch self {
            case .shorts: 0xef832e06e55db0fa
            case .ints: 0x4dba602676eab2a5
            case .longs: 0x782004b512b17593
            case .characters: 0xb02666b0e25d84ac
            }
        }

        var width: Int {
            switch self {
            case .shorts, .characters: 2
            case .ints: 4
            case .longs: 8
            }
        }
    }

    private struct FixtureArray {
        let kind: FixtureKind
        let values: [UInt64]
    }

    private func appendBigEndian(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in (0..<width).reversed() {
            data.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
        }
    }

    private func javaPrimitiveArrays(_ arrays: [FixtureArray]) -> Data {
        var data = Data([0xac, 0xed, 0, 5])
        for array in arrays {
            let descriptor = Data(array.kind.descriptor.utf8)
            data.append(contentsOf: [0x75, 0x72])
            appendBigEndian(UInt64(descriptor.count), width: 2, to: &data)
            data.append(descriptor)
            appendBigEndian(array.kind.serialVersionUID, width: 8, to: &data)
            data.append(contentsOf: [2, 0, 0, 0x78, 0x70])
            appendBigEndian(UInt64(array.values.count), width: 4, to: &data)
            for value in array.values {
                appendBigEndian(value, width: array.kind.width, to: &data)
            }
        }
        return data
    }

    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb8_8320)
            }
        }
        return ~value
    }

    private func storedZIP(_ files: [(String, Data)]) -> Data {
        struct CentralEntry {
            let name: Data
            let checksum: UInt32
            let size: UInt32
            let offset: UInt32
        }

        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        func append32(_ value: UInt32, to data: inout Data) {
            append16(UInt16(truncatingIfNeeded: value), to: &data)
            append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        }

        var data = Data()
        var centralEntries: [CentralEntry] = []
        for (path, payload) in files {
            let name = Data(path.utf8)
            let size = UInt32(payload.count)
            let checksum = crc32(payload)
            let offset = UInt32(data.count)
            append32(0x0403_4b50, to: &data)
            append16(20, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append32(checksum, to: &data)
            append32(size, to: &data)
            append32(size, to: &data)
            append16(UInt16(name.count), to: &data)
            append16(0, to: &data)
            data.append(name)
            data.append(payload)
            centralEntries.append(.init(name: name, checksum: checksum, size: size, offset: offset))
        }

        let centralOffset = UInt32(data.count)
        for entry in centralEntries {
            append32(0x0201_4b50, to: &data)
            append16(20, to: &data)
            append16(20, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append32(entry.checksum, to: &data)
            append32(entry.size, to: &data)
            append32(entry.size, to: &data)
            append16(UInt16(entry.name.count), to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append16(0, to: &data)
            append32(0, to: &data)
            append32(entry.offset, to: &data)
            data.append(entry.name)
        }
        let centralSize = UInt32(data.count) - centralOffset
        append32(0x0605_4b50, to: &data)
        append16(0, to: &data)
        append16(0, to: &data)
        append16(UInt16(centralEntries.count), to: &data)
        append16(UInt16(centralEntries.count), to: &data)
        append32(centralSize, to: &data)
        append32(centralOffset, to: &data)
        append16(0, to: &data)
        return data
    }

    private func validDictionaryArchive(category: String = "facility/transport/parking") -> Data {
        let reading = javaPrimitiveArrays([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x3042]),
            .init(kind: .ints, values: [1])
        ])
        let surface = javaPrimitiveArrays([
            .init(kind: .longs, values: [0b101]),
            .init(kind: .longs, values: [0b100]),
            .init(kind: .characters, values: [0, 0x20, 0x611])
        ])
        let tokens = javaPrimitiveArrays([
            .init(kind: .shorts, values: [0]),
            .init(kind: .shorts, values: [100]),
            .init(kind: .ints, values: [2]),
            .init(kind: .longs, values: [0b10])
        ])
        let positionTable = javaPrimitiveArrays([
            .init(kind: .shorts, values: (0..<Self.bundledPositionCount).map { UInt64($0 & 1) }),
            .init(kind: .shorts, values: (0..<Self.bundledPositionCount).map { UInt64($0 & 1) })
        ])

        var connectionMatrix = Data()
        for value: UInt16 in [0, 1, 2, 3] {
            connectionMatrix.append(UInt8(value >> 8))
            connectionMatrix.append(UInt8(truncatingIfNeeded: value))
        }

        func nestedArchive(_ name: String, _ payload: Data) -> Data {
            storedZIP([(name, payload)])
        }

        return storedZIP([
            ("connectionId.dat.zip", nestedArchive("connectionId.dat", connectionMatrix)),
            ("pos_table.dat", positionTable),
            ("categories/\(category)/yomi.dat.zip", nestedArchive("yomi.dat", reading)),
            ("categories/\(category)/tango.dat.zip", nestedArchive("tango.dat", surface)),
            ("categories/\(category)/token.dat.zip", nestedArchive("token.dat", tokens))
        ])
    }

    private func openDictionarySettings(in app: XCUIApplication) {
        app.launch()

        let dictionaryCategory = app.buttons["settings-category-dictionaries"]
        for _ in 0..<5 where !dictionaryCategory.isHittable { app.swipeUp() }
        XCTAssertTrue(dictionaryCategory.waitForExistence(timeout: 5))
        dictionaryCategory.tap()

        let dictionarySettings = app.buttons["settings-destination-dictionaries"]
        XCTAssertTrue(dictionarySettings.waitForExistence(timeout: 5))
        dictionarySettings.tap()
    }

    private func presentFileImporter(in app: XCUIApplication) -> XCUIElement {
        let importButton = app.buttons["dictionary-import-android-zip"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5),
                      "The shared dictionary import control should be available in the Simulator app group.")
        importButton.tap()
        return importButton
    }

    func testImportButtonPresentsSystemPickerAndCancellationKeepsSettingsAvailable() {
        let app = XCUIApplication()
        openDictionarySettings(in: app)
        let importButton = presentFileImporter(in: app)

        let cancel = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Cancel", "キャンセル")
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "Tapping the import control should present the system document picker.")
        cancel.tap()

        XCTAssertTrue(importButton.waitForExistence(timeout: 5),
                      "Cancelling the picker should return to dictionary settings.")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch.exists,
            "A user cancellation must not be reported as an import result.")
    }

    func testSelectedArchiveFlowsThroughPickerAndShowsAsynchronousImportFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-seed-invalid-dictionary-import-zip"]
        openDictionarySettings(in: app)
        _ = presentFileImporter(in: app)

        let browse = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Browse", "ブラウズ")
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5),
                      "The document picker should expose its Browse tab.")
        browse.tap()

        let localFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "このiPhone内", "このiPad内"])
        ).firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 10),
                      "The seeded Debug-only fixture should be visible through Files local storage.")
        localFiles.tap()

        let sumireFolder = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sumire,")
        ).firstMatch
        XCTAssertTrue(sumireFolder.waitForExistence(timeout: 10))
        sumireFolder.tap()

        let archive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "sumire-ui-invalid-dictionary.zip")
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()

        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }

        let outcome = app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 20),
                      "The picker selection should complete the asynchronous import and show its result.")
        XCTAssertTrue(outcome.label.contains("辞書ZIPが壊れている"), outcome.label)
    }

    func testSelectedValidArchiveImportsAndPublishesThroughPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-seed-valid-dictionary-import-zip"]
        app.launchEnvironment["SUMIRE_UI_DICTIONARY_ARCHIVE_BASE64"] = validDictionaryArchive().base64EncodedString()
        openDictionarySettings(in: app)
        _ = presentFileImporter(in: app)

        let browse = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Browse", "ブラウズ")
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()

        let localFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "このiPhone内", "このiPad内"])
        ).firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 10))
        localFiles.tap()

        let sumireFolder = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sumire,")
        ).firstMatch
        XCTAssertTrue(sumireFolder.waitForExistence(timeout: 10))
        sumireFolder.tap()

        let archive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "sumire-ui-valid-dictionary.zip")
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()

        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }

        let outcome = app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 30),
                      "The selected archive should finish conversion and publication asynchronously.")
        XCTAssertTrue(outcome.label.contains("検証済みの辞書世代を有効化しました"), outcome.label)
        XCTAssertTrue(app.staticTexts["facility/transport/parking.sud"].exists,
                      "The success result should identify the release leaf published from the selected archive.")
    }

    func testSelectedReleaseOnlyDemographicArchiveImportsAsReleaseLeafThroughPicker() {
        let categoryID = "media_demographic/audience/shonen"
        let app = XCUIApplication()
        app.launchArguments = ["-seed-valid-dictionary-import-zip"]
        app.launchEnvironment["SUMIRE_UI_DICTIONARY_ARCHIVE_BASE64"] =
            validDictionaryArchive(category: categoryID).base64EncodedString()
        openDictionarySettings(in: app)
        _ = presentFileImporter(in: app)

        let browse = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Browse", "ブラウズ")
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()

        let localFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "このiPhone内", "このiPad内"])
        ).firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 10))
        localFiles.tap()

        let sumireFolder = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sumire,")
        ).firstMatch
        XCTAssertTrue(sumireFolder.waitForExistence(timeout: 10))
        sumireFolder.tap()

        let archive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "sumire-ui-valid-dictionary.zip")
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()

        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }

        let outcome = app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 30),
                      "The release-only category should pass conversion, publication, and generation readback.")
        XCTAssertTrue(outcome.label.contains("検証済みの辞書世代を有効化しました"), outcome.label)
        XCTAssertTrue(app.staticTexts[categoryID + ".sud"].exists,
                      "The release-only demographic ID must remain a direct release leaf, not a legacy aggregate.")
    }

    func testSelectedLegacyAggregateArchiveIsStoredWithoutActivationThroughPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-seed-valid-dictionary-import-zip"]
        app.launchEnvironment["SUMIRE_UI_DICTIONARY_ARCHIVE_BASE64"] = validDictionaryArchive(category: "character").base64EncodedString()
        openDictionarySettings(in: app)

        let importMode = app.buttons["dictionary-import-mode"]
        XCTAssertTrue(importMode.waitForExistence(timeout: 5),
                      "The import mode should be selectable before opening the archive picker.")
        importMode.tap()
        let legacyAggregateOption = app.buttons["旧Android集約分類"]
        XCTAssertTrue(legacyAggregateOption.waitForExistence(timeout: 5))
        legacyAggregateOption.tap()

        _ = presentFileImporter(in: app)
        let browse = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Browse", "ブラウズ")
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()

        let localFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "このiPhone内", "このiPad内"])
        ).firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 10))
        localFiles.tap()

        let sumireFolder = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sumire,")
        ).firstMatch
        XCTAssertTrue(sumireFolder.waitForExistence(timeout: 10))
        sumireFolder.tap()

        let archive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "sumire-ui-valid-dictionary.zip")
        ).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()

        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }

        let outcome = app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 30),
                      "The selected aggregate should finish conversion and generation read-back.")
        XCTAssertTrue(outcome.label.contains("旧分類集約辞書は型付き保存のみ"), outcome.label)
        XCTAssertTrue(app.staticTexts["保存した旧分類集約辞書（未有効化）"].exists)
        XCTAssertTrue(app.staticTexts["character"].exists,
                      "The reloaded generation should report the typed aggregate identity as stored but inactive.")
    }

    func testSelectedPinnedAndroidArchiveStoresTypedAggregatesThroughFilesPicker() throws {
        guard ProcessInfo.processInfo.environment["SUMIRE_UI_RUN_PINNED_ANDROID_ARCHIVE_PICKER"] == "1" else {
            throw XCTSkip("Requires the exact pinned Android ZIP pre-seeded in Files/Sumire. Set SUMIRE_UI_RUN_PINNED_ANDROID_ARCHIVE_PICKER=1 only when that external fixture is present.")
        }

        let app = XCUIApplication()
        openDictionarySettings(in: app)

        let importMode = app.buttons["dictionary-import-mode"]
        XCTAssertTrue(importMode.waitForExistence(timeout: 5))
        importMode.tap()
        let legacyAggregateOption = app.buttons["旧Android集約分類"]
        XCTAssertTrue(legacyAggregateOption.waitForExistence(timeout: 5))
        legacyAggregateOption.tap()

        _ = presentFileImporter(in: app)
        let browse = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Browse", "ブラウズ")
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()

        let localFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad", "このiPhone内", "このiPad内"])
        ).firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 10))
        localFiles.tap()

        let sumireFolder = app.cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sumire,")
        ).firstMatch
        XCTAssertTrue(sumireFolder.waitForExistence(timeout: 10))
        sumireFolder.tap()

        let pinnedArchive = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "pinned-android-assets-df1f383.zip")
        ).firstMatch
        XCTAssertTrue(pinnedArchive.waitForExistence(timeout: 10),
                      "The exact pinned Android source ZIP must be visible through Files local storage.")
        pinnedArchive.tap()

        let open = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Open", "開く")
        ).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }

        let outcome = app.descendants(matching: .any)
            .matching(identifier: "dictionary-import-outcome-message").firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 180),
                      "The pinned archive should finish conversion, publication, and generation readback asynchronously.")
        XCTAssertTrue(outcome.label.contains("辞書世代を保存しました"), outcome.label)
        XCTAssertTrue(outcome.label.contains("旧分類集約辞書は型付き保存のみ"), outcome.label)
        XCTAssertTrue(app.staticTexts["保存した旧分類集約辞書（未有効化）"].exists)

        let expectedAggregateIDs = Set([
            "person", "character", "mythological_figure", "place", "address", "station", "facility",
            "transport_route", "organization", "lineage", "product", "vehicle", "event", "award",
            "agreement", "initiative", "term", "work_franchise", "work_manga", "work_anime", "work_film",
            "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical",
            "work_other", "kampo", "medical"
        ])
        var visibleAggregateIDs = Set<String>()
        for _ in 0..<12 {
            visibleAggregateIDs.formUnion(app.staticTexts.allElementsBoundByIndex.map(\.label)
                .filter(expectedAggregateIDs.contains))
            if visibleAggregateIDs == expectedAggregateIDs { break }
            app.swipeUp()
        }
        XCTAssertEqual(visibleAggregateIDs, expectedAggregateIDs,
                       "The Files-import outcome should list all 30 typed aggregate IDs from the pinned ZIP.")
    }

}
