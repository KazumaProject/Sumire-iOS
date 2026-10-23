#if DEBUG
import XCTest
import UIKit
@testable import Sumire
import SumireCore

@MainActor
final class KeyboardToolbarActionRoutingTests: XCTestCase {
    func testAndroidImportedTemplateAndMacroActionsKeepOrderAndOpenMacroPanel() throws {
        let backupData = Data(#"{"version":2,"entries":[],"shortcutIds":["template","text_macro"]}"#.utf8)
        let backup = try AndroidPreferenceBackup.decode(backupData)
        let suite = "toolbar-android-macro-route-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try backup.apply(to: defaults)
        XCTAssertEqual(KeyboardToolbarPreferences.load(defaults: defaults), [.template, .textMacros])

        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        var lexicon = PersonalLexicon()
        lexicon.textMacros = [
            PersonalTextMacro(name: "zeta", body: "last"),
            PersonalTextMacro(name: "Alpha", body: "first"),
            PersonalTextMacro(name: "beta", body: "middle")
        ]
        surface.personalLexicon = lexicon
        surface.candidateBar.reloadToolbarSettings(defaults: defaults)
        let toolbar = surface.candidateBar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        XCTAssertEqual(toolbar?.arrangedSubviews.compactMap(\.accessibilityIdentifier),
                       ["toolbar-template", "toolbar-text-macros"])

        let button = toolbar?.arrangedSubviews.first {
            $0.accessibilityIdentifier == "toolbar-text-macros"
        } as? UIButton
        XCTAssertNotNil(button)
        button?.sendActions(for: .touchUpInside)

        func findMacroPanel(in view: UIView) -> KeyboardTextMacroPanel? {
            if let panel = view as? KeyboardTextMacroPanel { return panel }
            for child in view.subviews {
                if let panel = findMacroPanel(in: child) { return panel }
            }
            return nil
        }
        let panel = try XCTUnwrap(findMacroPanel(in: surface))
        let macroRowTitles = descendants(of: panel)
            .compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier?.hasPrefix("text-macro-") == true }
            .compactMap { $0.configuration?.title }
        XCTAssertEqual(macroRowTitles, ["Alpha", "beta", "zeta"])
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testRequiredTextMacroPanelRemainsAvailableDuringComposition() throws {
        let suite = "toolbar-required-macro-composition-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("builtin:sumire", forKey: "keyboard.lastUsed")
        defaults.set("toggle", forKey: "sumire.keyArrangement")

        let requestedID = UUID().uuidString.lowercased()
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.textMacroContextAllowed = true
        var lexicon = PersonalLexicon()
        lexicon.textMacros = [
            PersonalTextMacro(name: "Other", body: "plain"),
            PersonalTextMacro(id: requestedID, name: "Clipboard macro", body: "{clipboard}")
        ]
        surface.personalLexicon = lexicon
        surface.reloadAppearance()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = try XCTUnwrap(controller.view)
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: 390),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        ])
        container.layoutIfNeeded()
        surface.layoutIfNeeded()

        let character = try XCTUnwrap(descendants(of: surface).first {
            $0.accessibilityIdentifier == "sumire-a"
        } as? UIButton)
        XCTAssertTrue(character.accessibilityActivate())
        XCTAssertTrue(surface.hasComposition)
        XCTAssertFalse(surface.candidateBar.showsShortcuts)

        surface.showTextMacroList(requiredMacroID: requestedID)
        let panel = try XCTUnwrap(descendants(of: surface).compactMap { $0 as? KeyboardTextMacroPanel }.first)
        let macroRows = descendants(of: panel).compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier?.hasPrefix("text-macro-") == true }
        XCTAssertEqual(macroRows.compactMap { $0.configuration?.title }, ["Clipboard macro"])
        XCTAssertTrue(macroRows[0].isEnabled)
        let pasteControl = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? UIPasteControl }.first)
        XCTAssertFalse(pasteControl.isHidden, "Clipboard access remains explicitly user initiated")
    }

    func testImportedClipboardActionOpensClipboardPanelWithFullAccessOff() {
        let suite = "toolbar-clipboard-route-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.clipboard], defaults: defaults)

        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        surface.candidateBar.reloadToolbarSettings(defaults: defaults)
        let toolbar = surface.candidateBar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let button = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-clipboard" } as? UIButton

        XCTAssertNotNil(button)
        button?.sendActions(for: .touchUpInside)

        func findPanel(in view: UIView) -> Sumire.SymbolKeyboardView? {
            if let panel = view as? Sumire.SymbolKeyboardView { return panel }
            for child in view.subviews {
                if let panel = findPanel(in: child) { return panel }
            }
            return nil
        }
        let panel = findPanel(in: surface)
        XCTAssertEqual(panel?.mode, .clipboard)
        XCTAssertFalse(panel?.clipboardAccessAllowed ?? true)
    }

    func testTemplateActionShowsReadOnlyTemplatesAndInsertsSelectedText() {
        let suite = "toolbar-template-route-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.template], defaults: defaults)

        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = defaults
        var lexicon = PersonalLexicon()
        lexicon.templates = [
            PersonalWord(word: "花束を贈ります", reading: "はなたば"),
            PersonalWord(word: "おはようございます", reading: "おはよう"),
            PersonalWord(word: "お元気ですか", reading: "おはよう")
        ]
        surface.personalLexicon = lexicon
        surface.candidateBar.reloadToolbarSettings(defaults: defaults)
        var inserted: String?
        surface.candidateBar.onInsertShortcutText = { inserted = $0 }
        let toolbar = surface.candidateBar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let button = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-template" } as? UIButton

        button?.sendActions(for: .touchUpInside)

        func findPanel(in view: UIView) -> KeyboardTemplatePanel? {
            if let panel = view as? KeyboardTemplatePanel { return panel }
            for child in view.subviews {
                if let panel = findPanel(in: child) { return panel }
            }
            return nil
        }
        let panel = findPanel(in: surface)
        XCTAssertEqual(panel?.orderedTemplateWords, ["おはようございます", "お元気ですか", "花束を贈ります"])
        panel?.selectTemplate(at: 0)
        XCTAssertEqual(inserted, "おはようございます")
        XCTAssertNil(findPanel(in: surface))
    }

    func testLiveConversionToggleUsesConfiguredPrivateStoreAndNotifiesSettingsAccess() {
        let sharedDomain = "toolbar-routing-shared-" + UUID().uuidString
        let localDomain = "toolbar-routing-local-" + UUID().uuidString
        let shared = UserDefaults(suiteName: sharedDomain)!
        let local = UserDefaults(suiteName: localDomain)!
        defer {
            shared.removePersistentDomain(forName: sharedDomain)
            local.removePersistentDomain(forName: localDomain)
        }
        shared.set(false, forKey: "liveConversion")
        let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = access.readDefaults
        surface.settingsWriteDefaults = access.writeDefaults
        surface.liveConversion = access.readDefaults.bool(forKey: "liveConversion")
        surface.onSettingsWritten = { access.didWrite($0) }
        let router: Sumire.KeyboardToolbarActionRouting = surface

        XCTAssertFalse(router.keyboardToolbarLiveConversionEnabled)
        XCTAssertTrue(router.toggleKeyboardToolbarLiveConversion())
        XCTAssertTrue(surface.liveConversion)
        XCTAssertTrue(local.bool(forKey: "liveConversion"))
        XCTAssertFalse(shared.bool(forKey: "liveConversion"))
        XCTAssertTrue(access.readDefaults.bool(forKey: "liveConversion"))

        let reopened = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
        XCTAssertTrue(reopened.readDefaults.bool(forKey: "liveConversion"))

        XCTAssertFalse(router.toggleKeyboardToolbarLiveConversion())
        XCTAssertFalse(surface.liveConversion)
        XCTAssertFalse(local.bool(forKey: "liveConversion"))
        XCTAssertFalse(shared.bool(forKey: "liveConversion"))
        XCTAssertFalse(access.readDefaults.bool(forKey: "liveConversion"))
        XCTAssertFalse(KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
            .readDefaults.bool(forKey: "liveConversion"))
    }

    func testLearningPauseIsSessionOnlyAndDoesNotWriteSettings() {
        let sharedDomain = "toolbar-learning-pause-shared-" + UUID().uuidString
        let localDomain = "toolbar-learning-pause-local-" + UUID().uuidString
        let shared = UserDefaults(suiteName: sharedDomain)!
        let local = UserDefaults(suiteName: localDomain)!
        defer {
            shared.removePersistentDomain(forName: sharedDomain)
            local.removePersistentDomain(forName: localDomain)
        }
        let access = KeyboardSettingsAccess(shared: shared, local: local, allowSharedWrites: false)
        let surface = Sumire.KeyboardSurface()
        surface.settingsDefaults = access.readDefaults
        surface.settingsWriteDefaults = access.writeDefaults
        var writtenKeys: [[String]] = []
        surface.onSettingsWritten = { writtenKeys.append($0) }
        let router: Sumire.KeyboardToolbarActionRouting = surface

        XCTAssertFalse(router.keyboardToolbarLearningPaused)
        XCTAssertTrue(router.toggleKeyboardToolbarLearningPause())
        XCTAssertTrue(surface.learningPausedForSession)
        XCTAssertFalse(local.bool(forKey: "learningPausedForSession"))
        XCTAssertFalse(shared.bool(forKey: "learningPausedForSession"))
        XCTAssertTrue(writtenKeys.isEmpty)

        XCTAssertFalse(router.toggleKeyboardToolbarLearningPause())
        XCTAssertFalse(surface.learningPausedForSession)
        XCTAssertFalse(local.bool(forKey: "learningPausedForSession"))
        XCTAssertFalse(shared.bool(forKey: "learningPausedForSession"))
        XCTAssertTrue(writtenKeys.isEmpty)
    }
}
#endif
