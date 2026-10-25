import UIKit
import SumireCore

final class KeyboardViewController: UIInputViewController {
    private let surface = KeyboardSurface()
    private typealias Context = MarkedDocumentOwnership.Context
    private var markedOwnership = MarkedDocumentOwnership()
    private var expectedContext: Context?
    private var changing = false
#if DEBUG
    private var lifecycleTrace: [String] = []
#endif
    private var keyboardHeight: NSLayoutConstraint!
    private var settingsAccess: KeyboardSettingsAccess?
    override func viewDidLoad() {
        super.viewDidLoad()
        ProcessMemory.record("extension.loaded")
        surface.candidateBar.clipboardAccessAllowed = hasFullAccess
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
#if DEBUG
        surface.exposeLifecycleSwitcherForDiagnostics { [weak self] in self?.advanceToNextInputMode() }
#endif
        surface.candidateBar.bindKeyboardPicker(
            target: self,
            action: #selector(handleInputModeList(from:with:))
        )
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        keyboardHeight = view.heightAnchor.constraint(equalToConstant: 464)
        keyboardHeight.priority = .defaultHigh
        keyboardHeight.isActive = true
        surface.onHeightChange = { [weak self] height in self?.keyboardHeight.constant = height }
        surface.beforeInput = { [weak self] in self?.validateContext() }
        surface.insert = { [weak self] text in self?.perform { $0.insertText(text) } }
        surface.candidateBar.onInsertShortcutText = { [weak self] text in
            guard let self, !self.surface.hasComposition else { return }
            self.surface.beforeInput?()
            self.surface.insert?(text)
        }
        surface.delete = { [weak self] in self?.perform { $0.deleteBackward() } }
        surface.deleteUntilBoundary = { [weak self] in
            guard let self else { return }
            let proxy = self.textDocumentProxy
            let symbols = self.surface.settingsDefaults.string(forKey: DeletionBoundary.settingsKey) ?? DeletionBoundary.defaultSymbols
            let count = proxy.selectedText?.isEmpty == false ? 1 :
                DeletionBoundary.backwardCount(context: proxy.documentContextBeforeInput ?? "", symbols: symbols)
            self.perform { proxy in for _ in 0..<count { proxy.deleteBackward() } }
        }
        let mark: (String, NSRange) -> Void = { [weak self] text, selection in
            guard let self else { return }
            // Empty editors may return nil on both sides of the insertion point.
            // That does not mean marked text is unsupported. Keep the reading in
            // the surface as well, so hosts ignoring marked text can still commit.
            let proxy = self.textDocumentProxy
            guard self.resolveMarkedOwnership(for: proxy, event: "mark", invalidateComposition: false) else { return }
            let before = self.context(for: proxy)
            guard before.document != nil else {
#if DEBUG
                self.recordLifecycleDiagnostic("mark-skip-document-missing", current: before)
#endif
                self.markedOwnership.discard()
                return
            }
            self.changing = true
#if DEBUG
            self.recordLifecycleDiagnostic("set-marked-called", current: before)
#endif
            proxy.setMarkedText(text, selectedRange: selection)
            if text.isEmpty { proxy.unmarkText() }
            let after = self.context(for: proxy)
            self.markedOwnership.recordMark(before: before, after: after, isEmpty: text.isEmpty)
            self.expectedContext = after
            self.changing = false
        }
        surface.updateMarkedSelection = mark
        surface.updateMarkedText = { mark($0, NSRange(location: $0.utf16.count, length: 0)) }
        surface.commitMarkedText = { [weak self] text in
            guard let self else { return }
            // insertText replaces the current marked range and commits it in one
            // operation, so a following cursor action does not target marked text.
            self.perform { $0.insertText(text) }
        }
        surface.finishMarkedText = { [weak self] in self?.perform { $0.unmarkText() } }
        surface.commitRawTextAndSpace = { [weak self] left, tail in
            self?.perform { proxy in
                RawSpaceCommit.apply(left: left, tail: tail,
                    setMarked: { proxy.setMarkedText($0, selectedRange: $1) },
                    unmark: { proxy.unmarkText() }, insert: { proxy.insertText($0) })
            }
        }
        surface.moveCursorLeft = { [weak self] in
            guard let self, let last = self.textDocumentProxy.documentContextBeforeInput?.last else { return }
            self.perform { $0.adjustTextPosition(byCharacterOffset: -String(last).utf16.count) }
        }
        surface.moveCursorRight = { [weak self] in
            guard let self, let first = self.textDocumentProxy.documentContextAfterInput?.first else { return }
            self.perform { $0.adjustTextPosition(byCharacterOffset: String(first).utf16.count) }
        }
        surface.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        surface.executeTextMacro = { [weak self] id, clipboard in
            self?.executeTextMacro(id: id, clipboard: clipboard)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        _ = resolveMarkedOwnership(for: textDocumentProxy, event: "appear", onAppearance: true)
        expectedContext = context()
        let access = KeyboardSettings.extensionAccess(hasFullAccess: hasFullAccess)
        settingsAccess = access
        let defaults = access.readDefaults
        surface.candidateBar.clipboardAccessAllowed = hasFullAccess
        surface.candidateBar.automaticallyPreviewClipboard = defaults.bool(forKey: "clipboardAutomaticPreview")
        surface.settingsDefaults = defaults
        surface.settingsWriteDefaults = access.writeDefaults
        surface.bunsetsuSeparation = defaults.bool(forKey: "bunsetsuSeparation")
        surface.onSettingsWritten = { [weak access] keys in access?.didWrite(keys) }
        let clipboardReset = LocalDataReset(store: .clipboard, url: PersonalDataLocation.clipboardURL(allowShared: false), sharedDefaults: defaults, localDefaults: .standard)
        surface.configureClipboard(accessAllowed: hasFullAccess, allowShared: hasFullAccess, localReset: clipboardReset)
        surface.reloadTheme()
        surface.reloadRomaji()
        surface.reloadCustomLayouts()
        surface.reloadAppearance()
        let learningEnabled = defaults.object(forKey: "learningEnabled") == nil || defaults.bool(forKey: "learningEnabled")
        let learningReset = LocalDataReset(store: .learning, url: PersonalDataLocation.learningURL(allowShared: false), sharedDefaults: defaults, localDefaults: .standard)
        surface.configureLearning(url: learningEnabled ? PersonalDataLocation.learningURL(allowShared: hasFullAccess) : nil, localReset: learningReset)
        surface.learnFirstCandidate = defaults.bool(forKey: "learnFirstCandidate")
        updateTextMacroContext()
        surface.reloadSizing()
        do {
            let loaded = try PersonalDataLocation.readableStore().load()
            surface.personalLexicon = loaded.lexicon
            if loaded.recovered { surface.showDataNotice("ユーザー辞書を直前の正常な世代から復元しました") }
        } catch { surface.showDataNotice("ユーザー辞書: " + error.localizedDescription) }
        let rows = KeyboardSettings.candidateRowCount(from: defaults)
        surface.liveConversion = defaults.bool(forKey: "liveConversion")
        surface.omissionSearch = defaults.bool(forKey: "omissionSearch")
        surface.englishReadingEnabled = defaults.object(forKey: "englishReadingEnabled") as? Bool ?? true
        surface.categoryMask = UInt32(defaults.integer(forKey: "categoryMask") & 0x3fff_ffff)
        surface.candidateRowCount = rows
        surface.candidateBar.reloadToolbarSettings(defaults: defaults)
        keyboardHeight.constant = surface.requestedHeight
        ProcessMemory.record("extension.visible")
    }
    private func context() -> Context { context(for: textDocumentProxy) }
    private func context(for proxy: UITextDocumentProxy) -> Context {
        Context(document: DocumentProxyIdentity.read(proxy),
                before: proxy.documentContextBeforeInput,
                after: proxy.documentContextAfterInput,
                selected: proxy.selectedText)
    }

#if DEBUG
    private func recordLifecycleDiagnostic(_ event: String, current: Context,
                                           ownerState: String? = nil,
                                           resolution: MarkedDocumentOwnership.Resolution? = nil) {
        let document = current.document == nil ? "missing" : "present"
        let owner = ownerState ?? markedOwnership.diagnosticState(for: current)
        var entry = "\(event):doc=\(document):owner=\(owner)"
        if let resolution { entry += ":result=\(resolution)" }
        lifecycleTrace.append(entry)
        if lifecycleTrace.count > 12 { lifecycleTrace.removeFirst(lifecycleTrace.count - 12) }
        surface.lifecycleDiagnostics = lifecycleTrace.joined(separator: "|")
    }
#endif

    /// Android finalizes its active composing range when the input view hides.
    /// UIKit may disconnect the keyboard proxy during that transition, so retain
    /// ownership until the same document/context is available and finalize it
    /// before the next key can replace that stale range.
    @discardableResult
    private func resolveMarkedOwnership(for proxy: UITextDocumentProxy,
                                        event: String = "resolve",
                                        onAppearance: Bool = false,
                                        onHide: Bool = false,
                                        invalidateComposition: Bool = true) -> Bool {
        let current = context(for: proxy)
#if DEBUG
        let ownerState = markedOwnership.diagnosticState(for: current)
#endif
        let resolution: MarkedDocumentOwnership.Resolution
        if onHide {
            resolution = markedOwnership.resolveOnHide(current)
        } else if onAppearance {
            resolution = markedOwnership.resolveOnAppearance(current)
        } else {
            resolution = markedOwnership.resolveCurrentContext(current)
        }
#if DEBUG
        recordLifecycleDiagnostic(event, current: current, ownerState: ownerState,
                                  resolution: resolution)
#endif

        switch resolution {
        case .none:
            return true
        case .unmarkOwnedText:
            changing = true
#if DEBUG
            recordLifecycleDiagnostic("unmark-called", current: current)
#endif
            proxy.unmarkText()
            expectedContext = context(for: proxy)
            changing = false
            if invalidateComposition { surface.invalidateComposition() }
            return true
        case .waitForDocument:
            expectedContext = current
            if invalidateComposition { surface.invalidateComposition() }
            return false
        case .discardOwnership:
            expectedContext = current
            if invalidateComposition { surface.invalidateComposition() }
            return true
        }
    }

    private func perform(_ operation: (UITextDocumentProxy) -> Void) {
        let proxy = textDocumentProxy
        guard resolveMarkedOwnership(for: proxy) else { return }
        markedOwnership.discard()
        changing = true
        operation(proxy)
        expectedContext = context()
        changing = false
    }
    private func validateContext() {
        guard !changing else { return }
        let proxy = textDocumentProxy
        guard resolveMarkedOwnership(for: proxy) else { return }
        let current = context(for: proxy)
        if current.document == nil || expectedContext.map({ current != $0 }) == true {
            markedOwnership.discard()
            surface.invalidateComposition()
        }
        expectedContext = current
    }
    override func textDidChange(_ textInput: UITextInput?) {
        updateTextMacroContext()
        validateContext()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        updateTextMacroContext()
        validateContext()
    }

    private func updateTextMacroContext() {
        let proxy = textDocumentProxy
        surface.textMacroSelectionAvailable = proxy.selectedText?.isEmpty == false
        let traits = proxy as UITextInputTraits
        let sensitiveTypes: [UITextContentType] = [.password, .newPassword, .oneTimeCode]
        surface.textMacroContextAllowed = traits.isSecureTextEntry == false &&
            !sensitiveTypes.contains(where: { traits.textContentType == $0 })
    }

    private func executeTextMacro(id: String, clipboard: String?) {
        let proxy = textDocumentProxy
        let initial = context(for: proxy)
        guard let macro = surface.personalLexicon.textMacros.first(where: { $0.id == id && $0.enabled }) else {
            surface.showDataNotice("定型マクロを使用できません")
            return
        }
        do {
            let compiled = try AndroidTextMacroCompiler.compile(macro.body)
            let requirements = compiled.requirements
            guard requirements.isEmpty || surface.textMacroContextAllowed else {
                throw PersonalDataError("この入力欄では選択文字とクリップボードを使うマクロを停止しています")
            }
            if requirements.contains(.clipboard), clipboard == nil {
                surface.showTextMacroList(requiredMacroID: id)
                return
            }
            let selection: String?
            if requirements.contains(.selection) {
                guard let value = proxy.selectedText, !value.isEmpty else {
                    throw PersonalDataError("使う文字を選択してから実行してください")
                }
                selection = value
            } else { selection = nil }
            let clipboardValue: String?
            if requirements.contains(.clipboard) {
                guard let clipboard, !clipboard.isEmpty else {
                    throw PersonalDataError("先に貼り付けボタンからクリップボードの文字を許可してください")
                }
                clipboardValue = clipboard
            } else { clipboardValue = nil }
            let expanded = try compiled.expand(context: AndroidTextMacroContext(
                selection: selection, clipboard: clipboardValue
            ))
            guard context(for: proxy) == initial,
                  surface.personalLexicon.textMacros.first(where: { $0.id == id }) == macro else {
                throw PersonalDataError("入力欄またはマクロが変更されたため、展開を中止しました")
            }
            let cursorDelta = try expanded.cursorAdjustmentUTF16()
            perform { current in
                // insertText replaces the active marked range, matching Android's
                // clear-composing-then-commit behavior. UIKit text-field and text-view
                // coverage is in MarkedTextCommitTests; extension-host behavior remains
                // an external-host acceptance check.
                current.insertText(expanded.text)
                if cursorDelta != 0 { current.adjustTextPosition(byCharacterOffset: cursorDelta) }
            }
            surface.invalidateComposition()
            surface.showDataNotice("定型マクロを展開しました")
        } catch {
            surface.showDataNotice(error.localizedDescription)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        let proxy = textDocumentProxy
        _ = resolveMarkedOwnership(for: proxy, event: "hide", onHide: true, invalidateComposition: false)
        surface.invalidateComposition()
        super.viewWillDisappear(animated)
        expectedContext = nil
        ProcessMemory.record("extension.hidden")
    }

}
