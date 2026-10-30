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
        KeyboardToolbarPreferences.save([.resize, .selectDate, .keyboardPicker, .liveConversionToggle, .learningPause, .template, .textMacros, .clipboard, .paste, .emoji], defaults: defaults)

        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.reloadToolbarSettings(defaults: defaults)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }

        XCTAssertEqual(toolbar?.arrangedSubviews.compactMap(\.accessibilityIdentifier), [
            "toolbar-resize", "toolbar-date-picker", "toolbar-keyboard-picker", "toolbar-live-conversion", "toolbar-learning-pause", "toolbar-template", "toolbar-text-macros", "toolbar-clipboard", "toolbar-paste-group", "symbol-open"
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
    func testLearningPauseToolbarActionUsesHostAndUpdatesItsAccessibleState() {
        let suite = "KeyboardToolbarCandidateBarTests.LearningPause.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.learningPause], defaults: defaults)

        let router = KeyboardToolbarActionRouterProbe(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        router.addSubview(bar)
        bar.reloadToolbarSettings(defaults: defaults)
        let toolbar = bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" }
        let toggle = toolbar?.arrangedSubviews.first { $0.accessibilityIdentifier == "toolbar-learning-pause" } as? UIButton

        XCTAssertEqual(toggle?.accessibilityLabel, "変換学習を一時停止")
        XCTAssertEqual(toggle?.accessibilityValue, "有効")
        toggle?.sendActions(for: .touchUpInside)

        XCTAssertEqual(router.learningPauseToggleCount, 1)
        XCTAssertTrue(router.keyboardToolbarLearningPaused)
        XCTAssertTrue(toggle?.isSelected == true)
        XCTAssertEqual(toggle?.accessibilityLabel, "変換学習を再開")
        XCTAssertEqual(toggle?.accessibilityValue, "一時停止中")
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
    func testExplicitImageProviderWithoutFullAccessShowsThumbnailWithoutHistory() async throws {
        let suite = "ExplicitImagePaste.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardToolbarPreferences.save([.paste], defaults: defaults)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.rootViewController = UIViewController()
        let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        bar.clipboardAccessAllowed = false
        bar.captureClipboardHistory = true
        bar.reloadToolbarSettings(defaults: defaults)
        window.rootViewController?.view.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded(); bar.layoutIfNeeded()
        let toolbar = try XCTUnwrap(bar.subviews.compactMap { $0 as? UIStackView }
            .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" })
        let group = try XCTUnwrap(toolbar.arrangedSubviews.first {
            $0.accessibilityIdentifier == "toolbar-paste-group"
        } as? UIStackView)
        let preview = try XCTUnwrap(group.arrangedSubviews.first {
            $0.accessibilityIdentifier == "clipboard-description"
        } as? UIButton)
        let control = try XCTUnwrap(group.arrangedSubviews.first {
            $0.accessibilityIdentifier == "clipboard-preview"
        } as? UIPasteControl)
        print("EXPLICIT_IMAGE_SYSTEM_ACCESSIBILITY=" + String(describing: control.accessibilityLabel)
              + " hint=" + String(describing: control.accessibilityHint))
        XCTAssertFalse(group.isHidden)
        XCTAssertFalse(control.isHidden)
        XCTAssertTrue(preview.isHidden)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
        let notified = expectation(description: "Explicit image provider notice")
        var notices = 0
        var inserts = 0
        var captures = 0
        bar.onClipboardNotice = { text in
            notices += 1
            XCTAssertTrue(text.contains("貼り付け"))
            notified.fulfill()
        }
        bar.onPasteText = { _ in inserts += 1 }
        bar.onClipboardCaptured = { _, _ in captures += 1 }
        bar.paste(itemProviders: [provider])
        await fulfillment(of: [notified], timeout: 5)
        XCTAssertNotNil(preview.image(for: .normal), "The real provider must decode a thumbnail")
        XCTAssertFalse(preview.isHidden, "Explicit OFF image paste must reveal its decoded thumbnail")
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(inserts, 0)
        XCTAssertEqual(captures, 0)
        XCTAssertFalse(bar.clipboardAccessAllowed)
    }

    @MainActor
    func testDelayedExplicitImageIsRejectedAfterToolbarHideOrWindowDetach() async throws {
        for detach in [false, true] {
            let suite = "DelayedExplicitImage.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            KeyboardToolbarPreferences.save([.paste], defaults: defaults)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
            window.rootViewController = UIViewController()
            let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
            bar.clipboardAccessAllowed = false
            bar.captureClipboardHistory = true
            window.rootViewController?.view.addSubview(bar)
            window.isHidden = false
            defer { window.isHidden = true }
            bar.reloadToolbarSettings(defaults: defaults)
            let toolbar = try XCTUnwrap(bar.subviews.compactMap { $0 as? UIStackView }
                .first { $0.accessibilityIdentifier == "keyboard-toolbar-actions" })
            let group = try XCTUnwrap(toolbar.arrangedSubviews.first {
                $0.accessibilityIdentifier == "toolbar-paste-group"
            } as? UIStackView)
            let preview = try XCTUnwrap(group.arrangedSubviews.first {
                $0.accessibilityIdentifier == "clipboard-description"
            } as? UIButton)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at: url) }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            try XCTUnwrap(image.pngData()).write(to: url)
            let requested = expectation(description: "Image request is pending")
            let unexpected = expectation(description: "Invalidated image produces no callback")
            unexpected.isInverted = true
            let lock = NSLock()
            var complete: ((URL?, Bool, Error?) -> Void)?
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { callback in
                lock.lock(); complete = callback; lock.unlock()
                requested.fulfill()
                return nil
            }
            bar.onClipboardNotice = { _ in unexpected.fulfill() }
            bar.onPasteText = { _ in unexpected.fulfill() }
            bar.onClipboardCaptured = { _, _ in unexpected.fulfill() }
            bar.paste(itemProviders: [provider])
            await fulfillment(of: [requested], timeout: 5)
            if detach {
                bar.removeFromSuperview()
                XCTAssertNil(bar.window)
                window.rootViewController?.view.addSubview(bar)
                bar.reloadToolbarSettings(defaults: defaults)
            } else {
                bar.showsShortcuts = false
                bar.showsShortcuts = true
            }
            lock.lock(); let callback = complete; lock.unlock()
            try XCTUnwrap(callback)(url, false, nil)
            await fulfillment(of: [unexpected], timeout: 1)
            XCTAssertNil(preview.image(for: .normal))
            XCTAssertTrue(preview.isHidden)
            XCTAssertFalse(bar.clipboardAccessAllowed)
        }
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
    private(set) var learningPauseToggleCount = 0
    private(set) var keyboardToolbarLearningPaused = false

    func toggleKeyboardToolbarLiveConversion() -> Bool {
        toggleCount += 1
        keyboardToolbarLiveConversionEnabled.toggle()
        return keyboardToolbarLiveConversionEnabled
    }

    func toggleKeyboardToolbarLearningPause() -> Bool {
        learningPauseToggleCount += 1
        keyboardToolbarLearningPaused.toggle()
        return keyboardToolbarLearningPaused
    }
}

private final class KeyboardPickerTargetProbe: NSObject {
    @objc func handleInputModeList(from view: UIView, with event: UIEvent) {}
}
