import UIKit
import SumireCore

final class KeyboardViewController: UIInputViewController {
    private let surface = KeyboardSurface()
    private struct Context: Equatable {
        let document: String?
        let before: String?
        let after: String?
        let selected: String?
    }
    private var expectedContext: Context?
    private var changing = false
    private var keyboardHeight: NSLayoutConstraint!
    private var settingsAccess: KeyboardSettingsAccess?
    override func viewDidLoad() {
        super.viewDidLoad()
        ProcessMemory.record("extension.loaded")
        surface.candidateBar.clipboardAccessAllowed = hasFullAccess
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
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
            guard DocumentProxyIdentity.read(self.textDocumentProxy) != nil else { return }
            self.perform {
                $0.setMarkedText(text, selectedRange: selection)
                if text.isEmpty { $0.unmarkText() }
            }
        }
        surface.updateMarkedSelection = mark
        surface.updateMarkedText = { mark($0, NSRange(location: $0.utf16.count, length: 0)) }
        surface.commitMarkedText = { [weak self] text in
            guard let self else { return }
            // insertText replaces the current marked range and commits it in one
            // operation, so a following cursor action does not target marked text.
            self.perform { $0.insertText(text) }
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
        keyboardHeight.constant = surface.requestedHeight
        ProcessMemory.record("extension.visible")
    }
    private func context() -> Context {
        Context(document: DocumentProxyIdentity.read(textDocumentProxy),
                before: textDocumentProxy.documentContextBeforeInput,
                after: textDocumentProxy.documentContextAfterInput,
                selected: textDocumentProxy.selectedText)
    }
    private func perform(_ operation: (UITextDocumentProxy) -> Void) {
        changing = true
        operation(textDocumentProxy)
        expectedContext = context()
        changing = false
    }
    private func validateContext() {
        guard !changing else { return }
        let current = context()
        if current.document == nil || expectedContext.map({ current != $0 }) == true {
            surface.invalidateComposition()
        }
        expectedContext = current
    }
    override func textDidChange(_ textInput: UITextInput?) { validateContext() }
    override func selectionDidChange(_ textInput: UITextInput?) { validateContext() }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        surface.invalidateComposition()
        expectedContext = nil
        ProcessMemory.record("extension.hidden")
    }

}
