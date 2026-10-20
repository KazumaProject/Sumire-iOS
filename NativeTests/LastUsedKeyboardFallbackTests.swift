#if DEBUG
import XCTest
import UIKit
import SumireCore
@testable import Sumire

@MainActor
final class LastUsedKeyboardFallbackTests: XCTestCase {
    func testRemovedSelectionStaysReplacedAfterTypingReenableAndRestart() throws {
        let domain = "last-used-fallback-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try KeyboardSelection(ids: ["builtin:english", "builtin:gojuon"]).save(defaults: defaults)
        defaults.set("builtin:english", forKey: "keyboard.lastUsed")
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.reloadAppearance()
        var writes: [[String]] = []
        surface.onSettingsWritten = { writes.append($0) }
        var reading = ""
        surface.updateMarkedText = { reading = $0 }
        surface.updateMarkedSelection = { text, _ in reading = text }
        try KeyboardSelection(ids: ["builtin:gojuon"]).save(defaults: defaults)
        surface.reloadAppearance()
        XCTAssertEqual(defaults.string(forKey: "keyboard.lastUsed"), "builtin:gojuon")
        XCTAssertEqual(writes, [["keyboard.lastUsed"]])
        let key = try XCTUnwrap(descendants(surface).first { $0.accessibilityIdentifier == "gojuon-0-0" } as? Sumire.FlickKey)
        key.onFlick?(.tap)
        XCTAssertFalse(reading.isEmpty)
        let composing = reading
        try KeyboardSelection(ids: ["builtin:english", "builtin:gojuon"]).save(defaults: defaults)
        surface.reloadAppearance()
        XCTAssertNotNil(descendants(surface).first { $0.accessibilityIdentifier == "gojuon-0-0" })
        XCTAssertEqual(reading, composing)
        let restarted = Sumire.KeyboardSurface()
        restarted.settingsDefaults = defaults
        restarted.reloadAppearance()
        XCTAssertNotNil(descendants(restarted).first { $0.accessibilityIdentifier == "gojuon-0-0" })
    }

    func testReplacementWritesOnlyToConfiguredLocalStore() throws {
        let sharedDomain = "last-used-shared-" + UUID().uuidString
        let localDomain = "last-used-local-" + UUID().uuidString
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedDomain))
        let local = try XCTUnwrap(UserDefaults(suiteName: localDomain))
        defer {
            shared.removePersistentDomain(forName: sharedDomain)
            local.removePersistentDomain(forName: localDomain)
        }
        shared.set("builtin:english", forKey: "keyboard.lastUsed")
        try KeyboardSelection(ids: ["builtin:gojuon"]).save(defaults: shared)
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = shared
        surface.settingsWriteDefaults = local
        var notified = false
        surface.onSettingsWritten = { notified = $0 == ["keyboard.lastUsed"] }
        surface.reloadAppearance()
        XCTAssertEqual(local.string(forKey: "keyboard.lastUsed"), "builtin:gojuon")
        XCTAssertEqual(shared.string(forKey: "keyboard.lastUsed"), "builtin:english")
        XCTAssertTrue(notified)
    }

    func testPreviewDoesNotReplaceSavedKeyboard() throws {
        let domain = "last-used-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("builtin:english", forKey: "keyboard.lastUsed")
        try KeyboardSelection(ids: ["builtin:gojuon"]).save(defaults: defaults)
        let surface = Sumire.KeyboardSurface()
        surface.configureAppearancePreview(.gojuon, defaults: defaults)
        surface.reloadAppearance()
        XCTAssertEqual(defaults.string(forKey: "keyboard.lastUsed"), "builtin:english")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
#endif
