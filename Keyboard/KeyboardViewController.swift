import UIKit
import SumireCore
import os

final class KeyboardViewController: UIInputViewController {
    private let session = KeyboardCompositionSession.extensionProcess
    private lazy var surface = KeyboardSurface(frame: .zero, session: session)
    private typealias Context = MarkedDocumentOwnership.Context
    private enum UndoCursorPlacement: Equatable { case beforeDeletedText, afterDeletedText }
    private struct CommittedDeletionUndoEntry {
        let text: String
        let cursorPlacement: UndoCursorPlacement
        let contextAfterDeletion: Context
        let contextAfterUndo: Context
        var hasProvisionalDeletionContext: Bool
    }
    private var markedOwnership: MarkedDocumentOwnership {
        get { session.markedOwnership }
        set { session.markedOwnership = newValue }
    }
    private var expectedContext: Context? {
        get { session.expectedContext }
        set { session.expectedContext = newValue }
    }
    private var committedDeletionHistory: [CommittedDeletionUndoEntry] = []
    private var pendingDeletionUndoContext: Context?
    private let maximumCommittedDeletionHistoryEntries = 64
    private let maximumCommittedDeletionHistoryUTF16Units = 16_384
    private var changing = false
    private var isPreparingAppearance = false
    private var hasReachedViewDidAppear = false
    private var appearanceContextValidated = false
    private var markedOwnerProxy: UITextDocumentProxy?
    private var hostWillResignActiveObserver: NSObjectProtocol?
#if DEBUG
    private let compositionLogger = Logger(subsystem: "com.kazumaproject.sumire.ios", category: "CompositionLease")
    private var compositionTraceControllerIdentifier: UInt64 = 0
#endif
    private var keyboardHeight: NSLayoutConstraint!
    private var settingsAccess: KeyboardSettingsAccess?
    deinit {
        if let hostWillResignActiveObserver {
            NotificationCenter.default.removeObserver(hostWillResignActiveObserver)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        hostWillResignActiveObserver = NotificationCenter.default.addObserver(
            forName: .NSExtensionHostWillResignActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finalizeCompositionBeforeHostDeactivation()
        }
        ProcessMemory.record("extension.loaded")
        surface.candidateBar.clipboardAccessAllowed = hasFullAccess
#if DEBUG
        compositionTraceControllerIdentifier = session.registerDebugController()
        surface.debugCompositionTrace = { [weak self] event in self?.traceCompositionEvent(event) }
        surface.exposeStableFocusFinalizationForDiagnostics { [weak self] in
            self?.finalizeOwnedMarkWithStableFocusForDiagnostics()
        }
        surface.exposeRetainedOwnerFinalizationForDiagnostics { [weak self] in
            self?.finalizeOwnedMarkThroughRetainedProxyWithStableFocusForDiagnostics()
        }
        session.debugCompositionDidChange = { [weak self] in
            self?.traceCompositionEvent("composition.change")
        }
#endif
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.isUserInteractionEnabled = false
        view.addSubview(surface)
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
        surface.beforeInput = { [weak self] in self?.validateContext() ?? false }
        surface.insert = { [weak self] text in self?.perform { $0.insertText(text) } }
        surface.candidateBar.onInsertShortcutText = { [weak self] text in
            guard let self, !self.surface.hasComposition else { return }
            guard self.surface.beforeInput?() ?? false else { return }
            self.surface.insert?(text)
        }
        surface.delete = { [weak self] in self?.deleteBackwardWithHistory() }
        surface.deleteForward = { [weak self] in
            self?.deleteForwardWithHistory()
        }
        surface.deleteAfterCursorUntilBoundary = { [weak self] in
            self?.deleteAfterCursorUntilBoundaryWithHistory()
        }
        surface.canRecordDeletionHistory = { [weak self] in
            guard let self else { return false }
            return !self.isSensitiveInput(self.textDocumentProxy)
        }
        surface.undoDelete = { [weak self] in
            guard let self else { return false }
            if self.isSensitiveInput(self.textDocumentProxy) {
                self.committedDeletionHistory.removeAll(keepingCapacity: true)
                self.pendingDeletionUndoContext = nil
                self.surface.clearCompositionDeletionHistory()
                return false
            }
            return self.surface.undoCompositionDeletion() || self.undoCommittedDeletion()
        }
        surface.deleteUntilBoundary = { [weak self] in
            self?.deleteUntilBoundaryWithHistory()
        }
        let mark: (String, NSRange, UInt64) -> Void = { [weak self] text, selection, generation in
            guard let self else { return }
            self.traceCompositionEvent("mark.enter", generation: generation)
            guard !self.isPreparingAppearance,
                  self.hasReachedViewDidAppear, self.appearanceContextValidated,
                  generation == self.session.composition.generation else {
                self.traceCompositionEvent("mark.reject-lifecycle", generation: generation)
                return
            }
            // Empty editors may return nil on both sides of the insertion point.
            // That does not mean marked text is unsupported. Keep the reading in
            // the surface as well, so hosts ignoring marked text can still commit.
            let proxy = self.textDocumentProxy
            guard self.resolveSuspendedMark(for: proxy), self.appearanceContextValidated,
                  generation == self.session.composition.generation else {
                self.traceCompositionEvent("mark.reject-owner", proxy: proxy, generation: generation)
                return
            }
            let before = self.context(for: proxy)
            guard let expected = self.expectedContext, expected.document != nil,
                  before == expected, self.markedOwnership.canUpdateMark(in: before),
                  self.context(for: proxy) == expected else {
                self.traceCompositionEvent("mark.reject-context", proxy: proxy, generation: generation)
                self.rejectStaleHostWrite(for: proxy)
                return
            }
            self.committedDeletionHistory.removeAll(keepingCapacity: true)
            self.pendingDeletionUndoContext = nil
            self.surface.clearCompositionDeletionHistory()
            self.changing = true
            proxy.setMarkedText(text, selectedRange: selection)
            if text.isEmpty {
                proxy.unmarkText()
                self.markedOwnerProxy = nil
            }
            let after = self.context(for: proxy)
            let acceptedMark = self.markedOwnership.recordMark(
                before: before, after: after, isEmpty: text.isEmpty
            )
            if acceptedMark {
                if self.markedOwnerProxy == nil { self.markedOwnerProxy = proxy }
            } else {
                // Do not let an unaccepted mark leave a proxy that a later
                // composition could mistake for the current owner.
                self.markedOwnerProxy = nil
                if !text.isEmpty {
                    // The proxy write already happened, but the controller
                    // cannot safely attribute it to a document after ownership
                    // changed. Drop the local reading so a later key cannot
                    // replay it into the newly observed context.
                    self.session.needsCompositionRefresh = false
                    self.session.hostFocusChangedWhileSuspended = false
                    self.session.needsHostMarkRestore = false
                    self.surface.invalidateComposition()
                }
            }
#if DEBUG
            if let reason = self.markedOwnership.debugLastDiscardReason {
                self.traceCompositionEvent("ownership.discard", proxy: proxy,
                                           detail: "reason=mark-\(reason.rawValue)")
            }
#endif
            self.expectedContext = after
            self.changing = false
            self.traceCompositionEvent("mark.wrote", proxy: proxy, generation: generation)
            if acceptedMark {
                self.traceCompositionEvent("mark.accepted", proxy: proxy, generation: generation)
            }
        }
        surface.updateMarkedSelection = mark
        surface.updateMarkedText = { mark($0, NSRange(location: $0.utf16.count, length: 0), $1) }
        surface.commitMarkedText = { [weak self] text in
            guard let self else { return }
            // insertText replaces the current marked range and commits it in one
            // operation, so a following cursor action does not target marked text.
            self.perform { $0.insertText(text) }
        }
        surface.finishMarkedText = { [weak self] in
            guard let self else { return }
            self.perform { proxy in
                self.traceCompositionEvent("mark.finalize.request", proxy: proxy)
                proxy.unmarkText()
                self.traceCompositionEvent("mark.finalize.return", proxy: proxy)
            }
        }
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
        committedDeletionHistory.removeAll(keepingCapacity: true)
        pendingDeletionUndoContext = nil
        surface.clearCompositionDeletionHistory()
        traceCompositionEvent("lifecycle.will-appear")
        surface.isUserInteractionEnabled = false
        hasReachedViewDidAppear = false
        appearanceContextValidated = false
        isPreparingAppearance = true
        defer { isPreparingAppearance = false }
        // Invalidate async conversion work before reconfiguring the surface.
        // The proxy may still point at the previous editor during attachment.
        surface.suspendCompositionDisplay()
        // Do not resolve a suspended mark against the proxy during
        // viewWillAppear. UIKit may still expose the previously active editor
        // while attaching the keyboard to the newly focused host. In that
        // window, restoring the composition would write the old reading into
        // the new editor before the user presses a key.
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        traceCompositionEvent("lifecycle.did-appear.begin")
        hasReachedViewDidAppear = true
        appearanceContextValidated = false
        let wasSuspended = session.needsCompositionRefresh
        let focusChangedWhileSuspended = session.hostFocusChangedWhileSuspended
        // Revalidate the owner after every appearance. The keyboard can remain
        // alive while a host switches between fields, so a false suspension
        // flag is not evidence that the proxy still targets the old document.
        let canResumeComposition = resolveSuspendedMark(
            for: textDocumentProxy, onAppearance: true, deferCompositionRefresh: true)
        guard canResumeComposition else {
            surface.isUserInteractionEnabled = false
            traceCompositionEvent("lifecycle.did-appear.wait")
            return
        }
        appearanceContextValidated = true
        session.needsCompositionRefresh = false
        session.hostFocusChangedWhileSuspended = false
        let reapplyHostMark = session.needsHostMarkRestore
        session.needsHostMarkRestore = false
        expectedContext = context()
        // Rebuild candidates without a host write when the existing mark is
        // present. If UIKit dropped it, only the guarded baseline-context
        // resolution may request reattachment.
        surface.restoreCompositionAfterControllerRecreation(reapplyHostMark: reapplyHostMark)
        surface.isUserInteractionEnabled = true
        traceCompositionEvent("lifecycle.did-appear.ready",
                              detail: "suspended=\(wasSuspended);hostReplay=\(reapplyHostMark ? "reattach" : "false");focusChanged=\(focusChangedWhileSuspended)")
    }

    private func context() -> Context { context(for: textDocumentProxy) }
    private func context(for proxy: UITextDocumentProxy) -> Context {
        Context(document: DocumentProxyIdentity.read(proxy),
                before: proxy.documentContextBeforeInput,
                after: proxy.documentContextAfterInput,
                selected: proxy.selectedText)
    }

    /// A proxy disconnection cannot identify a host document. If the first
    /// appearance still has no document, keep the token suspended and apply
    /// the same appearance policy when a later callback exposes one.
    @discardableResult
    private func resolveSuspendedMark(for proxy: UITextDocumentProxy, onAppearance: Bool = false,
                                      deferCompositionRefresh: Bool = false) -> Bool {
        let current = context(for: proxy)
#if DEBUG
        let ownershipComparison = markedOwnership.debugContextComparison(current)
#endif
        let resolution = onAppearance
            ? markedOwnership.resolveOnAppearance(
                current, discardSuspended: session.hostFocusChangedWhileSuspended)
            : markedOwnership.resolveCurrentContext(current)
#if DEBUG
        let discardReason = markedOwnership.debugLastDiscardReason?.rawValue ?? "none"
        let resolutionName: String
        switch resolution {
        case .none: resolutionName = "none"
        case .preserveOwnedText: resolutionName = "preserve"
        case .restoreOwnedText: resolutionName = "restore"
        case .waitForDocument: resolutionName = "wait"
        case .discardOwnership: resolutionName = "discard"
        }
        traceCompositionEvent("owner.resolve.\(onAppearance ? "appearance" : "current").\(resolutionName)",
                              proxy: proxy, detail: "reason=\(discardReason);\(ownershipComparison)")
#endif
        switch resolution {
        case .none:
            guard current.document != nil else {
                // No lease plus a disconnected proxy is not a validated input
                // target. Drop unowned local composition and keep every key
                // disabled until a later callback exposes a document.
                expectedContext = current
                session.needsCompositionRefresh = false
                session.hostFocusChangedWhileSuspended = false
                session.needsHostMarkRestore = false
                surface.isUserInteractionEnabled = false
                if surface.hasComposition {
#if DEBUG
                    traceCompositionInvalidation(reason: "disconnected-proxy-without-owner", proxy: proxy)
#endif
                    surface.invalidateComposition()
                }
                else { surface.suspendCompositionDisplay() }
                markedOwnerProxy = nil
                return false
            }
            if onAppearance, surface.hasComposition {
                // A reading without a recorded host mark cannot be attached to
                // whichever editor the proxy happens to expose after reentry.
                expectedContext = current
                session.needsCompositionRefresh = false
                session.hostFocusChangedWhileSuspended = false
                session.needsHostMarkRestore = false
#if DEBUG
                traceCompositionInvalidation(reason: "appearance-without-owned-mark", proxy: proxy)
#endif
                surface.invalidateComposition()
                markedOwnerProxy = nil
            }
            return true
        case .preserveOwnedText:
            expectedContext = context(for: proxy)
            session.needsHostMarkRestore = false
            if onAppearance { session.hostFocusChangedWhileSuspended = false }
            if session.needsCompositionRefresh && !deferCompositionRefresh {
                session.needsCompositionRefresh = false
                surface.restoreCompositionAfterControllerRecreation()
            }
            return true
        case .restoreOwnedText:
            expectedContext = context(for: proxy)
            session.needsHostMarkRestore = true
            if onAppearance { session.hostFocusChangedWhileSuspended = false }
            if session.needsCompositionRefresh && !deferCompositionRefresh {
                session.needsCompositionRefresh = false
                session.needsHostMarkRestore = false
                surface.restoreCompositionAfterControllerRecreation(reapplyHostMark: true)
            }
            return true
        case .waitForDocument:
            expectedContext = current
            session.needsCompositionRefresh = true
            if !deferCompositionRefresh {
                // An active keyboard seeing a proxy disconnection may be in
                // the middle of a host focus transition. Fail closed on resume
                // unless the disconnection was already part of appearance
                // attachment, where UIKit commonly exposes nil transiently.
                session.hostFocusChangedWhileSuspended = true
            }
            surface.isUserInteractionEnabled = false
            if !deferCompositionRefresh { surface.suspendCompositionDisplay() }
            return false
        case .discardOwnership:
            expectedContext = context(for: proxy)
            session.needsCompositionRefresh = false
            session.needsHostMarkRestore = false
            if onAppearance { session.hostFocusChangedWhileSuspended = false }
#if DEBUG
            traceCompositionInvalidation(reason: "resolver-\(discardReason)", proxy: proxy)
#endif
            surface.invalidateComposition()
            markedOwnerProxy = nil
            return true
        }
    }

    private func perform(_ operation: (UITextDocumentProxy) -> Void) {
        perform(operation, preservingDeletionHistory: false)
    }

    private func perform(_ operation: (UITextDocumentProxy) -> Void, preservingDeletionHistory: Bool) {
        traceCompositionEvent("perform.enter")
        guard hasReachedViewDidAppear, appearanceContextValidated, !isPreparingAppearance else {
            traceCompositionEvent("perform.reject-lifecycle")
            return
        }
        let proxy = textDocumentProxy
        guard resolveSuspendedMark(for: proxy), appearanceContextValidated else {
            traceCompositionEvent("perform.reject-owner", proxy: proxy)
            return
        }
        let before = context(for: proxy)
        guard let expected = expectedContext, expected.document != nil, before == expected,
              self.context(for: proxy) == expected else {
            traceCompositionEvent("perform.reject-context", proxy: proxy)
            rejectStaleHostWrite(for: proxy)
            return
        }
        surface.clearCompositionDeletionHistory()
        if !preservingDeletionHistory {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            pendingDeletionUndoContext = nil
        }
#if DEBUG
        traceOwnershipDiscard(reason: "host-write-started", proxy: proxy)
#endif
        markedOwnership.discard()
        markedOwnerProxy = nil
        changing = true
        operation(proxy)
        expectedContext = context(for: proxy)
        changing = false
        traceCompositionEvent("perform.wrote", proxy: proxy)
    }

    @discardableResult
    private func validateContext() -> Bool {
        // Lifecycle configuration may refresh local settings before the surface
        // becomes interactive. Actual key actions remain disabled until didAppear.
        if isPreparingAppearance { return true }
        guard hasReachedViewDidAppear, !changing else { return false }
        let proxy = textDocumentProxy
        // viewDidAppear can arrive before UIKit reconnects the document proxy.
        // While that appearance remains unresolved, later callbacks must use
        // appearance revalidation (including the observed-focus veto), rather
        // than the stricter active-context path that would discard a renewed
        // document identifier unconditionally.
        let isResolvingDeferredAppearance = session.needsCompositionRefresh
        guard resolveSuspendedMark(for: proxy, onAppearance: isResolvingDeferredAppearance,
                                   deferCompositionRefresh: isResolvingDeferredAppearance) else {
            appearanceContextValidated = false
            surface.isUserInteractionEnabled = false
            return false
        }
        let current = context(for: proxy)
        var pendingUndoContextIsIncomplete = false
        if let pending = pendingDeletionUndoContext {
            if current.matchesDeletionUndoSnapshot(pending) {
                pendingDeletionUndoContext = nil
            } else if current.hasMissingSideComparedTo(pending) {
                pendingUndoContextIsIncomplete = true
            } else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                pendingDeletionUndoContext = nil
            }
        }
        if !pendingUndoContextIsIncomplete,
           let lastIndex = committedDeletionHistory.indices.last {
            let entry = committedDeletionHistory[lastIndex]
            if current.matchesDeletionUndoSnapshot(entry.contextAfterDeletion) {
                let hasContextAnchor = entry.contextAfterDeletion.before?.isEmpty == false ||
                    entry.contextAfterDeletion.after?.isEmpty == false
                if !entry.hasProvisionalDeletionContext || hasContextAnchor {
                    committedDeletionHistory[lastIndex].hasProvisionalDeletionContext = false
                }
            } else if entry.hasProvisionalDeletionContext &&
                        current.matchesDeletionUndoSnapshot(
                            entry.contextAfterDeletion,
                            allowUnavailableTrailingContext: true
                        ) {
                // Keep the entry provisional: the host has exposed trailing
                // text that was outside the proxy context window at deletion.
            } else if entry.hasProvisionalDeletionContext &&
                        (current.before == nil || current.after == nil) {
                // UITextDocumentProxy can briefly expose a partial context after
                // moving across a supplementary grapheme. Keep the candidate
                // only until a complete context can confirm or reject it; undo
                // still requires an exact match with contextAfterDeletion.
            } else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
            }
        }
        if isSensitiveInput(textDocumentProxy) {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            pendingDeletionUndoContext = nil
            surface.clearCompositionDeletionHistory()
        }
        if current.document == nil || expectedContext.map({ current != $0 }) == true {
#if DEBUG
            let reason = current.document == nil ? "validate-missing-document" : "validate-context-drift"
            traceOwnershipDiscard(reason: reason, proxy: proxy)
#endif
            markedOwnership.discard()
            markedOwnerProxy = nil
            surface.invalidateComposition()
        }
        expectedContext = current
        appearanceContextValidated = current.document != nil
        if !appearanceContextValidated {
            surface.isUserInteractionEnabled = false
            return false
        }
        if isResolvingDeferredAppearance, session.needsCompositionRefresh, appearanceContextValidated {
            // A delayed proxy reconnection is now validated against its owner.
            // Restore candidates and any authorized host mark only after the
            // lifecycle write guard has been reopened.
            session.needsCompositionRefresh = false
            session.hostFocusChangedWhileSuspended = false
            let reapplyHostMark = session.needsHostMarkRestore
            session.needsHostMarkRestore = false
            surface.restoreCompositionAfterControllerRecreation(reapplyHostMark: reapplyHostMark)
        }
        surface.isUserInteractionEnabled = appearanceContextValidated
        return appearanceContextValidated
    }

    private func rejectStaleHostWrite(for proxy: UITextDocumentProxy) {
        traceCompositionEvent("host-write.reject", proxy: proxy)
        let current = context(for: proxy)
#if DEBUG
        traceOwnershipDiscard(reason: "stale-host-write-rejected", proxy: proxy)
#endif
        markedOwnership.discard()
        markedOwnerProxy = nil
        session.needsCompositionRefresh = false
        surface.invalidateComposition()
        expectedContext = current
        appearanceContextValidated = hasReachedViewDidAppear && current.document != nil
    }

    private func finalizeCompositionBeforeHostDeactivation() {
        guard surface.hasComposition else { return }
        let proxy = textDocumentProxy
        let current = context(for: proxy)
        guard hasReachedViewDidAppear, appearanceContextValidated, !changing,
              !session.needsCompositionRefresh, expectedContext == current,
              markedOwnership.canFinalizeMark(in: current) else { return }

        var didFinalize = false
        perform { proxy in
            self.traceCompositionEvent("lifecycle.host-will-resign-active", proxy: proxy)
            proxy.unmarkText()
            didFinalize = true
        }
        guard didFinalize else { return }
        surface.invalidateComposition()
    }

#if DEBUG
    /// Test-only entry point for checking the exact proxy unmark path without
    /// changing the host responder. It retains the normal owner/context vetoes.
    private func finalizeOwnedMarkWithStableFocusForDiagnostics() {
        let proxy = textDocumentProxy
        let current = context(for: proxy)
        let contextMatches = expectedContext == current
        let ownerMatches = markedOwnership.canFinalizeMark(in: current)
        guard surface.hasComposition, hasReachedViewDidAppear,
              appearanceContextValidated, !isPreparingAppearance, !changing,
              !session.needsCompositionRefresh, contextMatches, ownerMatches else {
            traceCompositionEvent(
                "debug.stable-focus.finalization-rejected",
                proxy: proxy,
                detail: "composition=\(surface.hasComposition);appeared=\(hasReachedViewDidAppear);validated=\(appearanceContextValidated);context=\(contextMatches);owner=\(ownerMatches)"
            )
            return
        }

        traceCompositionEvent("debug.stable-focus.finalization-request", proxy: proxy)
        let traceSequenceBeforeFinalize = session.debugCompositionTraceSequence
        surface.finishMarkedText?()

        let newTraceEvents = session.debugCompositionTraceEvents.filter { entry in
            guard let sequenceField = entry.split(separator: ";", maxSplits: 1).first,
                  sequenceField.hasPrefix("seq="),
                  let sequence = UInt64(sequenceField.dropFirst("seq=".count)) else { return false }
            return sequence > traceSequenceBeforeFinalize &&
                entry.contains(";controller=\(compositionTraceControllerIdentifier);")
        }
        let didRequestUnmark = newTraceEvents.contains { $0.contains(";event=mark.finalize.request;") }
        let didReturnFromUnmark = newTraceEvents.contains { $0.contains(";event=mark.finalize.return;") }
        traceCompositionEvent(
            "debug.stable-focus.finalization-result",
            proxy: proxy,
            detail: "request=\(didRequestUnmark);return=\(didReturnFromUnmark)"
        )
        guard didRequestUnmark, didReturnFromUnmark else { return }

        surface.invalidateComposition()
        traceCompositionEvent("debug.stable-focus.finalization-return", proxy: proxy)
    }

    /// Test-only same-focus control for the proxy retained with the owned mark.
    /// Require both the current and retained proxy to match the exact lease
    /// before writing, so this control cannot finalize a different host field.
    private func finalizeOwnedMarkThroughRetainedProxyWithStableFocusForDiagnostics() {
        let currentProxy = textDocumentProxy
        let current = context(for: currentProxy)
        guard let ownerProxy = markedOwnerProxy else {
            traceCompositionEvent(
                "debug.stable-owner.finalization-rejected",
                proxy: currentProxy,
                detail: "ownerProxy=false;composition=\(surface.hasComposition)"
            )
            return
        }

        let ownerContext = context(for: ownerProxy)
        let expectedMatchesCurrent = expectedContext == current
        let expectedMatchesOwner = expectedContext == ownerContext
        let currentMatchesOwner = current == ownerContext
        let ownerCanFinalize = markedOwnership.canFinalizeMark(in: ownerContext)
        guard surface.hasComposition, hasReachedViewDidAppear,
              appearanceContextValidated, !isPreparingAppearance, !changing,
              !session.needsCompositionRefresh, expectedMatchesCurrent,
              expectedMatchesOwner, currentMatchesOwner, ownerCanFinalize else {
            traceCompositionEvent(
                "debug.stable-owner.finalization-rejected",
                proxy: ownerProxy,
                detail: "ownerProxy=true;composition=\(surface.hasComposition);appeared=\(hasReachedViewDidAppear);validated=\(appearanceContextValidated);expectedCurrent=\(expectedMatchesCurrent);expectedOwner=\(expectedMatchesOwner);proxiesEqual=\(currentMatchesOwner);owner=\(ownerCanFinalize)"
            )
            return
        }

        let before = markedOwnership.debugContextComparison(ownerContext)
            .replacingOccurrences(of: ";", with: ",")
        let traceSequenceBeforeFinalize = session.debugCompositionTraceSequence
        traceCompositionEvent("debug.stable-owner.finalization-request", proxy: ownerProxy,
                              detail: "target=retained-owner-proxy,\(before)")
        traceCompositionEvent("mark.finalize.request", proxy: ownerProxy,
                              detail: "target=retained-owner-proxy,\(before)")
        changing = true
        ownerProxy.unmarkText()
        changing = false

        let after = markedOwnership.debugContextComparison(context(for: ownerProxy))
            .replacingOccurrences(of: ";", with: ",")
        traceCompositionEvent("mark.finalize.return", proxy: ownerProxy,
                              detail: "target=retained-owner-proxy,\(after)")
        let newTraceEvents = session.debugCompositionTraceEvents.filter { entry in
            guard let sequenceField = entry.split(separator: ";", maxSplits: 1).first,
                  sequenceField.hasPrefix("seq="),
                  let sequence = UInt64(sequenceField.dropFirst("seq=".count)) else { return false }
            return sequence > traceSequenceBeforeFinalize &&
                entry.contains(";controller=\(compositionTraceControllerIdentifier);")
        }
        let didRequestUnmark = newTraceEvents.contains { $0.contains(";event=mark.finalize.request;") }
        let didReturnFromUnmark = newTraceEvents.contains { $0.contains(";event=mark.finalize.return;") }
        traceCompositionEvent(
            "debug.stable-owner.finalization-result",
            proxy: ownerProxy,
            detail: "request=\(didRequestUnmark);return=\(didReturnFromUnmark);ownerAfter=\(after)"
        )
        guard didRequestUnmark, didReturnFromUnmark else { return }

        surface.invalidateComposition()
        traceCompositionEvent("debug.stable-owner.finalization-return", proxy: ownerProxy)
    }
#endif

    override func textWillChange(_ textInput: UITextInput?) {
        traceCompositionEvent("callback.text-will-change", inputAvailable: textInput != nil)
        // A proxy can still report the old document identifier while UIKit is
        // routing a focus transition to another field. The helper finalizes only
        // when the exact marked-document owner and context still match.
        guard !changing, hasReachedViewDidAppear, appearanceContextValidated,
              !session.needsCompositionRefresh, surface.hasComposition else { return }
        discardLocalCompositionBeforeContextChange(event: "callback.text-will-change.discarded-local")
    }
    override func textDidChange(_ textInput: UITextInput?) {
        traceCompositionEvent("callback.text-did-change", inputAvailable: textInput != nil)
        updateTextMacroContext()
        validateContext()
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        traceCompositionEvent("callback.selection-did-change", inputAvailable: textInput != nil)
        updateTextMacroContext()
        validateContext()
    }
    override func selectionWillChange(_ textInput: UITextInput?) {
        // UITextDocumentProxy does not expose field identity. Finalize a mark
        // only while the proxy still matches its exact owner context; a proxy
        // that has already switched to another editor must never receive it.
#if DEBUG
        let suspendedComparison = session.needsCompositionRefresh
            ? markedOwnership.debugContextComparison(context()) : nil
#else
        let suspendedComparison: String? = nil
#endif
        traceCompositionEvent("callback.selection-will-change", inputAvailable: textInput != nil,
                              detail: suspendedComparison)
        if session.needsCompositionRefresh {
            // A focus transition observed while the keyboard was suspended
            // invalidates the suspended lease even if a replacement editor
            // exposes identical document/text context values.
            session.hostFocusChangedWhileSuspended = true
            return
        }
        discardLocalCompositionBeforeContextChange(event: "callback.selection-will-change.discarded-local")
    }

    private func discardLocalCompositionBeforeContextChange(event: String) {
        guard !changing, !session.needsCompositionRefresh, surface.hasComposition else { return }
        let proxy = textDocumentProxy
        let current = context(for: proxy)
#if DEBUG
        let ownershipComparison = markedOwnership.debugContextComparison(current)
#else
        let ownershipComparison = "unavailable"
#endif
        let expectedContextMatches = expectedContext == current
        let canFinalizeMark = markedOwnership.canFinalizeMark(in: current)
        if expectedContextMatches, canFinalizeMark {
            if let ownerProxy = markedOwnerProxy {
                // Keep the exact proxy object used for the owner's marked-text
                // write. The controller's current proxy can be retargeted to
                // the next field before UIKit delivers this callback.
                traceCompositionEvent("context-change.finalize-marked-owner", proxy: proxy)
                #if DEBUG
                let ownerContextAtRequest = markedOwnership
                    .debugContextComparison(context(for: ownerProxy))
                    .replacingOccurrences(of: ";", with: ",")
                #else
                let ownerContextAtRequest = "unavailable"
                #endif
                traceCompositionEvent("mark.finalize.request", proxy: ownerProxy,
                                      detail: "target=marked-owner-proxy,\(ownerContextAtRequest)")
                changing = true
                ownerProxy.unmarkText()
                changing = false
                #if DEBUG
                let ownerContextAtReturn = markedOwnership
                    .debugContextComparison(context(for: ownerProxy))
                    .replacingOccurrences(of: ";", with: ",")
                #else
                let ownerContextAtReturn = "unavailable"
                #endif
                traceCompositionEvent("mark.finalize.return", proxy: ownerProxy,
                                      detail: "target=marked-owner-proxy,\(ownerContextAtReturn)")
            } else {
                traceCompositionEvent("mark.finalize.owner-proxy-unavailable", proxy: proxy)
            }
        }
        appearanceContextValidated = false
        expectedContext = context()
#if DEBUG
        traceOwnershipDiscard(reason: "context-change", proxy: proxy)
#endif
        markedOwnership.discard()
        markedOwnerProxy = nil
        session.needsHostMarkRestore = false
        surface.invalidateComposition()
        traceCompositionEvent(event, proxy: proxy,
                              detail: "expected=\(expectedContextMatches);before-discard=\(ownershipComparison)")
    }

    private func isSensitiveInput(_ proxy: UITextDocumentProxy) -> Bool {
        let traits = proxy as UITextInputTraits
        return traits.isSecureTextEntry == true ||
            [UITextContentType.password, .newPassword, .oneTimeCode]
                .contains(where: { traits.textContentType == $0 })
    }

    private func deleteBackwardWithHistory() {
        let proxy = textDocumentProxy
        guard !isSensitiveInput(proxy) else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            perform { $0.deleteBackward() }
            return
        }
        let before = context(for: proxy)
        if let selected = before.selected, !selected.isEmpty {
            guard let remaining = remainingContextAfterSelection(selected, in: before) else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                perform { $0.deleteBackward() }
                return
            }
            // Android records this as a BeforeCursor deletion and restores it
            // with commitText(text, 1), which leaves the caret after the text.
            let restored = Context(document: before.document,
                                   before: before.before.map { $0 + selected },
                                   after: remaining, selected: nil)
            performTrackedDeletion(
                selected, placement: .afterDeletedText, before: before, restored: restored,
                provisionalAfterDeletion: Context(document: before.document,
                                                  before: before.before, after: remaining, selected: nil),
                operation: { $0.deleteBackward() },
                confirms: { after in
                    after.before == before.before && after.after == remaining && after.selected?.isEmpty != false
                }
            )
            return
        }
        guard let beforeText = before.before, let deleted = beforeText.last else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            perform { $0.deleteBackward() }
            return
        }
        let text = String(deleted)
        let restored = Context(document: before.document, before: before.before,
                               after: before.after, selected: nil)
        performTrackedDeletion(
            text, placement: .afterDeletedText, before: before, restored: restored,
            operation: { $0.deleteBackward() },
            confirms: { after in
                after.before != before.before && after.before?.hasSuffix(String(beforeText.dropLast())) == true &&
                    after.after == before.after
            }
        )
    }

    private func deleteForwardWithHistory() {
        let proxy = textDocumentProxy
        guard !isSensitiveInput(proxy) else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            if proxy.selectedText?.isEmpty == false {
                perform { $0.deleteBackward() }
            } else if let next = proxy.documentContextAfterInput?.first {
                let offset = String(next).utf16.count
                perform { current in
                    current.adjustTextPosition(byCharacterOffset: offset)
                    current.deleteBackward()
                }
            }
            return
        }
        let before = context(for: proxy)
        switch ForwardDeletePlanner.plan(selectedText: before.selected, contextAfterInput: before.after) {
        case .deleteSelection:
            guard let selected = before.selected, !selected.isEmpty else { return }
            guard let remaining = remainingContextAfterSelection(selected, in: before) else {
                // Do not create undo text unless the proxy exposes the selected
                // position's trailing context, allowing a post-delete context
                // comparison against the content outside the selected range.
                committedDeletionHistory.removeAll(keepingCapacity: true)
                perform { $0.deleteBackward() }
                return
            }
            let restored = Context(document: before.document, before: before.before,
                                   after: selected + remaining, selected: nil)
            performTrackedDeletion(
                selected, placement: .beforeDeletedText, before: before, restored: restored,
                provisionalAfterDeletion: Context(document: before.document,
                                                  before: before.before, after: remaining, selected: nil),
                operation: { $0.deleteBackward() },
                confirms: { after in
                    after.before == before.before && after.after == remaining && after.selected?.isEmpty != false
                }
            )
        case .deleteAfterCursor(let offset):
            guard let after = before.after, let next = after.first else { return }
            let deleted = String(next)
            let remaining = String(after.dropFirst())
            let restored = Context(document: before.document, before: before.before,
                                   after: deleted + remaining, selected: nil)
            performTrackedDeletion(
                deleted, placement: .beforeDeletedText, before: before, restored: restored,
                provisionalAfterDeletion: before.before.map {
                    Context(document: before.document, before: $0,
                            after: remaining, selected: nil)
                },
                operation: { proxy in
                    proxy.adjustTextPosition(byCharacterOffset: offset)
                    proxy.deleteBackward()
                },
                confirms: { after in
                    after.before == before.before && after.after?.hasPrefix(remaining) == true &&
                        after.after != before.after
                }
            )
        case .noOp:
            return
        }
    }

    private func deleteAfterCursorUntilBoundaryWithHistory() {
        let proxy = textDocumentProxy
        let before = context(for: proxy)
        guard before.selected?.isEmpty != false,
              let trailing = before.after, !trailing.isEmpty else { return }
        let symbols = surface.settingsDefaults.string(forKey: DeletionBoundary.settingsKey) ??
            DeletionBoundary.defaultSymbols
        let count = DeletionBoundary.forwardCount(context: trailing, symbols: symbols)
        guard count > 0 else { return }
        let deleted = String(trailing.prefix(count))
        let remaining = String(trailing.dropFirst(count))
        let restored = Context(document: before.document, before: before.before,
                               after: before.after, selected: nil)
        let provisional = Context(document: before.document, before: before.before,
                                  after: remaining, selected: nil)
        let operation: (UITextDocumentProxy) -> Void = { current in
            for character in deleted {
                current.adjustTextPosition(byCharacterOffset: String(character).utf16.count)
                current.deleteBackward()
            }
        }
        guard !isSensitiveInput(proxy) else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            perform(operation)
            return
        }
        performTrackedDeletion(
            deleted, placement: .beforeDeletedText, before: before, restored: restored,
            provisionalAfterDeletion: provisional,
            operation: operation,
            confirms: { after in
                !remaining.isEmpty && after.before == before.before &&
                    after.after?.hasPrefix(remaining) == true &&
                    after.after != before.after && after.selected?.isEmpty != false
            }
        )
    }

    private func deleteUntilBoundaryWithHistory() {
        let proxy = textDocumentProxy
        let symbols = surface.settingsDefaults.string(forKey: DeletionBoundary.settingsKey) ?? DeletionBoundary.defaultSymbols
        guard !isSensitiveInput(proxy) else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            let count = DeletionBoundary.backwardCount(
                context: proxy.documentContextBeforeInput ?? "", symbols: symbols
            )
            guard count > 0 else { return }
            perform { current in for _ in 0..<count { current.deleteBackward() } }
            return
        }
        let before = context(for: proxy)
        let selected = before.selected.flatMap { $0.isEmpty ? nil : $0 }
        let count = selected == nil
            ? DeletionBoundary.backwardCount(context: before.before ?? "", symbols: symbols)
            : 1
        guard count > 0 else { return }
        let text: String
        let placement: UndoCursorPlacement
        let restored: Context
        let confirms: (Context) -> Bool
        if let selected {
            guard let remaining = remainingContextAfterSelection(selected, in: before) else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                perform { proxy in for _ in 0..<count { proxy.deleteBackward() } }
                return
            }
            text = selected
            placement = .beforeDeletedText
            restored = Context(document: before.document, before: before.before,
                               after: selected + remaining, selected: nil)
            confirms = { after in
                after.before == before.before && after.after == remaining && after.selected?.isEmpty != false
            }
        } else {
            guard let beforeText = before.before, beforeText.count >= count else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                perform { proxy in for _ in 0..<count { proxy.deleteBackward() } }
                return
            }
            text = String(beforeText.suffix(count))
            placement = .afterDeletedText
            restored = Context(document: before.document, before: before.before,
                               after: before.after, selected: nil)
            let expectedPrefix = String(beforeText.dropLast(count))
            confirms = { after in
                after.before != before.before && after.before?.hasSuffix(expectedPrefix) == true &&
                    after.after == before.after
            }
        }
        performTrackedDeletion(
            text, placement: placement, before: before, restored: restored,
            provisionalAfterDeletion: placement == .beforeDeletedText
                ? Context(document: before.document, before: before.before,
                          after: restored.after.map { String($0.dropFirst(text.count)) }, selected: nil)
                : nil,
            operation: { proxy in for _ in 0..<count { proxy.deleteBackward() } },
            confirms: confirms
        )
    }

    /// If the trailing context starts with the selected text, the proxy snapshot
    /// cannot tell whether that prefix is the selection or identical text after
    /// a host that excludes the selection. Decline undo history for that ambiguous
    /// shape; guessing could retain the wrong post-delete context.
    private func remainingContextAfterSelection(_ selected: String, in context: Context) -> String? {
        guard let trailing = context.after else { return nil }
        guard !trailing.hasPrefix(selected) else { return nil }
        return trailing
    }

    private func performTrackedDeletion(
        _ deletedText: String,
        placement: UndoCursorPlacement,
        before: Context,
        restored: Context,
        provisionalAfterDeletion: Context? = nil,
        operation: (UITextDocumentProxy) -> Void,
        confirms: (Context) -> Bool
    ) {
        let hasComposition = surface.hasComposition
        let sensitive = isSensitiveInput(textDocumentProxy)
        let textUnits = deletedText.utf16.count
        guard !hasComposition, !sensitive,
              let document = before.document,
              !deletedText.isEmpty, textUnits <= 16_384 else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            perform(operation)
            return
        }
        if pendingDeletionUndoContext != nil {
            // A new edit arrived before UIKit supplied an anchored context for
            // the previous undo. Keep the user edit, but discard uncertain undo.
            committedDeletionHistory.removeAll(keepingCapacity: true)
            pendingDeletionUndoContext = nil
        }
        if let prior = committedDeletionHistory.last, prior.contextAfterDeletion != before {
            committedDeletionHistory.removeAll(keepingCapacity: true)
        }
        perform(operation, preservingDeletionHistory: true)
        let after = context()
        let sameDocument = after.document == document
        let noSelection = after.selected?.isEmpty != false
        let hasBothAfterContexts = after.before != nil && after.after != nil
        let deletionConfirmed = confirms(after)
        let provisionalContextIsPlausible = !deletionConfirmed &&
            provisionalAfterDeletion != nil && sameDocument && noSelection &&
            after != before && !hasBothAfterContexts
        // A boundary deletion at the start of a document may have no `before`
        // context even when the proxy confirms the remaining text exactly.
        // Do not require both context sides when the operation-specific check
        // already confirms the deletion.
        guard sameDocument, noSelection,
              (deletionConfirmed || provisionalContextIsPlausible) else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            return
        }
        let entry = CommittedDeletionUndoEntry(
            text: deletedText,
            cursorPlacement: placement,
            contextAfterDeletion: deletionConfirmed ? after : provisionalAfterDeletion!,
            contextAfterUndo: restored,
            hasProvisionalDeletionContext: provisionalContextIsPlausible
        )
        let entryCost = retainedUTF16Units(entry)
        guard entryCost <= maximumCommittedDeletionHistoryUTF16Units else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            return
        }
        while !committedDeletionHistory.isEmpty &&
                (committedDeletionHistory.count >= maximumCommittedDeletionHistoryEntries ||
                 committedDeletionHistory.reduce(0, { $0 + retainedUTF16Units($1) }) + entryCost >
                    maximumCommittedDeletionHistoryUTF16Units) {
            committedDeletionHistory.removeFirst()
        }
        committedDeletionHistory.append(entry)
    }

    private func retainedUTF16Units(_ entry: CommittedDeletionUndoEntry) -> Int {
        func contextUnits(_ context: Context) -> Int {
            [context.document, context.before, context.after, context.selected]
                .compactMap { $0 }
                .reduce(0) { $0 + $1.utf16.count }
        }
        return entry.text.utf16.count + contextUnits(entry.contextAfterDeletion) +
            contextUnits(entry.contextAfterUndo)
    }

    private func undoCommittedDeletion() -> Bool {
        guard !surface.hasComposition else { return false }
        guard let entry = committedDeletionHistory.last else {
            return false
        }
        let proxy = textDocumentProxy
        let current = context(for: proxy)
        let sensitive = isSensitiveInput(proxy)
        if let pending = pendingDeletionUndoContext {
            if current.matchesDeletionUndoSnapshot(pending) {
                pendingDeletionUndoContext = nil
            } else if current.hasMissingSideComparedTo(pending) {
                return false
            } else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                pendingDeletionUndoContext = nil
                return false
            }
        }
        let contextMatches = current.matchesDeletionUndoSnapshot(
            entry.contextAfterDeletion,
            allowUnavailableTrailingContext: entry.hasProvisionalDeletionContext
        )
        let entryHasDocument = entry.contextAfterDeletion.document != nil
        guard !sensitive, contextMatches, entryHasDocument else {
            committedDeletionHistory.removeAll(keepingCapacity: true)
            return false
        }
        committedDeletionHistory.removeLast()
        perform({ proxy in
            proxy.insertText(entry.text)
            if entry.cursorPlacement == .beforeDeletedText {
                proxy.adjustTextPosition(byCharacterOffset: -entry.text.utf16.count)
            }
        }, preservingDeletionHistory: true)
        let restored = context()
        let restoredMatches = restored.matchesDeletionUndoSnapshot(entry.contextAfterUndo)
        let priorEntryMatches = committedDeletionHistory.last.map {
            restored.matchesDeletionUndoSnapshot(
                $0.contextAfterDeletion,
                allowUnavailableTrailingContext: $0.hasProvisionalDeletionContext
            )
        }
        let restoredContextIsIncomplete = restored.hasMissingSideComparedTo(entry.contextAfterUndo)
        if !restoredMatches || priorEntryMatches == false {
            if restoredContextIsIncomplete,
               let previous = committedDeletionHistory.last,
               previous.contextAfterDeletion == entry.contextAfterUndo {
                // The deletion history relationship was exact before this undo.
                // Retain it only pending a fresh proxy snapshot; undo itself
                // remains disabled until that snapshot matches the saved context.
                pendingDeletionUndoContext = previous.contextAfterDeletion
            } else {
                committedDeletionHistory.removeAll(keepingCapacity: true)
                pendingDeletionUndoContext = nil
            }
        }
        return restoredMatches || priorEntryMatches == true || pendingDeletionUndoContext != nil ||
            (restoredContextIsIncomplete && committedDeletionHistory.isEmpty)
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
        traceCompositionEvent("lifecycle.will-disappear")
        surface.isUserInteractionEnabled = false
        committedDeletionHistory.removeAll(keepingCapacity: true)
        pendingDeletionUndoContext = nil
        surface.clearCompositionDeletionHistory()
        let proxy = textDocumentProxy
        let current = context(for: proxy)
        if hasReachedViewDidAppear, appearanceContextValidated, !changing,
           !session.needsCompositionRefresh, expectedContext == current,
           markedOwnership.canFinalizeMark(in: current) {
            // Android finalizes composing text at onFinishInputView while
            // retaining its characters. Finalize only before ownership is
            // suspended and only while the exact owner context is still live.
            traceCompositionEvent("lifecycle.hide.finalize-owned-mark", proxy: proxy)
            surface.finishMarkedText?()
        }
        let resolution = markedOwnership.resolveOnHide(context(for: proxy))
#if DEBUG
        if let reason = markedOwnership.debugLastDiscardReason {
            traceCompositionEvent("ownership.discard", proxy: proxy,
                                  detail: "reason=hide-\(reason.rawValue)")
        }
#endif
        hasReachedViewDidAppear = false
        appearanceContextValidated = false
        switch resolution {
        case .preserveOwnedText:
            // The proxy was unavailable or no longer exactly matched the owner,
            // so keep the fallback lease suspended without writing to a host
            // document that cannot be identified safely.
            expectedContext = context(for: proxy)
            session.needsCompositionRefresh = true
            session.needsHostMarkRestore = false
            surface.suspendCompositionDisplay()
            traceCompositionEvent("lifecycle.hide.suspended", proxy: proxy)
        case .restoreOwnedText:
            // A previous appearance may have validated a host rollback without
            // completing the corresponding host mark write. Keep that explicit
            // request for the next validated appearance.
            expectedContext = context(for: proxy)
            session.needsCompositionRefresh = true
            session.needsHostMarkRestore = true
            surface.suspendCompositionDisplay()
            traceCompositionEvent("lifecycle.hide.suspended", proxy: proxy,
                                  detail: "hostReplay=pending")
        case .waitForDocument:
            session.needsCompositionRefresh = true
            session.needsHostMarkRestore = false
            surface.suspendCompositionDisplay()
        case .none, .discardOwnership:
            session.needsCompositionRefresh = false
            session.hostFocusChangedWhileSuspended = false
            session.needsHostMarkRestore = false
#if DEBUG
            let reason = resolution == .none ? "hide-without-owned-mark" : "hide-owner-discarded"
            traceCompositionInvalidation(reason: reason, proxy: proxy)
#endif
            markedOwnerProxy = nil
            surface.invalidateComposition()
        }
        super.viewWillDisappear(animated)
        expectedContext = nil
        ProcessMemory.record("extension.hidden")
    }

#if DEBUG
    /// Temporary, privacy-safe trace for the composition ownership regression.
    /// It records only event ordering and boolean state, never text or document IDs.
    private func traceOwnershipDiscard(reason: String, proxy: UITextDocumentProxy) {
        let current = context(for: proxy)
        let comparison = markedOwnership.debugContextComparison(current)
        guard surface.hasComposition || comparison.hasPrefix("lease=present;") else { return }
        traceCompositionEvent("ownership.discard", proxy: proxy,
                              detail: "reason=\(reason);\(comparison)")
    }

    private func traceCompositionInvalidation(reason: String, proxy: UITextDocumentProxy) {
        guard surface.hasComposition else { return }
        let current = context(for: proxy)
        let comparison = markedOwnership.debugContextComparison(current)
        traceCompositionEvent("composition.invalidate.request", proxy: proxy,
                              detail: "reason=\(reason);\(comparison)")
    }

    private func traceCompositionEvent(_ event: String, proxy: UITextDocumentProxy? = nil,
                                      generation: UInt64? = nil, inputAvailable: Bool? = nil,
                                      detail: String? = nil) {
        let current = context(for: proxy ?? textDocumentProxy)
        let contextMatches = expectedContext.map { $0 == current } ?? false
        let generationMatches = generation.map { $0 == session.composition.generation } ?? true
        let inputState = inputAvailable.map { $0 ? "true" : "false" } ?? "na"
        let ownerAllowsMark = markedOwnership.canUpdateMark(in: current)
        let didAppear = hasReachedViewDidAppear
        let contextValidated = appearanceContextValidated
        let refreshPending = session.needsCompositionRefresh
        let isChanging = changing
        let hasComposition = surface.hasComposition
        let ownerCanFinalizeMark = markedOwnership.canFinalizeMark(in: current)
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        let payload = "uptime=\(uptime);event=\(event);input=\(inputState);doc=\(current.document != nil);ctx=\(contextMatches);owner=\(ownerAllowsMark);finalizable=\(ownerCanFinalizeMark);gen=\(generationMatches);appeared=\(didAppear);validated=\(contextValidated);refresh=\(refreshPending);changing=\(isChanging);composition=\(hasComposition);detail=\(detail ?? "na")"
        let record = session.recordDebugCompositionTrace(
            controller: compositionTraceControllerIdentifier,
            payload: payload
        )
        surface.setDebugCompositionTrace(record.trace)
        compositionLogger.notice("\(record.entry, privacy: .public)")
    }
#else
    private func traceCompositionEvent(_ event: String, proxy: UITextDocumentProxy? = nil,
                                      generation: UInt64? = nil, inputAvailable: Bool? = nil,
                                      detail: String? = nil) {}
#endif
}
