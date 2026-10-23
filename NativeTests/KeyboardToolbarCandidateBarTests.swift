import XCTest
import UIKit
@testable import Sumire
import SumireCore

final class KeyboardToolbarCandidateBarTests: XCTestCase {
    @MainActor
    func testCandidateBarPlacesConfiguredActionsInStoredOrder() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.resize, .selectDate, .keyboardPicker, .liveConversionToggle, .template, .textMacros, .clipboard, .paste, .emoji], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }

        XCTAssertEqual(toolbar?.arrangedSubviews.compactMap(\.accessibilityIdentifier), [
            "toolbar-resize", "toolbar-date-picker", "toolbar-keyboard-picker", "toolbar-live-conversion", "toolbar-template", "toolbar-text-macros", "toolbar-clipboard", "toolbar-paste-group", "symbol-open"
        ])
        let datePicker = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-date-picker" } as? UIButton
        XCTAssertTrue(datePicker?.showsMenuAsPrimaryAction == true)
        XCTAssertFalse(datePicker?.menu?.children.isEmpty ?? true)
        let pasteGroup = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-paste-group" } as? UIStackView
        XCTAssertEqual(pasteGroup?.arrangedSubviews.compactMap(\.accessibilityIdentifier), [
            "clipboard-preview", "clipboard-description"
        ])
    }


    @MainActor
    func testTextMacroActionOpensTheInjectedMacroRoute() {
        let suite = "KeyboardToolbarCandidateBarTests.TextMacro.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.textMacros], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        var didOpenMacroList = false
        bar.onTextMacros = { didOpenMacroList = true }
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let button = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-text-macros" } as? UIButton

        XCTAssertNotNil(button)
        XCTAssertEqual(KeyboardToolbarAction(rawValue: "text_macro"), .textMacros)
        button?.sendActions(for: .touchUpInside)
        XCTAssertTrue(didOpenMacroList)
    }

    @MainActor
    func testKeyboardPickerUsesTheSystemInputModeListHandlerForAllTouchEvents() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.keyboardPicker], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        let target = KeyboardPickerTargetProbe()
        let handler = #selector(KeyboardPickerTargetProbe.handleInputModeList(from:with:))
        bar.bindKeyboardPicker(target: target, action: handler)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let picker = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-keyboard-picker" } as? UIButton

        XCTAssertTrue(picker?.allTargets.contains { ($0 as AnyObject) === target } == true)
        XCTAssertTrue(picker?.actions(forTarget: target, forControlEvent: .allTouchEvents)?.contains(NSStringFromSelector(handler)) == true)
    }

    @MainActor
    func testLiveConversionToolbarActionUsesHostAndUpdatesItsAccessibleState() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.liveConversionToggle], defaults: defaults)

        let router = KeyboardToolbarActionRouterProbe(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        router.addSubview(bar)
        bar.reloadToolbarSettings(defaults: defaults)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let toggle = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-live-conversion" } as? UIButton

        XCTAssertEqual(toggle?.accessibilityValue, "オフ")
        toggle?.sendActions(for: .touchUpInside)

        XCTAssertEqual(router.toggleCount, 1)
        XCTAssertTrue(router.keyboardToolbarLiveConversionEnabled)
        XCTAssertTrue(toggle?.isSelected == true)
        XCTAssertEqual(toggle?.accessibilityValue, "オン")
    }

    @MainActor
    func testCandidateBarRemovesDisabledPasteActionAndRendersRemainingOrder() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.emoji, .resize], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }

        XCTAssertEqual(toolbar?.arrangedSubviews.compactMap(\.accessibilityIdentifier), [
            "symbol-open", "toolbar-resize"
        ])
    }

    @MainActor
    func testUserInitiatedPasteControlRemainsVisibleWithFullAccessOff() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.paste], defaults: defaults)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.clipboardAccessAllowed = false
        window.rootViewController?.view.addSubview(bar)
        bar.reloadToolbarSettings(defaults: defaults)

        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let pasteGroup = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-paste-group" } as? UIStackView
        let pasteControl = pasteGroup?.arrangedSubviews.first { $0.accessibilityIdentifier == "clipboard-preview" }
        let clipboardPreview = pasteGroup?.arrangedSubviews.first { $0.accessibilityIdentifier == "clipboard-description" }

        XCTAssertFalse(bar.clipboardAccessAllowed)
        XCTAssertFalse(pasteGroup?.isHidden ?? true)
        XCTAssertFalse(pasteControl?.isHidden ?? true)
        XCTAssertTrue(clipboardPreview?.isHidden ?? false)
    }

    @MainActor
    func testUserInitiatedPasteProviderInsertsTextWithFullAccessOffWithoutCapturingHistory() async {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.paste], defaults: defaults)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.clipboardAccessAllowed = false
        bar.captureClipboardHistory = true
        window.rootViewController?.view.addSubview(bar)
        bar.reloadToolbarSettings(defaults: defaults)

        let pasted = expectation(description: "user-initiated paste provider is inserted")
        var pastedText: String?
        bar.onPasteText = { text in
            pastedText = text
            pasted.fulfill()
        }
        bar.onClipboardCaptured = { _, _ in
            XCTFail("Full Access OFF paste must not be added to clipboard history")
        }

        bar.paste(itemProviders: [NSItemProvider(object: NSString(string: "selected local text"))])
        await fulfillment(of: [pasted], timeout: 2)

        XCTAssertEqual(pastedText, "selected local text")
        XCTAssertFalse(bar.clipboardAccessAllowed)
    }

    @MainActor
    func testClipboardToolbarButtonOpensTheClipboardActionRoute() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.clipboard], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        var didOpenClipboard = false
        bar.onClipboard = { didOpenClipboard = true }
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let button = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-clipboard" } as? UIButton

        XCTAssertNotNil(button)
        button?.sendActions(for: .touchUpInside)
        XCTAssertTrue(didOpenClipboard)
    }

    @MainActor
    func testTemplateToolbarButtonOpensItsActionRoute() {
        let suite = "KeyboardToolbarCandidateBarTemplateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.template], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        var didOpenTemplates = false
        bar.onTemplates = { didOpenTemplates = true }
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let button = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-template" } as? UIButton

        XCTAssertNotNil(button)
        button?.sendActions(for: .touchUpInside)
        XCTAssertTrue(didOpenTemplates)
    }

    @MainActor
    func testClipboardOverlayAcceptsOnlyUserSelectedTextWithFullAccessOffWithoutSavingHistory() async throws {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClipboardHistorySettings.enabledKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let panel = SymbolKeyboardView(defaults: defaults, catalog: [], initialMode: .clipboard)
        var controller: ClipboardHistoryController? = ClipboardHistoryController()
        controller?.configure(defaults: defaults, writableDefaults: defaults,
                              url: directory.appendingPathComponent("clipboard.sqlite"), allowed: false)
        controller?.attach(panel)
        var insertedText: String?
        let inserted = expectation(description: "explicit system paste inserts the selected text")
        controller?.onInsertText = { text in
            insertedText = text
            inserted.fulfill()
        }

        let pasteControl = descendants(of: panel).compactMap { $0 as? UIPasteControl }
            .first { $0.accessibilityIdentifier == "symbol-clipboard-load" }
        XCTAssertFalse(panel.clipboardAccessAllowed)
        XCTAssertTrue(pasteControl?.isEnabled == true)
        XCTAssertFalse(descendants(of: panel).contains { $0 is UISwitch })

        panel.paste(itemProviders: [NSItemProvider(object: NSString(string: "selected text only"))])
        await fulfillment(of: [inserted], timeout: 2)

        XCTAssertEqual(insertedText, "selected text only")
        controller?.detach()
        controller = nil
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite")
        var storedItems: [ClipboardHistoryStore.Item]?
        for _ in 0..<20 where storedItems == nil {
            storedItems = try? ClipboardHistoryStore(url: databaseURL).items()
            if storedItems == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertEqual(storedItems, [])
    }

    @MainActor
    func testToolbarStaysInFirstRowWhenThreeCandidateRowsAreReserved() {
        let suite = "KeyboardToolbarCandidateBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.resize], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        bar.rowCount = 3
        bar.showsShortcuts = true
        bar.layoutIfNeeded()

        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        XCTAssertEqual(bar.displayedHeight, 132)
        XCTAssertEqual(toolbar?.frame.minY ?? -1, 0, accuracy: 0.5)

        bar.showsShortcuts = false
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.displayedHeight, 132)
        XCTAssertEqual(toolbar?.frame.minY ?? -1, 0, accuracy: 0.5)
    }
}

private func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants(of:))
}

@MainActor
private final class KeyboardToolbarActionRouterProbe: UIView, KeyboardToolbarActionRouting {
    private(set) var toggleCount = 0
    private(set) var keyboardToolbarLiveConversionEnabled = false

    func toggleKeyboardToolbarLiveConversion() -> Bool {
        toggleCount += 1
        keyboardToolbarLiveConversionEnabled.toggle()
        return keyboardToolbarLiveConversionEnabled
    }
}

private final class KeyboardPickerTargetProbe: NSObject {
    @objc func handleInputModeList(from view: UIView, with event: UIEvent) {}
}
