import AVFoundation
import UIKit
import SumireCore

/// Shared native surface used in the app's diagnostic harness and extension.
/// Reading and selection survive layout changes; conversion runs off the main thread.
final class KeyboardSurface: UIInputView, UIInputViewAudioFeedback {
    private struct SpaceConvertKanaToggleState {
        let sourceReading: String
        let sourceCursor: Int
        let displayText: String
        let displayCursorUTF16: Int
        let hasConvertedKatakana: Bool
        let generation: UInt64

        func matches(_ composition: CompositionState) -> Bool {
            generation == composition.generation && sourceCursor == composition.cursor &&
                sourceReading.utf16.elementsEqual(composition.reading.utf16)
        }
    }

    var insert: ((String) -> Void)?
    var delete: (() -> Void)?
    var deleteForward: (() -> Void)?
    var deleteUntilBoundary: (() -> Void)?
    var nextKeyboard: (() -> Void)?
    private var specialKeySettings = SumireSpecialKeySettings()
    private var katakanaCycle = SumireKatakanaCycle()
    private var spaceConvertKanaToggleState: SpaceConvertKanaToggleState?
    var moveCursorRight: (() -> Void)?
    var moveCursorLeft: (() -> Void)?
    private(set) var spaceCursorMoveModeActive = false
    private var spaceCursorMoveRemainder: CGFloat = 0
    private let spaceCursorMovePointsPerCharacter: CGFloat = 12
    var beforeInput: (() -> Void)?
    var updateMarkedText: ((String) -> Void)?
    var updateMarkedSelection: ((String, NSRange) -> Void)?
    var commitMarkedText: ((String) -> Void)?
    var commitRawTextAndSpace: ((String, String) -> Void)?
    var finishMarkedText: (() -> Void)?
    var liveConversion = false {
        didSet {
            guard oldValue != liveConversion else { return }
            spaceConvertKanaToggleState = nil
            beforeInput?()
            guard hasComposition else { return }
            if currentBunsetsuSession != nil {
                renderBunsetsuSession()
                return
            }
            if liveConversion && !englishComposition
                && physicalFunctionKeyPreviewSuppressionGeneration != composition.generation
                && composition.cursorUTF16 == composition.reading.utf16.count,
               let first = converted.first {
                selectedCandidate = 0
                updateMarkedText?(first.text)
            } else {
                selectedCandidate = nil
                markReading()
            }
        }
    }
    var omissionSearch = false {
        didSet {
            guard oldValue != omissionSearch else { return }
            beforeInput?()
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var predictionSettings = JapanesePredictionSettings() {
        didSet {
            guard oldValue != predictionSettings else { return }
            beforeInput?()
            converter.setPredictionSettings(predictionSettings)
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var kotowazaEnabled = true {
        didSet {
            guard oldValue != kotowazaEnabled else { return }
            beforeInput?()
            converter.setKotowazaEnabled(kotowazaEnabled)
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var bunsetsuSeparation = false
    var englishReadingEnabled = true {
        didSet {
            guard oldValue != englishReadingEnabled else { return }
            beforeInput?()
            converter.setEnglishReading(englishReadingEnabled)
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var categoryIDs: [String]? {
        didSet {
            guard oldValue != categoryIDs else { return }
            beforeInput?()
            converter.setCategoryIDs(categoryIDs)
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var categoryMask: UInt32 = 0 {
        didSet {
            guard oldValue != categoryMask else { return }
            beforeInput?()
            converter.setCategories(categoryMask)
            guard hasComposition else { return }
            composition.optionsChanged()
            refreshConversion()
        }
    }
    var settingsDefaults: UserDefaults = .standard
    var settingsWriteDefaults: UserDefaults?
    var onSettingsWritten: (([String]) -> Void)?
    private var writableSettings: UserDefaults { settingsWriteDefaults ?? settingsDefaults }
    var onHeightChange: ((CGFloat) -> Void)?
    private var sizeOrientation = KeyboardOrientation.portrait
    private var sizeValue = KeyboardSize.standard(.portrait)
    private var dragSize = KeyboardSize.standard(.portrait)
    private var loadedSizing = false
    private var sizedAvailableHeight: CGFloat?
    private var isAppearancePreview = false
    private var resizeOverlay: KeyboardResizeOverlay?
    private var templatePanel: KeyboardTemplatePanel?
    private var customTapController: CustomDoubleTapController?
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    var requestedHeight: CGFloat { preferredHeight.constant }
    func reloadSizing() {
        sizeValue = KeyboardSizingStore(defaults: settingsDefaults).load(sizeOrientation)
        loadedSizing = true
        applySizing()
    }
    private var availableSizingHeight: CGFloat {
        KeyboardSurfaceSizingPlan.availableHeight(
            screenHeight: window?.screen.bounds.height,
            windowHeight: window?.bounds.height)
    }
    private func applySizing() {
        guard preferredHeight != nil else { return }
        let availableHeight = availableSizingHeight
        sizedAvailableHeight = availableHeight
        // Keep the configured key-area size stable as candidate rows are added.
        // In constrained hosts, show only complete rows and let the candidate
        // strip scroll vertically to reach the remaining configured rows.
        let plan = KeyboardSurfaceSizingPlan.make(
            keyAreaHeight: sizeValue.height,
            candidateHeight: candidateBar.requestedDisplayedHeight,
            bottomInset: safeAreaInsets.bottom,
            availableHeight: availableHeight)
        candidateBar.setDisplayedHeightLimit(plan.candidateHeight)
        let height = plan.totalHeight
        if abs(preferredHeight.constant - height) > 0.5 {
            preferredHeight.constant = height
            invalidateIntrinsicContentSize()
            onHeightChange?(height)
        }
        let free = max(0, max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right) * (1 - sizeValue.width))
        stackLeading?.constant = geometry.horizontalInset + free * sizeValue.alignment
        stackTrailing?.constant = -geometry.horizontalInset - free * (1 - sizeValue.alignment)
        setNeedsLayout()
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if !isAppearancePreview { applySizing() }
    }
    override func layoutSubviews() {
        let orientation: KeyboardOrientation = window?.windowScene?.interfaceOrientation.isLandscape == true ? .landscape : .portrait
        if !isAppearancePreview && (!loadedSizing || orientation != sizeOrientation) {
            if resizeOverlay != nil { saveSize() }
            sizeOrientation = orientation
            reloadSizing()
        } else if !isAppearancePreview,
                  sizedAvailableHeight.map({ abs($0 - availableSizingHeight) > 0.5 }) ?? true {
            applySizing()
        }
        let free = max(0, max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right) * (1 - sizeValue.width))
        stackLeading.constant = geometry.horizontalInset + free * sizeValue.alignment
        stackTrailing.constant = -geometry.horizontalInset - free * (1 - sizeValue.alignment)
        super.layoutSubviews()
        if let overlay = resizeOverlay {
            let top = candidateBar.convert(candidateBar.bounds, to: self).maxY + geometry.rowSpacing
            overlay.frame = CGRect(x: stack.frame.minX, y: top, width: stack.frame.width,
                                   height: max(100, stack.frame.maxY - top))
        }
    }
    private func saveSize() {
        do {
            try KeyboardSizingStore(defaults: writableSettings).save(sizeValue, for: sizeOrientation)
            onSettingsWritten?([KeyboardSizingStore.key(sizeOrientation)])
        }
        catch { status.text = "サイズを保存できませんでした" }
    }
    private func beginResize() {
        guard !hasComposition, resizeOverlay == nil else { return }
        let overlay = KeyboardResizeOverlay()
        overlay.onBegin = { [weak self] in guard let self else { return }; self.dragSize = self.sizeValue }
        overlay.onDrag = { [weak self] handle, delta in
            guard let self else { return }
            var value = self.dragSize
            switch handle {
            case .top: value.height -= delta.y
            case .left:
                let fixedRight = (1 - value.width) * value.alignment + value.width
                value.width = min(1, max(0.5, value.width - delta.x / max(1, self.bounds.width)))
                value.alignment = value.width < 1 ? (fixedRight - value.width) / (1 - value.width) : 0.5
            case .right:
                let fixedLeft = (1 - value.width) * value.alignment
                value.width = min(1, max(0.5, value.width + delta.x / max(1, self.bounds.width)))
                value.alignment = value.width < 1 ? fixedLeft / (1 - value.width) : 0.5
            }
            self.sizeValue = value.normalized
            self.applySizing()
        }
        overlay.onEnd = { [weak self] in self?.saveSize() }
        overlay.onDone = { [weak self] in
            self?.saveSize(); self?.resizeOverlay?.removeFromSuperview(); self?.resizeOverlay = nil
        }
        overlay.onReset = { [weak self] in
            guard let self else { return }
            self.sizeValue = .standard(self.sizeOrientation); self.saveSize(); self.applySizing()
        }
        resizeOverlay = overlay
        addSubview(overlay)
        setNeedsLayout()
    }
    private var appearance = KeyboardAppearance.load(.gojuon, defaults: .standard)
    private func keyAppearance(special: Bool = false) -> KeyboardAppearance {
        .load(keyboardKind, group: special ? .special : .normal, defaults: settingsDefaults)
    }
    private var keyboardKind: KeyboardKind {
        switch displayedInputMode {
        case .kana: return .gojuon
        case .tenKey: return .tenKey
        case .sumire: return .sumire
        case .romaji: return .romaji
        case .english: return .english
        case .custom: return .custom
        }
    }
    func configureAppearancePreview(_ kind: KeyboardKind, defaults: UserDefaults) {
        settingsDefaults = defaults
        customPresentationOwner = nil
        if !isAppearancePreview {
            stackLeading.isActive = false; stackTrailing.isActive = false
            stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: geometry.horizontalInset)
            stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -geometry.horizontalInset)
            NSLayoutConstraint.activate([stackLeading, stackTrailing])
        }
        isAppearancePreview = true
        isUserInteractionEnabled = false
        candidateBar.clipboardAccessAllowed = false
        inputMode = [.tenKey: .tenKey, .romaji: .romaji, .english: .english,
                     .sumire: .sumire, .custom: .custom, .gojuon: .kana][kind]!
        reloadCustomLayouts()
        reloadTheme()
        rebuild()
        status.text = "プレビュー"
        preferredHeight.constant = 300
    }
    func reloadAppearance() {
        // Preserve composition while a removed layout is replaced by the first enabled one.
        let choices = keyboardChoices
        if !isAppearancePreview, let saved = settingsDefaults.string(forKey: "keyboard.lastUsed"),
           let choice = choices.first(where: { selectionID(mode: $0.mode, customID: $0.customID) == saved }) {
            inputMode = choice.mode
            if let id = choice.customID { activeCustomID = id }
        }
        if !isAppearancePreview && !choices.contains(where: {
            $0.mode == inputMode && ($0.mode != .custom || $0.customID == activeCustomID)
        }), let first = choices.first {
            inputMode = first.mode
            if let id = first.customID { activeCustomID = id }
        }
        if customPresentationOwner != nil && !customProxyVisible {
            customPresentationOwner = nil
            refreshCustomPresentationLanguage()
        }
        if !isAppearancePreview,
           let saved = settingsDefaults.string(forKey: "keyboard.lastUsed"),
           !choices.contains(where: { selectionID(mode: $0.mode, customID: $0.customID) == saved }) {
            // Persist the replacement so re-enabling a removed layout cannot restore a stale selection.
            rememberKeyboard()
        }
        if sumireEnglishQWERTYVisible { resetEnglishQWERTYState() }
        rebuild()
    }
    var personalLexicon = PersonalLexicon() {
        didSet {
            guard personalLexicon != oldValue else { return }
            converter.setPersonal(personalLexicon)
            if hasComposition { composition.optionsChanged(); refreshConversion() }
        }
    }
    func showDataNotice(_ text: String) { status.text = text }
    private let converter = ConversionService()
    private var symbolPanel: SymbolKeyboardView?
    private let clipboardHistory = ClipboardHistoryController()
    func configureClipboard(accessAllowed: Bool, allowShared: Bool, localReset: LocalDataReset? = nil) {
        candidateBar.clipboardAccessAllowed = accessAllowed
        candidateBar.captureClipboardHistory = ClipboardHistorySettings.isEnabled(defaults: settingsDefaults)
        clipboardHistory.onSettingsWritten = { [weak self] keys in self?.onSettingsWritten?(keys) }
        clipboardHistory.configure(defaults: settingsDefaults, writableDefaults: writableSettings,
                                   url: PersonalDataLocation.clipboardURL(allowShared: allowShared), allowed: accessAllowed, localReset: localReset)
    }
    private func closeSymbolKeyboard() {
        symbolPanel?.removeFromSuperview(); symbolPanel = nil
        clipboardHistory.detach(); stack.accessibilityElementsHidden = false
    }
    private func showSymbolKeyboard(initialMode: SymbolKeyboardMode? = nil) {
        guard symbolPanel == nil, templatePanel == nil else { return }
        do {
            let panel = SymbolKeyboardView(defaults: settingsDefaults, writableDefaults: writableSettings,
                                           catalog: try SymbolKeyboardCatalog.load(), initialMode: initialMode)
            panel.onSettingsWritten = { [weak self] keys in self?.onSettingsWritten?(keys) }
            panel.applyPalette(KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness))
            panel.onClose = { [weak self] in self?.closeSymbolKeyboard() }
            panel.onInsert = { [weak self] value in
                guard let self else { return }
                self.beforeInput?(); self.commitComposition(); self.insert?(value)
            }
            panel.onDelete = { [weak self] in self?.pressed("⌫") }
            clipboardHistory.attach(panel)
            panel.translatesAutoresizingMaskIntoConstraints = false
            closeExpandedCandidates(); addSubview(panel)
            NSLayoutConstraint.activate([panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor), panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor)])
            panel.accessibilityViewIsModal = true; stack.accessibilityElementsHidden = true
            symbolPanel = panel
        } catch { showDataNotice("記号パネル: " + error.localizedDescription) }
    }
    private func showTemplatePanel() {
        guard !hasComposition, symbolPanel == nil, templatePanel == nil else { return }
        let templates = KeyboardTemplatePanel.ordered(personalLexicon.templates)
        guard !templates.isEmpty else {
            showDataNotice("定型文は登録されていません")
            return
        }
        let panel = KeyboardTemplatePanel(templates: templates)
        panel.onClose = { [weak self] in self?.closeTemplatePanel() }
        panel.onInsert = { [weak self] text in
            guard let self else { return }
            self.candidateBar.onInsertShortcutText?(text)
            self.closeTemplatePanel()
        }
        panel.applyPalette(KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark,
                                          saturation: saturation, brightness: brightness))
        panel.translatesAutoresizingMaskIntoConstraints = false
        closeExpandedCandidates()
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        panel.accessibilityViewIsModal = true
        stack.accessibilityElementsHidden = true
        templatePanel = panel
        UIAccessibility.post(notification: .layoutChanged, argument: panel)
    }
    private func closeTemplatePanel() {
        templatePanel?.removeFromSuperview()
        templatePanel = nil
        stack.accessibilityElementsHidden = false
    }
    private var learningURL: URL?
    private var learningRemainder: String?
    private(set) var learningPausedForSession = false
    var learnFirstCandidate = false
    var learnMixedSymbolsAndNumbers = true {
        didSet {
            guard oldValue != learnMixedSymbolsAndNumbers else { return }
            cancelLearning()
            converter.setLearnMixedSymbolsAndNumbers(learnMixedSymbolsAndNumbers)
            if hasComposition { composition.optionsChanged(); refreshConversion() }
        }
    }
    func reloadLearningResults() {
        if hasComposition { composition.optionsChanged(); refreshConversion() }
    }
    func configureLearning(url: URL?, localReset: LocalDataReset? = nil) {
        guard learningURL != url || localReset != nil else { return }
        cancelLearning()
        learningURL = url
        converter.setLearning(url: url, localReset: localReset)
        if hasComposition { composition.optionsChanged(); refreshConversion() }
    }
    func toggleLearningPauseForSession() -> Bool {
        cancelLearning()
        learningPausedForSession.toggle()
        converter.setLearningPaused(learningPausedForSession)
        return learningPausedForSession
    }
    private func cancelLearning() {
        learningRemainder = nil
        converter.cancelLearning()
    }
    func synchronizeLearning(_ completion: @escaping () -> Void) {
        converter.synchronizeLearning(completion)
    }
    /// Only synchronous input mutations at the old composing end may extend
    /// a partially committed session. Conversion callbacks never call this.
    private func mutateLearningInput(_ mutation: () -> Void) {
        let previous = composition.reading, cursor = composition.cursorUTF16
        mutation()
        guard let remainder = learningRemainder else { return }
        guard cursor == previous.utf16.count,
              remainder.utf16.elementsEqual(previous.utf16), !composition.reading.isEmpty else {
            cancelLearning(); return
        }
        converter.appendLearningInput(from: previous, to: composition.reading)
        learningRemainder = composition.reading
    }
    private func appendLearningInput(_ text: String) {
        mutateLearningInput { composition.append(text) }
    }
    private func appendLearningRomaji(_ text: String, using processor: RomajiConverter) {
        mutateLearningInput { composition.appendRomaji(text, using: processor) }
    }
    private var composition = CompositionState()
    private var converted: [ConversionCandidate] = []
    private var presentedCandidates: [ConversionCandidate] = []
    private var bunsetsuActionHandled = false
    private var bunsetsuSession: BunsetsuConversionSession?
    private var bunsetsuOwnerGeneration: UInt64?
    private var bunsetsuCandidateItems: [BunsetsuCandidateBarItem] = []
    private var bunsetsuRequestGeneration: UInt64 = 0
    private var resultGeneration: UInt64?
    private var selectedCandidate: Int? { didSet { candidateBar.selectedIndex = selectedCandidate } }
    var hasComposition: Bool { !composition.reading.isEmpty }

    var hue: CGFloat = 0.73 { didSet { if hue != oldValue { rebuild() } } }
    var saturation: CGFloat = 0.5 { didSet { if saturation != oldValue { rebuild() } } }
    var brightness: CGFloat = 0.7 { didSet { if brightness != oldValue { rebuild() } } }
    var colorMode: KeyboardColorMode = .system {
        didSet {
            guard colorMode != oldValue else { return }
            overrideUserInterfaceStyle = colorMode == .system ? .unspecified : (colorMode == .dark ? .dark : .light)
            rebuild()
        }
    }
    func reloadTheme() {
        let theme = KeyboardTheme.load(defaults: settingsDefaults)
        hue = CGFloat(theme.hue)
        saturation = CGFloat(theme.saturation)
        brightness = CGFloat(theme.brightness)
        colorMode = theme.mode
    }
    let candidateBar = CandidateBar()
    var candidateRowCount = 1 {
        didSet {
            candidateBar.rowCount = candidateRowCount
            applySizing()
        }
    }
    private var preferredHeight: NSLayoutConstraint!
    private var romajiPage = 0
    private var romajiLatin = false
    private var sumireMode = TenKeyMode.japanese
    private var sumireFlickProfile: ReferenceFlickMaps?
    private var gojuonMode = TenKeyMode.japanese
    private var gojuonShift = false
    private var gojuonCapsLock = false
    private var gojuonFullWidth = false
    private var gojuonLastShiftTap: TimeInterval = 0
    private var tenKeyMode = TenKeyMode.japanese
    private var englishComposition = false
    private var englishPage = 0 // letters, numbers, symbols
    private enum InputMode { case kana, tenKey, sumire, romaji, english, custom }
    private var inputMode: InputMode = .kana
    // A temporary English surface belongs to the selected custom layout. It is
    // independent of the user's enabled keyboard list and last-used layout.
    private var customPresentationOwner: String?
    private enum CustomPresentation { case english, number }
    private var customPresentation = CustomPresentation.english
    private var customProxyVisible: Bool {
        inputMode == .custom && customPresentationOwner == activeCustomID && customPresentationOwner != nil
            && customLayouts.contains { $0.id == customPresentationOwner }
    }
    private var customEnglishVisible: Bool { customProxyVisible && customPresentation == .english }
    private var customNumberVisible: Bool { customProxyVisible && customPresentation == .number }
    private var sumireEnglishQWERTYVisible: Bool {
        inputMode == .sumire && sumireMode == .english && settingsDefaults.bool(forKey: SumireModePreferences.englishQWERTYKey)
    }
    private var displayedInputMode: InputMode { customEnglishVisible || sumireEnglishQWERTYVisible ? .english : inputMode }
    private func setCustomEnglishPresentation(_ visible: Bool) {
        beforeInput?(); tapCycle.reset()
        if !visible { customShift = .off }
        customPresentationOwner = visible ? activeCustomID : nil
        if visible { customPresentation = .english }
        refreshCustomPresentationLanguage()
        rebuild()
    }
    private func showCustomNumberPresentation() {
        beforeInput?(); tapCycle.reset()
        customPresentationOwner = activeCustomID
        customPresentation = .number
        refreshCustomPresentationLanguage()
        rebuild()
    }
    private func refreshCustomPresentationLanguage() {
        let wasEnglish = englishComposition
        updateModeConversionLanguage()
        if hasComposition && wasEnglish != englishComposition {
            composition.optionsChanged(); refreshConversion()
        }
    }
    private var customInputModeStore = CustomInputModeStore()
    private var customModeOverrides: [String: CustomInputMode] = [:]
    private func customInputMode(for layout: ImportedCustomLayout) -> CustomInputMode {
        customModeOverrides[layout.id] ?? customInputModeStore.state(for: layout,
            remember: settingsDefaults.bool(forKey: CustomInputModeStore.rememberKey))
    }
    private func toggleCustomInputMode(layout: ImportedCustomLayout, direct: Bool) {
        var mode = customInputMode(for: layout)
        if direct {
            if !mode.direct && !finishCustomCompositionForDirectInput() { return }
            mode.direct.toggle()
        } else {
            mode.romaji.toggle()
            if !mode.romaji { containsRomaji = false }
        }
        customModeOverrides[layout.id] = mode
        var notice: String?
        if settingsDefaults.bool(forKey: CustomInputModeStore.rememberKey) {
            do {
                customInputModeStore.retain(layoutIDs: Set(customLayouts.map(\.id)))
                try customInputModeStore.set(state: mode, for: layout.id)
                try customInputModeStore.save(defaults: writableSettings)
                onSettingsWritten?([CustomInputModeStore.storageKey])
            } catch { notice = error.localizedDescription }
        }
        rebuild()
        if let notice { showDataNotice(notice) }
    }
    private func finishCustomCompositionForDirectInput() -> Bool {
        guard hasComposition, !settingsDefaults.bool(forKey: CustomInputModeStore.replaceKey) else { return true }
        guard let finishMarkedText else {
            showDataNotice("この入力先では未確定表示を確定できません")
            return false
        }
        // Finish the displayed preview without rewriting it, flushing pending
        // romaji or recording a candidate selection in learning.
        invalidateComposition()
        finishMarkedText()
        return true
    }
    private func insertCustomDirect(_ text: String) {
        guard finishCustomCompositionForDirectInput() else { return }
        if hasComposition {
            guard let commitMarkedText else {
                showDataNotice("この入力先では未確定文字を置換できません")
                return
            }
            invalidateComposition()
            commitMarkedText(text)
        } else { insert?(text) }
    }
    private var customLayouts: [ImportedCustomLayout] = []
    private var activeCustomID: String? {
        didSet { if activeCustomID != oldValue { customShift = .off } }
    }
    private var storedCustomID: String?
    func reloadCustomLayouts() {
        do {
            let restoredModeStore = try CustomInputModeStore.load(defaults: settingsDefaults)
            let memoryChanged = restoredModeStore != customInputModeStore
            customInputModeStore = restoredModeStore
            if memoryChanged { customModeOverrides.removeAll() }
            let library = try CustomKeyboardLibrary.load(defaults: settingsDefaults)
            let layouts = try library.layouts()
            guard layouts != customLayouts || library.activeID != storedCustomID else {
                if memoryChanged { rebuild() }
                return
            }
            customModeOverrides = customModeOverrides.filter { id, _ in
                layouts.first(where: { $0.id == id }) == customLayouts.first(where: { $0.id == id })
            }
            customShift = .off
            customLayouts = layouts
            storedCustomID = library.activeID
            activeCustomID = library.activeID ?? layouts.first?.id
            if customPresentationOwner != nil && !customProxyVisible {
                customPresentationOwner = nil
                refreshCustomPresentationLanguage()
            }
            rebuild()
        } catch { showDataNotice(error.localizedDescription) }
    }
    private var customShift = CustomKeyboardShiftState.off
    private var customDisplayRefreshes: [() -> Void] = []
    private var isDefaultCustomRomaji = true
    private var romaji = try? RomajiConverter.standard()
    func reloadRomaji() {
        do {
            let library = try RomajiLibrary.load(defaults: settingsDefaults)
            romaji = try library.converter()
            isDefaultCustomRomaji = library.activeID == nil
        }
        catch { showDataNotice("ローマ字設定: " + error.localizedDescription) }
    }
    private var containsRomaji = false
    private var physicalFunctionKeyConversionSource = PhysicalKeyboardFunctionKeyConversionSource()
    /// A function-key result stays visible for its composition generation even
    /// when live conversion returns candidates. Candidate selection remains an
    /// explicit user action and may still replace it.
    private var physicalFunctionKeyPreviewSuppressionGeneration: UInt64?
    private var shifted = false
    private var qwertyCapsLock = false
    private var qwertyLastShiftTap: TimeInterval = 0
    private var tapCycle = KanaTapCycle()
    var tenKeyToggle = true
    private let geometry = KeyboardGeometry()
    private var keyRows: [UIStackView] = []
    private let touchRouter = KeyTouchRouter()
    private var touchFeedback = TouchFeedbackSettings()
    private var keyFeedbackSettings = KeyFeedbackSettings()
    private var customKeyFeedbackActions: [ObjectIdentifier: CustomKeyAction] = [:]
    private lazy var keyFeedbackRuntime = KeyboardKeyFeedbackRuntime()
    var enableInputClicksWhenVisible: Bool {
        keyFeedbackSettings.isKeySoundEnabled &&
            keyFeedbackSettings.soundVolumeMultiplier == nil &&
            !isAppearancePreview && resizeOverlay == nil
    }
    private let stack = UIStackView()
    private let status = UILabel()
    private var expandedCandidates: UIView?
    var textMacroContextAllowed = false
    var textMacroSelectionAvailable = false
    var executeTextMacro: ((String, String?) -> Void)?


    init(frame: CGRect = .zero) {
        super.init(frame: frame, inputViewStyle: .keyboard)
        touchRouter.onBegin = { [weak self] participant in self?.emitKeyFeedback(.press, for: participant) }
        touchRouter.onEnd = { [weak self] participant in self?.emitKeyFeedback(.release, for: participant) }
        NotificationCenter.default.addObserver(self, selector: #selector(purgeConversionCache),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        translatesAutoresizingMaskIntoConstraints = false
        allowsSelfSizing = true
        preferredHeight = heightAnchor.constraint(equalToConstant: 464)
        preferredHeight.isActive = true
        stack.axis = .vertical
        stack.spacing = geometry.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackLeading = stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: geometry.horizontalInset)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -geometry.horizontalInset)
        NSLayoutConstraint.activate([
            stackLeading, stackTrailing,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (surface: KeyboardSurface, _: UITraitCollection) in
            surface.rebuild()
        }
        status.heightAnchor.constraint(equalToConstant: 27).isActive = true
        candidateBar.onPasteText = { [weak self] text in
            guard let self else { return }
            self.beforeInput?()
            self.commitComposition()
            self.insert?(text)
        }
        clipboardHistory.onInsertText = { [weak self] text in
            guard let self else { return }; self.beforeInput?(); self.commitComposition(); self.insert?(text)
        }
        clipboardHistory.onNotice = { [weak self] text in self?.symbolPanel?.showNotice(text); self?.showDataNotice(text) }
        clipboardHistory.onHistoryEnabledChanged = { [weak self] enabled in self?.candidateBar.captureClipboardHistory = enabled }
        candidateBar.onClipboardCaptured = { [weak self] text, image in self?.clipboardHistory.capture(text: text, image: image) }
        candidateBar.onSizingChange = { [weak self] in self?.applySizing() }
        candidateBar.onSymbols = { [weak self] in self?.showSymbolKeyboard(initialMode: .emoji) }
        candidateBar.onTextMacros = { [weak self] in self?.showTextMacroList() }
        candidateBar.onClipboard = { [weak self] in self?.showSymbolKeyboard(initialMode: .clipboard) }
        candidateBar.onTemplates = { [weak self] in self?.showTemplatePanel() }
        candidateBar.onClipboardNotice = { [weak self] in self?.showDataNotice($0) }
        candidateBar.onResize = { [weak self] in self?.beginResize() }
        candidateBar.onExpand = { [weak self] in self?.showExpandedCandidates() }
        candidateBar.onSelect = { [weak self] index in self?.chooseCandidate(index) }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func purgeConversionCache() { converter.purgeCache(); clipboardHistory.purgeThumbnails() }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight.constant)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: preferredHeight.constant)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { touchRouter.cancelAll(); customTapController?.cancel() }
    }
    private func touchPolicy(for key: UIButton) -> (exclusive: Bool, blocksFollowing: Bool) {
        let id = key.accessibilityIdentifier ?? ""
        if id == "keyboard-switch" || ["tenkey-symbols", "gojuon-symbols"].contains(id) {
            return (true, true)
        }
        if inputMode == .sumire, id.hasPrefix("sumire-") {
            let arrangement = SumireKeyArrangement(rawValue: settingsDefaults.string(forKey: "sumire.keyArrangement") ?? "") ?? .toggle
            if let special = SumireSpecialKeyID.resolve(String(id.dropFirst(7)), arrangement: arrangement, mode: sumireMode) {
                switch specialKeySettings.action(for: special, gesture: .tap, arrangement: arrangement,
                                                  mode: sumireMode, hasComposition: hasComposition) {
                case .nextKeyboard, .openSymbols: return (true, true)
                case .changeInputMode, .switchKana, .switchEnglish, .switchNumber: return (true, false)
                default: break
                }
            }
        }
        if let key = key as? FlickKey { return (key.exclusiveTouchAction, key.blocksSequentialTouches) }
        if let key = key as? MultiStageFlickKey { return (key.exclusiveTouchAction, key.blocksSequentialTouches) }
        if let key = key as? RepeatingKey { return (key.exclusiveTouchAction, key.blocksSequentialTouches) }
        if let key = key as? DirectionalActionKey { return (key.exclusiveTouchAction, key.blocksSequentialTouches) }
        return (false, false)
    }
    private func configureTouchInput(in view: UIView) {
        if let key = view as? UIButton {
            // Resolve dynamic modifier/symbol actions at DOWN, not at layout time.
            let policy = { [weak self, weak key] in
                guard let self, let key else { return (exclusive: false, blocksFollowing: false) }
                return self.touchPolicy(for: key)
            }
            if let flick = key as? FlickKey {
                flick.touchRouter = touchRouter
                flick.feedbackSettings = touchFeedback
                flick.popupPalette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness)
                flick.popupHost = self
                flick.touchPolicy = policy
            } else if let multi = key as? MultiStageFlickKey {
                multi.touchRouter = touchRouter
                multi.feedbackSettings = touchFeedback
                multi.popupPalette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness)
                multi.popupHost = self
                multi.touchPolicy = policy
            } else if let repeating = key as? RepeatingKey {
                repeating.touchRouter = touchRouter
                repeating.longPressMilliseconds = touchFeedback.longPressMilliseconds
                repeating.touchPolicy = policy
            } else if let directional = key as? DirectionalActionKey {
                directional.touchRouter = touchRouter
                directional.longPressMilliseconds = touchFeedback.longPressMilliseconds
                directional.touchPolicy = policy
            }
        }
        view.subviews.forEach { configureTouchInput(in: $0) }
    }
    private func emitKeyFeedback(_ moment: KeyFeedbackMoment, for participant: any KeyTouchParticipant) {
        let button = participant as? UIButton
        let kind: KeyFeedbackKeyKind
        if let button, let action = customKeyFeedbackActions[ObjectIdentifier(button)] {
            // Android's explicit no-op key suppresses both DOWN and release feedback.
            guard let resolved = KeyFeedbackKeyKind.resolve(action: action) else { return }
            kind = resolved
        } else {
            kind = KeyFeedbackKeyKind.resolve(
                identifier: button?.accessibilityIdentifier,
                label: button?.accessibilityLabel,
                title: button?.currentTitle
            )
        }
        keyFeedbackRuntime.dispatch(
            moment,
            kind: kind,
            settings: keyFeedbackSettings,
            isKeyboardLayoutEditing: isAppearancePreview || resizeOverlay != nil
        )
    }
    private func rebuild() {
        var customNotice: String?
        if inputMode == .custom, !customEnglishVisible,
           let layout = customLayouts.first(where: { $0.id == activeCustomID }) {
            let mode = customInputMode(for: layout)
            if !mode.romaji { containsRomaji = false }
            if mode.direct && !finishCustomCompositionForDirectInput() {
                customNotice = "この入力先では未確定表示を確定できません"
            }
        }
        defer { if let customNotice { showDataNotice(customNotice) } }
        touchRouter.cancelAll()
        customTapController?.deactivate(); customTapController = nil
        customKeyFeedbackActions.removeAll()
        touchFeedback = TouchFeedbackSettings.load(defaults: settingsDefaults)
        keyFeedbackSettings = KeyFeedbackSettings.load(defaults: settingsDefaults)
        touchRouter.independentMultiTouch = touchFeedback.independentMultiTouch
        // All arrangements, including early-return grids, share the same router.
        defer { configureTouchInput(in: stack) }
        var specialKeyNotice: String?
        do { specialKeySettings = try SumireSpecialKeySettings.load(defaults: settingsDefaults) }
        catch { specialKeySettings = SumireSpecialKeySettings(); specialKeyNotice = error.localizedDescription }
        defer { if let specialKeyNotice { showDataNotice(specialKeyNotice) } }
        closeExpandedCandidates()
        symbolPanel?.applyPalette(KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness))
        appearance = .load(keyboardKind, defaults: settingsDefaults)
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        keyRows = []
        sumireFlickProfile = nil
        let palette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness)
        backgroundColor = palette.background
        candidateBar.applyPalette(palette)
        layer.cornerRadius = geometry.surfaceCornerRadius
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        status.text = composition.reading.isEmpty ? "Sumire · C++変換" : composition.reading
        status.accessibilityIdentifier = "compositionReading"
        status.font = .systemFont(ofSize: 11)
        status.textColor = palette.foreground
        status.adjustsFontSizeToFitWidth = true
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(candidateBar)
        if customEnglishVisible { addQwertyGrid(palette: palette); return }
        if sumireEnglishQWERTYVisible { addQwertyGrid(palette: palette); return }
        if customNumberVisible {
            do { addCustomGrid(palette: palette, presentation: try CustomNumberLayout.layout()) }
            catch { showDataNotice(error.localizedDescription) }
            return
        }
        if inputMode == .custom {
            addCustomGrid(palette: palette)
            return
        }
        if inputMode == .sumire {
            addSumireGrid(palette: palette)
            return
        }
        if inputMode == .english || inputMode == .romaji {
            addQwertyGrid(palette: palette)
            return
        }
        if inputMode == .kana { addGojuonGrid(palette: palette); return }
        if inputMode == .tenKey { addTenKeyGrid(palette: palette) }
    }
    private func addTenKeyGrid(palette: KeyboardPalette) {
        // df1f383 tenkey/res/layout/keyboard_layout.xml: four rows, three
        // character columns between two side columns. No extra bottom row.
        var keys = [KeyboardLayout.Key]()
        for row in 0..<4 {
            for column in 0..<3 {
                let text = tenKeyMode.keys[row * 3 + column].joined()
                keys.append(.init(id: "tenkey-\(row)-\(column)", label: text, row: row, column: column + 1,
                                  action: text == "゛" ? .modifier : .text))
            }
        }
        let sides: [(String, String, KeyboardLayout.Action)] = [
            ("previous", "戻す", .changeMode), ("left", "←", .cursorLeft),
            ("symbols", "§", .changeMode), ("mode", "あa1", .changeMode),
            ("delete", "削除", .delete), ("right", "→", .changeMode),
            ("space", "空白", .space), ("enter", "改行", .enter)]
        for (index, item) in sides.enumerated() {
            keys.append(.init(id: "tenkey-" + item.0, label: item.1, row: index % 4,
                              column: index < 4 ? 0 : 4, action: item.2))
        }
        guard let grid = try? KeyboardGrid(layout: .init(rows: 4, columns: 5, keys: keys),
                                          horizontalGap: geometry.keySpacing, verticalGap: geometry.rowSpacing,
                                          makeKey: { [weak self] definition in
            guard let self else { return UIView() }
            let appearance = self.keyAppearance(special: definition.action != .text && definition.action != .modifier)
            let key: UIButton
            if definition.action == .text {
                let flickKey = FlickKey(type: .custom)
                let index = definition.row * 3 + definition.column - 1
                flickKey.directionalValues = self.tenKeyMode.keys[index]
                flickKey.values = definition.label
                flickKey.restingTitle = appearance.guidesVisible ? self.tenKeyMode.keys[index].first : self.tenKeyMode.restingLabel(at: index)
                flickKey.setTitle(flickKey.restingTitle, for: .normal)
                flickKey.titleLabel?.numberOfLines = self.tenKeyMode == .number && !appearance.guidesVisible ? 2 : 1
                flickKey.titleLabel?.textAlignment = .center
                flickKey.titleLabel?.adjustsFontSizeToFitWidth = true
                flickKey.titleLabel?.minimumScaleFactor = 0.5
                if self.tenKeyMode == .number, !appearance.guidesVisible, let label = flickKey.restingTitle,
                   label.contains("\n") {
                    let newline = (label as NSString).range(of: "\n").location
                    let text = NSMutableAttributedString(string: label, attributes: [.font: UIFont.systemFont(ofSize: appearance.keyFontSize), .foregroundColor: palette.foreground])
                    text.addAttribute(.font, value: UIFont.systemFont(ofSize: appearance.guideFontSize),
                                      range: NSRange(location: newline + 1, length: (label as NSString).length - newline - 1))
                    flickKey.restingAttributedTitle = text; flickKey.setAttributedTitle(text, for: .normal)
                }
                flickKey.onFlick = { [weak self] direction in self?.tenKeyFlick(index, direction: direction) }
                flickKey.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
                flickKey.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
                key = flickKey
            } else {
                key = RepeatingKey(type: .system)
                key.setTitle(definition.label, for: .normal)
                let icon: KeyboardIcon? = ["tenkey-previous": .undo, "tenkey-left": .left,
                    "tenkey-right": .right, "tenkey-delete": .delete, "tenkey-space": .space,
                    "tenkey-enter": .enter][definition.id]
                if let icon { key.setTitle(nil, for: .normal); key.setImage(icon.image, for: .normal) }
                if definition.action == .modifier { self.configureKeyboardSwitch(key, cycleOnTap: false) }
                key.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if definition.action == .modifier && !self.hasComposition { self.pressed("🌐") }
                    else if definition.action == .modifier && self.tenKeyMode == .english {
                        self.beforeInput?(); self.tapCycle.reset()
                        if let last = self.composition.characterBeforeCursor, last.isASCII, last.isLetter {
                            let text = String(last)
                            _ = self.composition.replaceLast(last.isUppercase ? text.lowercased() : text.uppercased())
                            self.refreshConversion()
                        }
                    }
                    else if definition.id == "tenkey-mode" {
                        self.beforeInput?(); self.tapCycle.reset()
                        self.tenKeyMode = self.tenKeyMode.next; self.rebuild()
                    }
                    else if definition.id == "tenkey-previous" {
                        self.beforeInput?(); self.tapCycle.reset()
                        if let last = self.composition.characterBeforeCursor, let previous = self.tenKeyMode.previous(last) {
                            _ = self.composition.replaceLast(String(previous)); self.refreshConversion()
                        }
                    } else if definition.id == "tenkey-right" {
                        self.beforeInput?(); self.moveCompositionCursor(by: 1)
                    } else if definition.id == "tenkey-symbols" { self.showSymbolKeyboard() }
                    else if definition.action == .changeMode { self.showDataNotice("この操作は移植中です") }
                    else { self.sumireAction(definition.action) }
                }, for: .touchUpInside)
            }
            key.accessibilityIdentifier = definition.action == .modifier ? "keyboard-switch" : definition.id
            key.accessibilityLabel = definition.action == .text ? String(definition.label.prefix(1)) : definition.label
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.setTitleColor(palette.foreground, for: .normal); key.tintColor = palette.foreground
            if definition.id == "tenkey-mode" {
                let title = NSMutableAttributedString(string: "あa1", attributes: [
                    .font: UIFont.systemFont(ofSize: appearance.keyFontSize),
                    .foregroundColor: palette.foreground.withAlphaComponent(0.4)])
                title.addAttribute(.foregroundColor, value: palette.foreground,
                                   range: NSRange(location: self.tenKeyMode.rawValue, length: 1))
                key.setAttributedTitle(title, for: .normal)
                key.accessibilityLabel = "入力モード：" + self.tenKeyMode.title
            }
            key.backgroundColor = definition.action == .text || definition.action == .modifier ? palette.key : palette.function
            key.layer.cornerRadius = geometry.keyCornerRadius
            return SizedKey(key, scale: appearance.keyScale)
        }) else { return }
        stack.addArrangedSubview(grid)
        updateSumireKeys()
    }
    private func tenKeyFlick(_ index: Int, direction: FlickDirection) {
        beforeInput?()
        let outputs = tenKeyMode.keys[index]
        guard outputs.indices.contains(direction.rawValue), !outputs[direction.rawValue].isEmpty else {
            tapCycle.reset(); return
        }
        if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
        containsRomaji = false
        if direction == .tap {
            let choice = tapCycle.choose(tenKeyMode.tapCycle(at: index), direction: .tap,
                generation: composition.generation, time: ProcessInfo.processInfo.systemUptime,
                enabled: tenKeyToggle && tenKeyMode != .number)
            if choice.replacing { _ = composition.replaceLast(choice.text) }
            else { appendLearningInput(choice.text) }
        } else { tapCycle.reset(); appendLearningInput(outputs[direction.rawValue]) }
        refreshConversion()
    }
    private func addGojuonGrid(palette: KeyboardPalette) {
        var keys = [KeyboardLayout.Key]()
        let centralColumns = GojuonInput.columns(mode: gojuonMode)
        for cell in GojuonInput.cells(mode: gojuonMode) {
            var text = GojuonInput.label(row: cell.row, column: cell.sourceColumn, mode: gojuonMode)
            let control = gojuonMode != .japanese && cell.row == 4 && [0, 3, 10].contains(cell.sourceColumn)
            if gojuonMode == .english && !control && (gojuonShift || gojuonCapsLock) { text = text.uppercased() }
            if gojuonMode == .english && cell.row == 4 && cell.sourceColumn == 0 && gojuonCapsLock { text = "⇪" }
            keys.append(.init(id: "gojuon-\(cell.row)-\(cell.sourceColumn)", label: text,
                              row: cell.row, column: cell.column + 2, columnSpan: cell.columnSpan,
                              action: text == "゛小" ? .modifier : control ? .changeMode : .text))
        }
        // JapaneseKeyboard dev 9506a0b: cursors share the second function row;
        // mode and keyboard switching occupy separate rows in all orientations.
        let left: [(String, String, Int, Int, Int, KeyboardLayout.Action)] = [
            ("previous", "戻す", 0, 0, 2, .changeMode),
            ("left", "←", 1, 0, 1, .cursorLeft),
            ("right", "→", 1, 1, 1, .changeMode),
            ("symbols", "§", 2, 0, 2, .changeMode),
            ("mode", gojuonMode == .japanese ? "あいう" : gojuonMode == .english ? "ABC" : "123", 3, 0, 2, .changeMode),
            ("switch", "キーボード切替", 4, 0, 2, .nextKeyboard)]
        for item in left {
            keys.append(.init(id: "gojuon-" + item.0, label: item.1, row: item.2, column: item.3, columnSpan: item.4, action: item.5))
        }
        keys += [.init(id: "gojuon-delete", label: "削除", row: 0, column: centralColumns + 2, columnSpan: 2, action: .delete),
                 .init(id: "gojuon-space", label: "空白", row: 1, column: centralColumns + 2, columnSpan: 2, action: .space),
                 .init(id: "gojuon-enter", label: "改行", row: 2, column: centralColumns + 2, rowSpan: 3, columnSpan: 2, action: .enter)]
        guard let grid = try? KeyboardGrid(layout: .init(rows: 5, columns: centralColumns + 4, keys: keys), horizontalGap: 0, verticalGap: 0,
                                          columnWeights: [1, 1] + Array(repeating: 11 / CGFloat(centralColumns), count: centralColumns) + [1, 1], makeKey: { definition in
            let side = definition.column < 2 || definition.column == centralColumns + 2
            let special = side
            let appearance = self.keyAppearance(special: special)
            let key: UIButton = definition.action == .text ? FlickKey(type: .custom) : RepeatingKey(type: .system)
            key.accessibilityIdentifier = definition.id
            key.isEnabled = !definition.label.isEmpty
            key.isAccessibilityElement = !definition.label.isEmpty
            key.accessibilityLabel = definition.label
            key.setTitle(definition.label, for: .normal)
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.titleLabel?.adjustsFontSizeToFitWidth = true
            key.titleLabel?.minimumScaleFactor = 0.5
            if definition.label == "「」" {
                key.setTitle("「\n」", for: .normal)
                key.titleLabel?.numberOfLines = 2
                key.titleLabel?.textAlignment = .center
            }
            key.setTitleColor(palette.foreground, for: .normal)
            key.backgroundColor = side ? palette.function : palette.key
            key.layer.cornerRadius = side ? self.geometry.keyCornerRadius : 0
            if !side {
                key.layer.borderWidth = 0.5
                key.layer.borderColor = palette.function.cgColor
            }
            if let icon: KeyboardIcon = [.cursorLeft: .left, .delete: .delete, .space: .space, .enter: .enter, .nextKeyboard: .globe][definition.action] {
                key.setTitle(nil, for: .normal); key.setImage(icon.image, for: .normal); key.tintColor = palette.foreground
            }
            if let icon: KeyboardIcon = ["gojuon-right": .right, "gojuon-previous": .undo][definition.id] {
                key.setTitle(nil, for: .normal); key.setImage(icon.image, for: .normal); key.tintColor = palette.foreground
            }
            if !side && definition.action == .changeMode {
                let selected = definition.id == "gojuon-4-10" ? self.gojuonFullWidth : definition.id == "gojuon-4-0" && (self.gojuonShift || self.gojuonCapsLock)
                if selected { key.backgroundColor = palette.function }
            }
            if definition.action == .modifier {
                key.setTitle("゛゜\n小", for: .normal)
                key.titleLabel?.numberOfLines = 2
                key.titleLabel?.textAlignment = .center
                key.accessibilityLabel = "゛小"
                key.accessibilityHint = "タップで小文字・濁点"
            }
            if definition.action == .nextKeyboard {
                self.configureKeyboardSwitch(key)
            }
            if let flickKey = key as? FlickKey {
                let sourceColumn = Int(definition.id.split(separator: "-").last!)!
                var outputs = GojuonInput.outputs(row: definition.row, column: sourceColumn, mode: self.gojuonMode)
                if self.gojuonMode != .japanese, outputs.count == 5 {
                    let slot = self.gojuonFullWidth ? ((self.gojuonShift || self.gojuonCapsLock) ? 3 : 2) : ((self.gojuonShift || self.gojuonCapsLock) ? 1 : 0)
                    outputs[0] = outputs[slot]
                }
                flickKey.directionalValues = outputs
                flickKey.restingTitle = appearance.guidesVisible ? outputs.first : (definition.label == "「」" ? "「\n」" : definition.label)
                flickKey.setTitle(flickKey.restingTitle, for: .normal)
                flickKey.thresholdShape = .radial
                flickKey.onFlick = { [weak self] direction in
                    guard outputs.indices.contains(direction.rawValue), !outputs[direction.rawValue].isEmpty else { return }
                    self?.insertGojuon(outputs[direction.rawValue], direction: direction)
                }
                flickKey.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
            }
            key.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if definition.action == .nextKeyboard { return }
                if definition.action == .text { self.pressed(definition.label == "「」" ? "「" : definition.label) }
                else if definition.id == "gojuon-right" {
                    self.beforeInput?(); self.moveCompositionCursor(by: 1)
                } else if definition.id == "gojuon-previous" {
                    self.beforeInput?()
                    if let last = self.composition.characterBeforeCursor, let previous = GojuonInput.previous(last, mode: self.gojuonMode) {
                        _ = self.composition.replaceLast(String(previous)); self.refreshConversion()
                    }
                } else if definition.id == "gojuon-symbols" { self.showSymbolKeyboard()
                } else if definition.id == "gojuon-mode" {
                    self.beforeInput?(); self.tapCycle.reset()
                    self.gojuonMode = self.gojuonMode.next
                    self.gojuonShift = false; self.gojuonCapsLock = false; self.gojuonFullWidth = false
                    self.gojuonLastShiftTap = 0; self.rebuild()
                } else if definition.id == "gojuon-4-10" && self.gojuonMode != .japanese {
                    self.gojuonFullWidth.toggle(); self.rebuild()
                } else if definition.id == "gojuon-4-0" && self.gojuonMode == .english {
                    let now = Date.timeIntervalSinceReferenceDate
                    if now - self.gojuonLastShiftTap < 0.3 { self.gojuonCapsLock = true; self.gojuonShift = false }
                    else if self.gojuonCapsLock { self.gojuonCapsLock = false; self.gojuonShift = false }
                    else { self.gojuonShift.toggle() }
                    self.gojuonLastShiftTap = now; self.rebuild()
                } else if definition.id == "gojuon-4-3" && self.gojuonMode == .english {
                    self.beforeInput?()
                    if let last = self.composition.characterBeforeCursor {
                        let text = String(last), lower = String(last).lowercased()
                        _ = self.composition.replaceLast(text == lower ? text.uppercased() : lower)
                        self.refreshConversion()
                    }
                } else if definition.id == "gojuon-4-0" && self.gojuonMode == .number {
                    // Gojuon ModeNumber remaps KeyKuten to KeyDakutenSmall;
                    // IMEService switches to the QWERTY surface for this action.
                    self.selectKeyboard(.english, customID: nil)
                } else if definition.action == .changeMode { self.showDataNotice("この操作は移植中です") }
                else { self.sumireAction(definition.action) }
            }, for: .touchUpInside)
            return SizedKey(key, scale: appearance.keyScale)
        }) else { return }
        stack.addArrangedSubview(grid)
    }
    private func insertGojuon(_ text: String, direction: FlickDirection) {
        beforeInput?(); tapCycle.reset()
        if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
        containsRomaji = false
        appendLearningInput(text); refreshConversion()
        if gojuonMode == .english && direction == .tap && gojuonShift {
            gojuonShift = false; rebuild()
        }
    }
    private func addQwertyGrid(palette: KeyboardPalette) {
        let japanese = inputMode == .romaji
        let page = japanese ? romajiPage : englishPage
        let pageColumn = japanese || customEnglishVisible || sumireEnglishQWERTYVisible ? 1 : 0
        let characters: [String]
        switch page {
        case 1: characters = japanese ? ["1234567890", "-/:@()「」￥&", "。、?!'"] : ["1234567890", "-/:;()¥&@\"", ".,?!'"]
        case 2: characters = japanese ? ["[]{}#%^*+=", "_/;|<>\"'$€", ".,?!・"] : ["[]{}#%^*+=", "_/\\~<>$€£·", ".,?!'"]
        default: characters = shifted ? ["QWERTYUIOP", japanese ? "ASDFGHJKLー" : "ASDFGHJKL", "ZXCVBNM"] : ["qwertyuiop", japanese ? "asdfghjklー" : "asdfghjkl", "zxcvbnm"]
        }
        var values = characters.map { $0.map(String.init) }
        values[2] = [page == 0 ? "⇧" : page == 1 ? "#+=" : "123"] + values[2] + ["⌫"]
        values.append((customEnglishVisible ? ["あa1"] : sumireEnglishQWERTYVisible ? ["あ"] : japanese ? [romajiLatin ? "aあ" : "あa"] : []) + [page == 0 ? "123" : "ABC", "🌐", "空白", "改行"])
        let rows = values.enumerated().map { row, values in
            values.enumerated().map { column, value -> UIView in
                let special = row == 3 || row == 2 && (column == 0 || column == values.count - 1)
                let appearance = keyAppearance(special: special)
                let key: UIButton = !special ? FlickKey(type: .custom) : RepeatingKey(type: .system)
                if !special && page == 0 { key.accessibilityIdentifier = "qwerty-character-" + value.lowercased() }
                else if !special { key.accessibilityIdentifier = "qwerty-symbol-\(page)-\(row)-\(column)" }
                key.setTitle(value, for: .normal)
                key.accessibilityLabel = value == "⌫" ? "削除" : value
                key.backgroundColor = special ? palette.function : palette.key
                key.setTitleColor(palette.foreground, for: .normal)
                key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
                key.layer.cornerRadius = geometry.keyCornerRadius
                if let icon: KeyboardIcon = ["🌐": .globe, "⌫": .delete, "改行": .enter, "⇧": .shift][value] {
                    key.setTitle(nil, for: .normal); key.setImage(icon.image, for: .normal); key.tintColor = palette.foreground
                }
                if let flickKey = key as? FlickKey { configureQwertyFlick(flickKey, label: value) }
                if value == "🌐" { configureKeyboardSwitch(key) }
                else if value == "⇧" {
                    key.accessibilityIdentifier = "qwerty-shift"
                    key.accessibilityValue = qwertyCapsLock ? "Caps Lock" : shifted ? "ON" : "OFF"
                    if qwertyCapsLock { key.setImage(UIImage(systemName: "capslock.fill"), for: .normal) }
                    key.addAction(UIAction { [weak self] _ in self?.pressed("⇧") }, for: .touchUpInside)
                }
                else if customEnglishVisible && row == 3 && column == 0 {
                    key.accessibilityIdentifier = "custom-input-mode-return"
                    key.accessibilityLabel = "カスタム配列に戻る"
                    key.addAction(UIAction { [weak self] _ in self?.setCustomEnglishPresentation(false) }, for: .touchUpInside)
                }
                else if sumireEnglishQWERTYVisible && row == 3 && column == 0 {
                    key.accessibilityIdentifier = "sumire-qwerty-return"
                    key.accessibilityLabel = "日本語モードへ戻る"
                    key.addAction(UIAction { [weak self] _ in self?.executeSpecialAction(.switchKana) }, for: .touchUpInside)
                }
                else if japanese && row == 3 && column == 0 {
                    key.accessibilityIdentifier = "qwerty-input-mode"
                    key.addAction(UIAction { [weak self] _ in
                        self?.romajiLatin.toggle(); self?.rebuild()
                    }, for: .touchUpInside)
                } else if row == 3 && column == pageColumn || row == 2 && column == 0 && page != 0 {
                    key.accessibilityIdentifier = row == 3 ? "qwerty-page-toggle" : "qwerty-symbol-page-toggle"
                    key.addAction(UIAction { [weak self] _ in
                        guard let self else { return }
                        let next = row == 3 ? (page == 0 ? 1 : 0) : (page == 1 ? 2 : 1)
                        if page == 0 {
                            self.shifted = false; self.qwertyCapsLock = false; self.qwertyLastShiftTap = 0
                        }
                        if japanese { self.romajiPage = next } else { self.englishPage = next }
                        self.rebuild()
                    }, for: .touchUpInside)
                } else { key.addAction(UIAction { [weak self, weak key] _ in self?.pressed(key?.currentTitle ?? value) }, for: .touchUpInside) }
                return SizedKey(key, scale: appearance.keyScale)
            }
        }
        let grid = QwertyKeyboardGrid(rows: rows, letters: page == 0 && !japanese, gap: geometry.keySpacing)
        stack.addArrangedSubview(grid)
        let minimum = grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 176)
        minimum.priority = .defaultLow; minimum.isActive = true
    }
    private func updateQwertyCase() {
        guard let grid = stack.arrangedSubviews.last as? QwertyKeyboardGrid else { return }
        for case let wrapper as SizedKey in grid.subviews {
            let key = wrapper.key
            if let id = key.accessibilityIdentifier, id.hasPrefix("qwerty-character-") {
                let base = String(id.dropFirst("qwerty-character-".count))
                let title = shifted ? base.uppercased() : base
                key.setTitle(title, for: .normal); key.accessibilityLabel = title
                if let flickKey = key as? FlickKey { configureQwertyFlick(flickKey, label: title) }
            } else if key.accessibilityIdentifier == "qwerty-shift" {
                key.accessibilityValue = qwertyCapsLock ? "Caps Lock" : shifted ? "ON" : "OFF"
                key.setImage(qwertyCapsLock ? UIImage(systemName: "capslock.fill") : KeyboardIcon.shift.image, for: .normal)
            }
        }
    }
    private func configureQwertyFlick(_ key: FlickKey, label: String) {
        let prefix = "qwerty.\(keyboardKind.rawValue).flick"
        let japanese = inputMode == .romaji
        let page = japanese ? romajiPage : englishPage
        let up = settingsDefaults.bool(forKey: prefix + "Up"), down = settingsDefaults.bool(forKey: prefix + "Down")
        key.directionalValues = page == 0 ? QwertyFlick.outputs(for: label, japanese: japanese, up: up, down: down) :
            QwertyFlick.pageOutputs(for: label, page: page, japanese: japanese, up: up, down: down)
        if japanese, var outputs = key.directionalValues, outputs.count == 5 {
            let numbers = settingsDefaults.bool(forKey: "qwerty.romaji.halfWidthNumbers")
            let symbols = settingsDefaults.bool(forKey: "qwerty.romaji.halfWidthSymbols")
            if page != 0 { outputs[0] = QwertyFlick.japaneseWidth(outputs[0], halfWidthNumbers: numbers, halfWidthSymbols: symbols) }
            outputs[2] = QwertyFlick.japaneseWidth(outputs[2], halfWidthNumbers: numbers, halfWidthSymbols: symbols)
            key.directionalValues = outputs
        }
        key.restingTitle = label
        key.thresholdShape = .radial
        let style = keyAppearance()
        key.titleLabel?.font = .systemFont(ofSize: style.keyFontSize)
        key.configureGuides(visible: style.guidesVisible, fontSize: style.guideFontSize, color: key.titleColor(for: .normal) ?? .label)
        key.onFlick = { [weak self, weak key] direction in
            guard let self, let outputs = key?.directionalValues, outputs.count == 5 else { return }
            let output = outputs[direction.rawValue]
            if (direction == .up && up || direction == .down && down) && output.isEmpty { return }
            guard direction != .tap && !output.isEmpty else { self.pressed(outputs[0]); return }
            self.beforeInput?(); self.tapCycle.reset()
            if self.displayedInputMode == .english {
                self.insertEnglish(output)
            } else {
                if self.containsRomaji, let romaji = self.romaji { _ = self.composition.flushRomaji(using: romaji) }
                self.containsRomaji = false
                self.appendLearningInput(output); self.refreshConversion()
            }
            self.consumeQwertyShift()
        }
    }
    private func addCustomGrid(palette: KeyboardPalette, presentation: ImportedCustomLayout? = nil) {
        guard let ownerLayout = customLayouts.first(where: { $0.id == activeCustomID }) else {
            status.text = "カスタム配列が選択されていません"
            addRow(["50音", "🌐"], palette: palette, special: true)
            return
        }
        customDisplayRefreshes = []
        let layout = presentation ?? ownerLayout
        let targets = CustomLayoutTargets(layouts: customLayouts)
        let tapController = CustomDoubleTapController()
        tapController.onAction = { [weak self] action in self?.customAction(action, layout: ownerLayout) }
        customTapController = tapController
        let grid = CustomKeyboardGrid(layout: layout) { [weak self] placement in
            guard let self else { return UIView() }
            let definition = placement.source["key"]
            let special = definition?["isSpecialKey"] == .bool(true)
            let appearance = self.keyAppearance(special: special)
            let label = definition?["label"]?.string ?? ""
            let type = definition?["keyType"]?.string ?? "NORMAL"
            let runtime: CustomMultiStageFlick.RuntimeDefinition?
            let runtimeError: Error?
            do {
                runtime = try CustomMultiStageFlick.runtimeDefinition(for: placement, targets: targets)
                runtimeError = nil
            } catch {
                runtime = nil
                runtimeError = error
            }
            let key: UIButton = type == "NORMAL" ? RepeatingKey(type: .custom) : MultiStageFlickKey(type: .custom)
            key.setTitle(label, for: .normal)
            key.accessibilityIdentifier = "custom-" + placement.id
            key.accessibilityLabel = label
            key.backgroundColor = special ? palette.function : palette.key
            key.setTitleColor(palette.foreground, for: .normal)
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.titleLabel?.numberOfLines = 2
            key.titleLabel?.textAlignment = .center
            key.titleLabel?.adjustsFontSizeToFitWidth = true
            key.titleLabel?.minimumScaleFactor = 0.5
            key.layer.cornerRadius = self.geometry.keyCornerRadius

            let tapAction: CustomKeyAction
            if let raw = definition?["action"]?.string {
                tapAction = .tap(raw, targets: targets)
            } else if !special {
                tapAction = .text(label)
            } else {
                tapAction = .unsupported(raw: placement.id, reason: "キーの操作が未設定です")
            }
            let normalAction = tapAction
            self.customKeyFeedbackActions[ObjectIdentifier(key)] = normalAction
            let textLabels = Set(((runtime.map { Self.customActions(in: $0, targets: targets) } ?? []) + [normalAction]).compactMap { action -> String? in
                if case .text(let value) = action { return value }
                return nil
            })
            if let flick = key as? MultiStageFlickKey {
                flick.displayTransform = { [weak self] value in
                    textLabels.contains(value) ? (self?.customShift.applying(to: value) ?? value) : value
                }
            }
            let refreshDisplay = { [weak self, weak key] in
                guard let self, let key else { return }
                let transformMain: Bool
                if case .text = normalAction { transformMain = true }
                else { transformMain = !special && type != "NORMAL" }
                if transformMain {
                    let title = self.customShift.applying(to: label)
                    key.setTitle(title, for: .normal); key.accessibilityLabel = title
                }
                if case .command(let command) = normalAction, command == .shift || command == .capsLock {
                    let icon: KeyboardIcon = command == .shift
                        ? (self.customShift == .locked ? .capsLock : self.customShift == .oneShot ? .shiftActive : .shift)
                        : (self.customShift == .locked ? .capsLock : .capsLockOutline)
                    key.setTitle(nil, for: .normal); key.setImage(icon.image, for: .normal)
                    key.tintColor = palette.foreground
                    key.accessibilityValue = self.customShift == .locked ? "Caps Lock" : self.customShift == .oneShot ? "ON" : "OFF"
                }
                (key as? MultiStageFlickKey)?.refreshDisplayedText()
            }
            self.customDisplayRefreshes.append(refreshDisplay)
            refreshDisplay()
            if case .command(let command) = normalAction, command == .switchDirect || command == .switchRomaji {
                let mode = self.customInputMode(for: ownerLayout)
                let icon: KeyboardIcon = command == .switchDirect
                    ? (mode.direct ? .directOn : .directOff) : (mode.romaji ? .romajiOn : .romajiOff)
                key.setTitle(nil, for: .normal)
                key.setImage(icon.image, for: .normal)
                key.tintColor = palette.foreground
                key.accessibilityValue = command == .switchDirect
                    ? (mode.direct ? "直接入力" : "変換入力") : (mode.romaji ? "ローマ字" : "かな")
            }
            if presentation != nil {
                let icons: [CustomKeyAction.Command: KeyboardIcon] = [
                    .nextKeyboard: .globe, .space: .space, .delete: .delete, .newLine: .enter]
                if case .command(let command) = normalAction, let icon = icons[command] {
                    key.setTitle(nil, for: .normal)
                    key.setImage(icon.image, for: .normal)
                    key.tintColor = palette.foreground
                }
            }
            let doubleTap = CustomDoubleTapBinding.effective(definition: definition, normalAction: normalAction, targets: targets)

            if let error = runtimeError {
                key.isEnabled = false
                key.accessibilityHint = error.localizedDescription
            }
            if type != "NORMAL", runtimeError == nil, runtime == nil {
                key.isEnabled = false
                key.accessibilityHint = "このカスタム入力方式の定義がありません"
            }

            let actions = (runtime.map { Self.customActions(in: $0, targets: targets) } ?? []) +
                [normalAction] + (doubleTap.map { [$0.action] } ?? [])
            let needsExclusiveTouch = actions.contains { action in
                switch action {
                case .switchLayout, .command(.changeMode), .command(.switchKana), .command(.switchEnglish), .command(.switchNumber), .command(.switchDirect), .command(.switchRomaji), .command(.nextKeyboard), .command(.moveCustomKeyboardTab): return true
                default: return false
                }
            }
            if let repeating = key as? RepeatingKey {
                repeating.exclusiveTouchAction = needsExclusiveTouch
                repeating.blocksSequentialTouches = actions.contains(.command(.nextKeyboard))
                repeating.repeatEnabled = [.command(.delete), .command(.backspace), .command(.cursorLeft), .command(.cursorRight)].contains(normalAction)
                repeating.longPressCancelsTap = normalAction == .command(.deleteAfterCursor)
                switch normalAction {
                case .switchLayout, .command(.changeMode), .command(.switchKana), .command(.switchEnglish), .command(.switchNumber), .command(.switchDirect), .command(.switchRomaji), .command(.moveCustomKeyboardTab): repeating.exclusiveTouchAction = true
                case .command(.nextKeyboard): repeating.exclusiveTouchAction = true; repeating.blocksSequentialTouches = true
                default: break
                }
                repeating.onCommittedPress = { isTap in
                    if isTap {
                        tapController.committedTap(keyIdentity: placement.id, action: normalAction, binding: doubleTap)
                    } else if normalAction == .command(.deleteAfterCursor) {
                        // The long press is consumed without an action, but it still
                        // separates any pending double-tap sequence from later taps.
                        tapController.interrupt()
                    } else {
                        tapController.committedGesture(normalAction)
                    }
                }
            } else if let flick = key as? MultiStageFlickKey, let runtime {
                flick.definition = runtime.gesture
                flick.styleSettings = FlickStyleSettings.load(defaults: settingsDefaults)
                flick.exclusiveTouchAction = needsExclusiveTouch
                flick.blocksSequentialTouches = actions.contains(.command(.nextKeyboard))
                flick.configureGuides(visible: appearance.guidesVisible,
                                      fontSize: appearance.guideFontSize, color: palette.foreground)
                flick.onCommit = { event in
                    var suppressesPendingTap = false
                    guard let action = Self.customAction(for: event, runtime: runtime, targets: targets,
                                                         suppressesPendingTap: &suppressesPendingTap) else {
                        if suppressesPendingTap { tapController.interrupt() }
                        return
                    }
                    if event.isPureTap {
                        let binding = CustomDoubleTapBinding.effective(definition: definition, normalAction: action, targets: targets)
                        tapController.committedTap(keyIdentity: placement.id, action: action, binding: binding)
                    } else { tapController.committedGesture(action) }
                }
            } else if let flick = key as? MultiStageFlickKey {
                flick.isEnabled = false
            }
            return SizedKey(key, scale: appearance.keyScale)
        }
        stack.addArrangedSubview(grid)
        if presentation == nil { addRow(["🌐", "空白", "⌫", "改行"], palette: palette, special: true) }
        if presentation == nil, let row = keyRows.last {
            let height = row.heightAnchor.constraint(equalToConstant: 44)
            height.priority = .defaultHigh
            height.isActive = true
        }
        let minimum = grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimum.priority = .defaultLow
        minimum.isActive = true
    }

    private static func customAction(for event: MultiStageFlickKey.CommitEvent,
                                     runtime: CustomMultiStageFlick.RuntimeDefinition,
                                     targets: CustomLayoutTargets,
                                     suppressesPendingTap: inout Bool) -> CustomKeyAction? {
        func tapOnly(_ action: CustomKeyAction?) -> CustomKeyAction? {
            guard event.isLongPress, action == .command(.deleteAfterCursor) else { return action }
            suppressesPendingTap = true
            return nil
        }
        if event.circularSlot != nil {
            switch event.output {
            case .text(let text, _): return .text(text)
            case .action(let type, let value, _):
                return tapOnly(.flick(type: type, value: value, targets: targets))
            case .referenceAction(let action, _):
                // The same pinned action vocabulary is used by built-in reference maps.
                let type = action["type"]?.string ?? ""
                let value = action["text"]?.string
                return tapOnly(.flick(type: type, value: value, targets: targets))
            case .mapSwitch: return .command(.moveCustomKeyboardTab)
            }
        }
        if let direction = event.direction {
            if event.isLongPress, let alternate = runtime.longPressActions[direction] { return tapOnly(alternate) }
            if let action = runtime.actions[direction] { return tapOnly(action) }
        }
        if case .text(let text, _) = event.output, !text.isEmpty { return .text(text) }
        return nil
    }

    private static func customActions(in runtime: CustomMultiStageFlick.RuntimeDefinition,
                                      targets: CustomLayoutTargets) -> [CustomKeyAction] {
        switch runtime.gesture {
        case .single:
            return Array(runtime.actions.values) + Array(runtime.longPressActions.values)
        case .twoStep, .hierarchical:
            return []
        case .circular(let maps):
            return maps.flatMap { map in
                map.values.compactMap { output in
                    switch output {
                    case .text(let text, _): return .text(text)
                    case .action(let type, let value, _): return .flick(type: type, value: value, targets: targets)
                    case .referenceAction(let action, _):
                        return .flick(type: action["type"]?.string ?? "",
                                      value: action["text"]?.string, targets: targets)
                    case .mapSwitch: return .command(.moveCustomKeyboardTab)
                    }
                }
            }
        }
    }

    private func customAction(_ action: CustomKeyAction, layout: ImportedCustomLayout) {
        beforeInput?(); tapCycle.reset()
        switch action {
        case .unsupported(_, let reason): status.text = reason
        case .switchLayout(let id):
            customShift = .off
            customModeOverrides.removeValue(forKey: id)
            activeCustomID = id; rememberKeyboard(); rebuild()
        case .inputText(let token):
            if let marker = SumireFlickMarker(rawValue: token) {
                applyCustomInputMarker(marker)
            } else if token == "^_^" {
                if hasComposition { applyCustomInputMarker(.small) }
                else { showSymbolKeyboard() }
            } else if token == ":" || token == "-" {
                insertCustomInputPunctuation(token, layout: layout)
            } else { showDataNotice("このInputText操作は未対応です: " + token) }
        case .text(let text):
            insertCustomText(text, layout: layout)
        case .command(let command):
            switch command {
            case .doNothing: break
            case .shift: customShift.tapShift(); refreshCustomShiftDisplay()
            case .capsLock: customShift.tapCapsLock(); refreshCustomShiftDisplay()
            case .delete, .backspace: pressed("⌫")
            case .deleteAfterCursor:
                if hasComposition {
                    if composition.deleteForward() { tapCycle.reset(); refreshConversion() }
                } else { deleteForward?() }
            case .space, .convert:
                if customInputMode(for: layout).direct { insertCustomDirect(" ") } else { pressed("空白") }
            case .enter, .newLine, .confirm:
                if customInputMode(for: layout).direct { insertCustomDirect("\n") } else { pressed("改行") }
            case .paste: sumireAction(.paste)
            case .cursorLeft: sumireAction(.cursorLeft)
            case .cursorRight: moveCompositionCursor(by: 1)
            case .deleteUntilBoundary: executeSpecialAction(.deleteUntilBoundary, prepareInput: false)
            case .openSymbols: showSymbolKeyboard()
            case .nextKeyboard: pressed("🌐")
            case .modifier, .toggleCase: applyCustomCharacterModifier()
            case .changeMode: setCustomEnglishPresentation(!customNumberVisible)
            case .switchKana: setCustomEnglishPresentation(false)
            case .switchEnglish: setCustomEnglishPresentation(true)
            case .switchNumber: showCustomNumberPresentation()
            case .switchDirect: toggleCustomInputMode(layout: layout, direct: true)
            case .switchRomaji: toggleCustomInputMode(layout: layout, direct: false)
            case .moveCustomKeyboardTab:
                guard !customLayouts.isEmpty else { status.text = "切り替え先のカスタム配列がありません"; return }
                customShift = .off
                let currentIndex = customLayouts.firstIndex { $0.id == activeCustomID } ?? -1
                activeCustomID = customLayouts[(currentIndex + 1) % customLayouts.count].id
                if let id = activeCustomID { customModeOverrides.removeValue(forKey: id) }
                rememberKeyboard(); rebuild()
            case .forceNewLine:
                if customInputMode(for: layout).direct { insertCustomDirect("\n") }
                else if hasComposition { commitComposition() } else { insert?("\n") }
            case .halfSpace, .fullSpace:
                if customInputMode(for: layout).direct { insertCustomDirect(" ") }
                else if hasComposition { pressed("空白") }
                else { insert?(command == .fullSpace ? "　" : " ") }
            case .commitAndSpace:
                if customInputMode(for: layout).direct { insertCustomDirect(" ") } else { commitRawAtCursorAndSpace() }
            }
        }
    }
    private func applyCustomCharacterModifier() {
        guard let previous = composition.characterBeforeCursor,
              let changed = CustomCharacterModifier.modified(previous) else { return }
        _ = composition.replaceLast(String(changed))
        refreshConversion()
    }
    private func applyCustomInputMarker(_ marker: SumireFlickMarker) {
        guard let previous = composition.characterBeforeCursor,
              let changed = marker.applying(to: previous) else { return }
        _ = composition.replaceLast(String(changed))
        refreshConversion()
    }
    private func insertCustomInputPunctuation(_ text: String, layout: ImportedCustomLayout) {
        if customInputMode(for: layout).direct {
            insertCustomDirect(text)
        } else {
            // InputText punctuation bypasses romaji conversion in the reference.
            // Preserve any pending roman prefix rather than flushing it here.
            appendLearningInput(text); refreshConversion()
        }
    }
    private func refreshCustomShiftDisplay() {
        customDisplayRefreshes.forEach { $0() }
    }
    private func insertCustomText(_ text: String, layout: ImportedCustomLayout) {
        guard !text.isEmpty else { return }
        let shiftedText = customShift.applying(to: text)
        defer { customShift.consumeText(text); refreshCustomShiftDisplay() }
        if customInputMode(for: layout).direct {
            insertCustomDirect(shiftedText)
        } else if customInputMode(for: layout).romaji, let romaji {
            containsRomaji = true
            if text.utf16.count == 1 {
                if isDefaultCustomRomaji && customShift.isActive {
                    appendLearningInput(text)
                    composition.transformPrefix { customShift.applying(to: $0) }
                } else {
                    appendLearningRomaji(text, using: romaji)
                    if !isDefaultCustomRomaji { composition.transformPrefix { customShift.applying(to: $0) } }
                }
            } else { appendLearningRomaji(shiftedText, using: romaji) }
            refreshConversion()
        } else {
            if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
            containsRomaji = false; appendLearningInput(shiftedText); refreshConversion()
        }
    }
    private func addSumireGrid(palette: KeyboardPalette) {
        let arrangement = SumireKeyArrangement(rawValue: settingsDefaults.string(forKey: "sumire.keyArrangement") ?? "") ?? .toggle
        let style = FlickStyleSettings.load(defaults: settingsDefaults)
        let slots = CircularSlotSetting.load(defaults: settingsDefaults)
        do { sumireFlickProfile = try ReferenceFlickMaps(arrangement: arrangement, mode: sumireMode, style: style.style) }
        catch { showDataNotice("入力スタイルの定義を読み込めません: " + error.localizedDescription) }
        guard let grid = try? KeyboardGrid(layout: arrangement.layout(mode: sumireMode),
                                          horizontalGap: geometry.keySpacing,
                                          verticalGap: geometry.rowSpacing, makeKey: { [weak self] definition in
            guard let self else { return UIView() }
            let appearance = keyAppearance(special: definition.action != .text && definition.action != .modifier)
            if definition.action == .text {
                let index = definition.row * 3 + definition.column - 1
                let key = MultiStageFlickKey(type: .custom)
                key.styleSettings = style
                let reference = sumireFlickProfile?.key(row: definition.row, column: definition.column)
                do {
                    if let reference { key.definition = try sumireFlickProfile?.definition(for: reference, settings: style, slotSettings: slots) }
                    if key.definition == nil { throw PersonalDataError("キーの入力定義がありません") }
                } catch {
                    key.isEnabled = false
                    key.accessibilityHint = error.localizedDescription
                    showDataNotice("入力スタイルのキーを読み込めません: " + error.localizedDescription)
                }
                let title = reference?.label ?? definition.label
                key.setTitle(title, for: .normal)
                key.accessibilityLabel = String(title.prefix(1))
                key.accessibilityIdentifier = "sumire-" + definition.id
                key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
                key.titleLabel?.numberOfLines = 2
                key.titleLabel?.textAlignment = .center
                key.titleLabel?.adjustsFontSizeToFitWidth = true
                key.titleLabel?.minimumScaleFactor = 0.5
                key.setTitleColor(palette.foreground, for: .normal)
                key.backgroundColor = palette.key
                key.layer.cornerRadius = geometry.keyCornerRadius
                // The reference STANDARD/HIERARCHICAL listeners always dispatch
                // as flick input, including a center release (FlickKeyboardView).
                // Other built-in controllers classify their final direction;
                // a hold or an earlier excursion does not itself force flick input.
                let supportsTapCycle = reference?.keyType != "STANDARD_FLICK" && reference?.keyType != "HIERARCHICAL_FLICK"
                key.onCommit = { [weak self] event in
                    self?.sumireStyleOutput(event.output, index: index, tapInput: event.isTap && supportsTapCycle)
                }
                if !appearance.guidesVisible, title.contains("\n") {
                    let label = title as NSString
                    let newline = label.range(of: "\n").location
                    let secondarySize = settingsDefaults.object(forKey: "appearance.sumire.guideFontSize") == nil
                        ? max(8, appearance.keyFontSize * 0.625) : appearance.guideFontSize
                    let text = NSMutableAttributedString(string: title, attributes: [
                        .font: UIFont.systemFont(ofSize: appearance.keyFontSize), .foregroundColor: palette.foreground])
                    text.addAttribute(.font, value: UIFont.systemFont(ofSize: secondarySize),
                        range: NSRange(location: newline + 1, length: label.length - newline - 1))
                    key.setAttributedTitle(text, for: .normal)
                }
                key.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
                if appearance.guidesVisible { key.setTitle(String(title.prefix(1)), for: .normal) }
                return SizedKey(key, scale: appearance.keyScale)
            }
            let configuredKey = SumireSpecialKeyID.resolve(definition.id, arrangement: arrangement, mode: self.sumireMode)
            let directional = configuredKey != nil && definition.action != .nextKeyboard
            let key: UIButton = directional ? DirectionalActionKey(type: .system) : RepeatingKey(type: .system)
            key.setTitle(definition.label, for: .normal)
            key.accessibilityLabel = definition.label
            key.accessibilityIdentifier = "sumire-" + definition.id
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.setTitleColor(palette.foreground, for: .normal)
            key.tintColor = palette.foreground
            key.backgroundColor = definition.action == .modifier ? palette.key : palette.function
            key.layer.cornerRadius = geometry.keyCornerRadius
            let icon: KeyboardIcon? = [.paste: .paste, .cursorLeft: .left,
                                       .nextKeyboard: .globe, .delete: .delete, .enter: .enter,
                                       .space: .space][definition.action]
            if let icon {
                key.setTitle(nil, for: .normal)
                key.setImage(icon.image, for: .normal)
                key.tintColor = palette.foreground
            }
            if definition.id == "cursor_right_key" {
                key.setTitle(nil, for: .normal); key.setImage(KeyboardIcon.right.image, for: .normal)
            }
            if definition.action == .nextKeyboard {
                // Retain UIKit's public long-press UIMenu on the globe key.
                self.configureKeyboardSwitch(key, cycleOnTap: false)
                let hold = self.specialKeySettings.action(for: .keyboardSwitch, gesture: .longPress,
                    arrangement: arrangement, mode: self.sumireMode, hasComposition: self.hasComposition)
                if let reason = hold.unavailabilityReason(for: .keyboardSwitch, gesture: .longPress, mode: self.sumireMode) {
                    let unavailable = UIAction(title: "この長押し操作は iOS で未対応", attributes: .disabled) { _ in }
                    unavailable.subtitle = reason
                    key.menu = UIMenu(children: [unavailable])
                    key.accessibilityHint = reason
                }
                key.addAction(UIAction { [weak self] _ in
                    self?.executeSpecialKey(.keyboardSwitch, gesture: .tap, arrangement: arrangement)
                }, for: .touchUpInside)
            } else if let configuredKey, let gestureKey = key as? DirectionalActionKey {
                gestureKey.action = { [weak self] gesture in
                    self?.executeSpecialKey(configuredKey, gesture: gesture, arrangement: arrangement)
                }
                gestureKey.repeats = { [weak self] gesture in
                    guard let self else { return false }
                    let action = self.specialKeySettings.action(for: configuredKey, gesture: gesture,
                        arrangement: arrangement, mode: self.sumireMode, hasComposition: self.hasComposition)
                    return action.isRepeatable && action.unavailabilityReason(for: configuredKey, gesture: gesture, mode: self.sumireMode) == nil
                }
                gestureKey.longPressEnabled = { [weak self] in
                    guard let self else { return false }
                    let assigned = self.specialKeySettings.assignedAction(for: configuredKey, gesture: .longPress,
                        arrangement: arrangement, mode: self.sumireMode)
                    return assigned != nil || self.specialKeySettings.action(for: configuredKey, gesture: .longPress,
                        arrangement: arrangement, mode: self.sumireMode, hasComposition: self.hasComposition) != .doNothing
                }
                if configuredKey == .spaceConvert {
                    gestureKey.longPressDragEnabled = { [weak self] in
                        guard let self else { return false }
                        let action = self.specialKeySettings.action(for: configuredKey, gesture: .longPress,
                            arrangement: arrangement, mode: self.sumireMode,
                            hasComposition: self.hasComposition)
                        return action == .cursorMoveMode && action.unavailabilityReason(
                            for: configuredKey, gesture: .longPress, mode: self.sumireMode) == nil
                    }
                    gestureKey.longPressDrag = { [weak self] delta in
                        self?.moveSpaceCursor(by: delta)
                    }
                    gestureKey.longPressDragEnded = { [weak self] in
                        self?.endSpaceCursorMoveMode()
                    }
                }
            } else {
                // The dakuten/case key is a normal key in the reference and
                // retains its existing dynamic modifier behavior.
                key.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if definition.action == .modifier && self.sumireMode == .english {
                        self.beforeInput?(); self.tapCycle.reset()
                        if let last = self.composition.characterBeforeCursor, last.isASCII, last.isLetter {
                            let text = String(last)
                            _ = self.composition.replaceLast(last.isUppercase ? text.lowercased() : text.uppercased())
                            self.refreshConversion()
                        }
                    } else { self.sumireAction(definition.action) }
                }, for: .touchUpInside)
            }
            return SizedKey(key, scale: appearance.keyScale)
        }) else { return }
        stack.addArrangedSubview(grid)
        let minimum = grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 176)
        minimum.priority = .defaultLow
        minimum.isActive = true
        updateSumireKeys()
    }
    private func sumireStyleOutput(_ output: CircularFlickOutput, index: Int, tapInput: Bool) {
        switch output {
        case .text(let text, _):
            guard !text.isEmpty else { tapCycle.reset(); return }
            beforeInput?(); katakanaCycle.reset()
            if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
            containsRomaji = false
            let cycle = sumireMode.tapCycle(at: index)
            if tapInput && sumireMode != .number && text == String(cycle.prefix(1)) {
                let choice = tapCycle.choose(cycle, direction: .tap,
                    generation: composition.generation, time: ProcessInfo.processInfo.systemUptime, enabled: tenKeyToggle)
                if choice.replacing { _ = composition.replaceLast(choice.text) }
                else { appendLearningInput(choice.text) }
            } else { tapCycle.reset(); appendLearningInput(text) }
            refreshConversion()
        case .referenceAction(let action, _): dispatchFlickReferenceAction(action)
        case .action(let action, let value, _):
            var reference: [String: LayoutJSON] = ["type": .string(action)]
            if let value { reference["text"] = .string(value) }
            dispatchFlickReferenceAction(.object(reference))
        case .mapSwitch: break // The circular evaluator owns its in-gesture map transition.
        }
    }
    private func dispatchFlickReferenceAction(_ action: LayoutJSON) {
        let type = action["type"]?.string ?? "不明な操作"
        if type == "InputText", let text = action["text"]?.string {
            beforeInput?(); tapCycle.reset(); katakanaCycle.reset()
            if let marker = SumireFlickMarker(rawValue: text) {
                if let previous = composition.characterBeforeCursor, let changed = marker.applying(to: previous) {
                    _ = composition.replaceLast(String(changed)); refreshConversion()
                }
            } else if !text.isEmpty { sumireStyleOutput(.text(text), index: 0, tapInput: false) }
            return
        }
        let actions: [String: SumireSpecialKeyAction] = [
            "MoveCursorLeft": .cursorLeft, "MoveCursorRight": .cursorRight,
            "MoveCursorUp": .cursorUp, "MoveCursorDown": .cursorDown,
            "Delete": .deleteBackward, "DeleteUntilSymbol": .deleteUntilBoundary,
            "Space": .space, "Paste": .paste, "SelectAll": .selectAll, "Copy": .copy,
            "ToggleDakuten": .toggleDakuten, "Convert": .convert,
            "SwitchToKanaLayout": .switchKana, "SwitchToEnglishLayout": .switchEnglish,
            "SwitchToNumberLayout": .switchNumber, "ShowEmojiKeyboard": .openSymbols,
            "NewLine": .enter, "SwitchToNextIme": .nextKeyboard]
        if let mapped = actions[type] { executeSpecialAction(mapped) }
        else { showDataNotice("この入力操作は未対応です: " + type) }
    }
    private func updateSumireKeys() {
        candidateBar.showsShortcuts = !hasComposition
        if inputMode == .tenKey, let grid = stack.arrangedSubviews.last as? KeyboardGrid {
            for case let wrapper as SizedKey in grid.subviews where wrapper.key.accessibilityIdentifier == "keyboard-switch" {
                let key = wrapper.key
                key.setTitle(hasComposition ? (tenKeyMode == .english ? "a/A" : "小゛゜") : nil, for: .normal)
                key.setImage(hasComposition ? nil : KeyboardIcon.globe.image, for: .normal)
                key.accessibilityLabel = hasComposition ? (tenKeyMode == .english ? "大文字・小文字" : "小゛゜") : "キーボード切替"
            }
        }
        guard inputMode == .sumire, let grid = stack.arrangedSubviews.last as? KeyboardGrid else { return }
        let arrangement = SumireKeyArrangement(rawValue: settingsDefaults.string(forKey: "sumire.keyArrangement") ?? "") ?? .toggle
        for case let wrapper as SizedKey in grid.subviews {
            let key = wrapper.key
            switch key.accessibilityIdentifier {
            case "sumire-dakuten_toggle_key" where sumireMode != .number:
                let label = sumireMode == .english ? "a/A" : (hasComposition ? "小゛゜" : "^_^")
                key.setTitle(label, for: .normal); key.accessibilityLabel = label
            case "sumire-space_convert_key":
                let label = hasComposition ? "変換" : "空白"
                key.setTitle(hasComposition ? label : nil, for: .normal)
                key.setImage(hasComposition ? nil : KeyboardIcon.space.image, for: .normal)
                key.accessibilityLabel = label
            case "sumire-enter_key":
                let label = hasComposition ? "確定" : "改行"
                key.setTitle(nil, for: .normal)
                key.setImage((hasComposition ? KeyboardIcon.done : .enter).image, for: .normal)
                key.accessibilityLabel = label
            default: break
            }
            let rawID = key.accessibilityIdentifier == "keyboard-switch" ? "switch_next_ime" :
                String((key.accessibilityIdentifier ?? "").dropFirst("sumire-".count))
            if let specialID = SumireSpecialKeyID.resolve(rawID, arrangement: arrangement, mode: sumireMode) {
                if let directional = key as? DirectionalActionKey {
                    configureSpecialKeyGuides(directional, key: specialID, arrangement: arrangement)
                }
                if specialID == .katakanaToggle {
                    key.setTitle(hasComposition ? "カナ" : "123", for: .normal)
                    key.accessibilityLabel = hasComposition ? "カタカナ切り替え" : "数字モード"
                }
                if let assigned = specialKeySettings.assignedAction(for: specialID, gesture: .tap, arrangement: arrangement, mode: sumireMode) {
                    let icon: KeyboardIcon? = [.deleteBackward: .delete, .cursorLeft: .left, .cursorRight: .right,
                        .paste: .paste, .space: .space, .enter: .enter, .confirm: .done, .nextKeyboard: .globe][assigned]
                    let shortTitle: [SumireSpecialKeyAction: String] = [.doNothing: "—", .deleteUntilBoundary: "区切削除",
                        .changeInputMode: "モード", .switchKana: "あいう", .switchEnglish: "ABC", .switchNumber: "123",
                        .toggleKatakana: "カナ", .toggleDakuten: "小゛゜", .convert: "変換", .insertColon: ":", .insertHyphen: "-"]
                    key.setImage(icon?.image, for: .normal)
                    key.setTitle(icon == nil ? (shortTitle[assigned] ?? assigned.title) : nil, for: .normal)
                    key.titleLabel?.numberOfLines = 2
                    key.titleLabel?.adjustsFontSizeToFitWidth = true
                    key.titleLabel?.minimumScaleFactor = 0.5
                    key.accessibilityLabel = assigned.title
                    key.accessibilityHint = assigned.unavailabilityReason(for: specialID, gesture: .tap, mode: self.sumireMode)
                }
            }
        }
    }
    private static let specialGuideDirections: [(FlickDirection, SumireSpecialKeyGesture)] = [
        (.left, .left), (.up, .up), (.right, .right), (.down, .down)]
    private static let specialGuideLabels: [SumireSpecialKeyAction: String] = [
            .deleteBackward: "削除", .deleteAfterCursorUntilBoundary: "後削除",
            .undoDelete: "戻す", .cursorLeft: "←", .cursorRight: "→", .cursorUp: "↑", .cursorDown: "↓",
            .paste: "貼付", .copy: "コピー", .cut: "切取", .selectAll: "全選択", .space: "空白",
            .convert: "変換", .enter: "改行", .confirm: "確定", .nextKeyboard: "次配列",
            .keyboardMenu: "配列", .changeInputMode: "モード", .switchKana: "かな", .switchEnglish: "ABC",
            .switchNumber: "123", .toggleKatakana: "カナ", .toggleDakuten: "小゛゜", .openSymbols: "記号",
            .insertColon: ":", .insertHyphen: "-"]
    private func configureSpecialKeyGuides(_ button: DirectionalActionKey, key: SumireSpecialKeyID,
                                           arrangement: SumireKeyArrangement) {
        let appearance = keyAppearance(special: true)
        let color = button.titleColor(for: .normal) ?? button.tintColor ?? UIColor.label
        guard appearance.guidesVisible else {
            button.configureGuides(titles: [:], visible: false, fontSize: appearance.guideFontSize, color: color)
            return
        }
        var titles: [FlickDirection: String] = [:]
        for (direction, gesture) in Self.specialGuideDirections {
            let action = specialKeySettings.action(for: key, gesture: gesture, arrangement: arrangement,
                                                   mode: sumireMode, hasComposition: hasComposition)
            if action != .doNothing, action.unavailabilityReason(for: key, gesture: gesture, mode: sumireMode) == nil {
                titles[direction] = action == .deleteUntilBoundary
                    ? (hasComposition ? "全削除" : "区切削除") : (Self.specialGuideLabels[action] ?? action.title)
            }
        }
        button.configureGuides(titles: titles, visible: appearance.guidesVisible,
                               fontSize: appearance.guideFontSize, color: color)
    }

    private func executeSpecialKey(_ key: SumireSpecialKeyID, gesture: SumireSpecialKeyGesture,
                                   arrangement: SumireKeyArrangement) {
        beforeInput?()
        let action = specialKeySettings.action(for: key, gesture: gesture,
            arrangement: arrangement, mode: sumireMode, hasComposition: hasComposition)
        let hasExplicitAction = specialKeySettings.assignedAction(for: key, gesture: gesture,
            arrangement: arrangement, mode: sumireMode) != nil
        if action == .cycleBunsetsuSplitPattern, !hasExplicitAction,
           currentBunsetsuSession == nil {
            _ = toggleSpaceConvertKatakanaIfAllowed()
            return
        }
        if action != .confirm {
            if let state = spaceConvertKanaToggleState,
               state.matches(composition), composition.phase != .selecting {
                if liveConversion && !englishComposition,
                   composition.cursorUTF16 == composition.reading.utf16.count,
                   let generation = resultGeneration, composition.accepts(generation),
                   !converted.isEmpty {
                    let index = selectedCandidate.flatMap { converted.indices.contains($0) ? $0 : nil } ?? 0
                    selectedCandidate = index
                    updateMarkedText?(previewText(converted[index]))
                } else {
                    selectedCandidate = nil
                    markReading()
                }
            }
            spaceConvertKanaToggleState = nil
        }
        executeSpecialAction(action, key: key, gesture: gesture, prepareInput: false)
    }
    private func toggleSpaceConvertKatakanaIfAllowed() -> Bool {
        guard hasComposition, composition.phase != .selecting else { return false }
        tapCycle.reset()
        katakanaCycle.reset()

        // Android's Space long-press has a two-state flag. Its live-conversion
        // order is intentionally the reverse of manual conversion.
        let previous = spaceConvertKanaToggleState.flatMap { $0.matches(composition) ? $0 : nil }
        let sourceReading = previous?.sourceReading ?? composition.reading
        let sourceCursor = previous?.sourceCursor ?? composition.cursor
        let hasConvertedKatakana = !(previous?.hasConvertedKatakana ?? false)
        let showKatakana = liveConversion ? !hasConvertedKatakana : hasConvertedKatakana
        let sourceCursorIndex = sourceReading.index(sourceReading.startIndex, offsetBy: sourceCursor)
        let sourcePrefix = String(sourceReading[..<sourceCursorIndex])
        let displayPrefix = showKatakana
            ? (sourcePrefix.applyingTransform(.hiraganaToKatakana, reverse: false) ?? sourcePrefix)
            : sourcePrefix
        // Android applies the kana candidate only to inputString (the
        // prefix before the caret), then appends the unchanged stringInTail.
        let displayText = displayPrefix + sourceReading[sourceCursorIndex...]
        let state = SpaceConvertKanaToggleState(
            sourceReading: sourceReading,
            sourceCursor: sourceCursor,
            displayText: displayText,
            displayCursorUTF16: displayPrefix.utf16.count,
            hasConvertedKatakana: hasConvertedKatakana,
            generation: composition.generation)
        spaceConvertKanaToggleState = state
        renderSpaceConvertKanaToggle(state)
        return true
    }

    private func renderSpaceConvertKanaToggle(_ state: SpaceConvertKanaToggleState) {
        if let updateMarkedSelection {
            updateMarkedSelection(state.displayText,
                NSRange(location: state.displayCursorUTF16, length: 0))
        } else {
            updateMarkedText?(state.displayText)
        }
    }

    private func beginSpaceCursorMoveMode() {
        spaceCursorMoveModeActive = true
        spaceCursorMoveRemainder = 0
        updateSumireKeys()
    }

    private func endSpaceCursorMoveMode() {
        guard spaceCursorMoveModeActive else { return }
        spaceCursorMoveModeActive = false
        spaceCursorMoveRemainder = 0
        updateSumireKeys()
    }

    private func moveSpaceCursor(by horizontalDelta: CGFloat) {
        guard spaceCursorMoveModeActive, horizontalDelta.isFinite else { return }
        // A short trackpad stride gives finer caret placement than a key flick.
        // Cap a single event so an anomalous touch delta cannot jump far.
        let delta = min(192, max(-192, horizontalDelta))
        spaceCursorMoveRemainder += delta
        let strideCount = Int(spaceCursorMoveRemainder / spaceCursorMovePointsPerCharacter)
        guard strideCount != 0 else { return }
        spaceCursorMoveRemainder -= CGFloat(strideCount) * spaceCursorMovePointsPerCharacter
        let offset = strideCount > 0 ? 1 : -1
        for _ in 0..<abs(strideCount) { moveCompositionCursor(by: offset) }
    }

    private func cycleBunsetsuSplitPatternIfActive() -> Bool {
        guard var session = currentBunsetsuSession,
              session.cycleSplitPattern(by: 1) else { return false }
        bunsetsuSession = session
        renderBunsetsuSession()
        loadNextBunsetsuCandidates()
        return true
    }

    private func executeSpecialAction(_ action: SumireSpecialKeyAction, key: SumireSpecialKeyID = .paste,
                                      gesture: SumireSpecialKeyGesture = .tap, prepareInput: Bool = true) {
        if prepareInput { beforeInput?() }
        if let reason = action.unavailabilityReason(for: key, gesture: gesture, mode: sumireMode) {
            showDataNotice(reason); return
        }
        if action != .toggleKatakana { katakanaCycle.reset() }
        tapCycle.reset()
        switch action {
        case .doNothing: break
        case .deleteBackward: pressed("⌫")
        case .deleteUntilBoundary:
            if hasComposition {
                composition.invalidate(); containsRomaji = false
                refreshConversion()
            } else if let deleteUntilBoundary { deleteUntilBoundary() }
            else { showDataNotice("この入力先では区切りまでの削除を実行できません") }
        case .cursorLeft: moveCompositionCursor(by: -1)
        case .cursorRight: moveCompositionCursor(by: 1)
        case .paste:
            guard candidateBar.clipboardAccessAllowed else {
                showDataNotice("クリップボードを利用するにはキーボードのフルアクセスが必要です"); return
            }
            if let text = UIPasteboard.general.string, !text.isEmpty {
                appendLearningInput(text); refreshConversion()
            } else { showDataNotice("貼り付けできる文字がありません") }
        case .space:
            commitComposition(); insert?(" ")
        case .cycleBunsetsuSplitPattern: _ = cycleBunsetsuSplitPatternIfActive()
        case .cursorMoveMode: beginSpaceCursorMoveMode()
        case .convert:
            guard hasComposition else { return }
            if cycleBunsetsuCandidateIfActive() || startBunsetsuConversionIfNeeded() { return }
            composition.select()
            if !converted.isEmpty {
                selectedCandidate = ((selectedCandidate ?? -1) + 1) % converted.count
                updateMarkedText?(previewText(converted[selectedCandidate!]))
            }
        case .enter: pressed("改行")
        case .confirm: commitComposition()
        case .nextKeyboard: cycleKeyboard()
        case .changeInputMode: setSumireMode(sumireMode.next)
        case .switchKana: setSumireMode(.japanese)
        case .switchEnglish: setSumireMode(.english)
        case .switchNumber: setSumireMode(.number)
        case .toggleDakuten: pressed("゛")
        case .toggleKatakana:
            guard hasComposition else { return }
            let oldCursor = composition.cursor
            let text = katakanaCycle.next(composition.reading)
            composition.invalidate(); appendLearningInput(text)
            _ = composition.moveCursor(by: min(oldCursor, text.count) - text.count)
            containsRomaji = false; refreshConversion()
        case .openSymbols: showSymbolKeyboard()
        case .insertColon: pressed(":")
        case .insertHyphen: pressed("-")
        case .keyboardMenu:
            // The globe's UIKit menu handles this gesture without invoking a
            // second action or synthesizing private context-menu events.
            break
        case .deleteAfterCursorUntilBoundary, .undoDelete, .cursorUp, .cursorDown, .copy, .cut, .selectAll:
            // The shared availability table rejects these before any edit.
            break
        }
        updateSumireKeys()
    }
    private func setSumireMode(_ mode: TenKeyMode) {
        guard mode != sumireMode else { return }
        sumireMode = mode
        if mode == .english && settingsDefaults.bool(forKey: SumireModePreferences.englishQWERTYKey) {
            resetEnglishQWERTYState()
        }
        if hasComposition { composition.optionsChanged(); refreshConversion() }
        rebuild()
    }
    private func resetEnglishQWERTYState() {
        englishPage = 0
        shifted = false
        qwertyCapsLock = false
        qwertyLastShiftTap = 0
    }
    private func sumireAction(_ action: KeyboardLayout.Action) {
        beforeInput?()
        switch action {
        case .paste:
            // Read only following an explicit tap; iOS controls paste permission.
            if let text = UIPasteboard.general.string {
                tapCycle.reset()
                appendLearningInput(text)
                refreshConversion()
            }
        case .cursorLeft:
            moveCompositionCursor(by: -1)
        case .nextKeyboard: pressed("🌐")
        case .modifier:
            if hasComposition { pressed("゛") }
            else { showSymbolKeyboard() }
        case .delete: pressed("⌫")
        case .space: pressed("空白")
        case .enter: pressed("改行")
        case .text, .changeMode: break
        }
        updateSumireKeys()
    }
    private func addFlickRow(_ values: [String], palette: KeyboardPalette) {
        let row = UIStackView()
        let minimum = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimum.priority = .defaultLow
        minimum.isActive = true
        row.spacing = geometry.keySpacing
        row.distribution = .fillEqually
        for value in values {
            let appearance = keyAppearance(special: value == "゛")
            let key = FlickKey(type: .custom)
            key.values = value
            key.setTitle(String(value.prefix(1)), for: .normal)
            key.accessibilityLabel = String(value.prefix(1))
            key.accessibilityHint = "タップ・左・上・右・下: " + value
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.setTitleColor(palette.foreground, for: .normal)
            key.backgroundColor = palette.key
            key.layer.cornerRadius = geometry.keyCornerRadius
            key.onFlick = { [weak self] direction in self?.flick(value, direction: direction) }
            key.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
            row.addArrangedSubview(SizedKey(key, scale: appearance.keyScale))
        }
        stack.addArrangedSubview(row)
        if let first = keyRows.first { row.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true }
        keyRows.append(row)
    }
    private func flick(_ values: String, direction: FlickDirection) {
        beforeInput?()
        if values == "゛" { pressed("゛"); return }
        if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
        containsRomaji = false
        let choice = tapCycle.choose(values, direction: direction, generation: composition.generation,
                                     time: ProcessInfo.processInfo.systemUptime, enabled: tenKeyToggle)
        if choice.replacing { _ = composition.replaceLast(choice.text) }
        else { appendLearningInput(choice.text) }
        refreshConversion()
    }
    private func addRow(_ values: [String], palette: KeyboardPalette, special: Bool) {
        let row = UIStackView()
        let minimum = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimum.priority = .defaultLow
        minimum.isActive = true
        row.spacing = geometry.keySpacing
        row.distribution = .fillEqually
        for value in values {
            if value.isEmpty { row.addArrangedSubview(UIView()); continue }
            let appearance = keyAppearance(special: special || value == "゛" || value == "゛小")
            let button = RepeatingKey(type: .system)
            button.setTitle(value, for: .normal)
            button.accessibilityLabel = value == "⌫" ? "削除" : value
            button.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            button.setTitleColor(palette.foreground, for: .normal)
            button.backgroundColor = special ? palette.function : palette.key
            button.layer.cornerRadius = geometry.keyCornerRadius
            let icon: KeyboardIcon? = ["🌐": .globe, "⌫": .delete, "改行": .enter][value]
            if let icon {
                button.setTitle(nil, for: .normal)
                button.setImage(icon.image, for: .normal)
                button.tintColor = palette.foreground
            }
            if value == "🌐" { configureKeyboardSwitch(button) }
            else { button.addAction(UIAction { [weak self] _ in self?.pressed(value == "゛小" ? "゛" : value == "「」" ? "「" : value) }, for: .touchUpInside) }
            row.addArrangedSubview(SizedKey(button, scale: appearance.keyScale))
        }
        stack.addArrangedSubview(row)
        if let first = keyRows.first { row.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true }
        keyRows.append(row)
    }
    func invalidateComposition() {
        spaceConvertKanaToggleState = nil
        endSpaceCursorMoveMode()
        cancelLearning()
        customTapController?.cancel()
        closeSymbolKeyboard()
        katakanaCycle.reset()
        closeExpandedCandidates()
        clearBunsetsuSession()
        composition.invalidate()
        containsRomaji = false
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        bunsetsuActionHandled = false
        selectedCandidate = nil
        candidateBar.candidates = []
        candidateBar.isUpdating = false
        status.text = "Sumire · C++変換"
        englishComposition = false
        updateSumireKeys()
        converter.reset()
    }
    private func closeExpandedCandidates() {
        expandedCandidates?.removeFromSuperview()
        expandedCandidates = nil
        stack.accessibilityElementsHidden = symbolPanel != nil
    }

    func showTextMacroList(requiredMacroID: String? = nil) {
        beforeInput?()
        guard (!hasComposition || requiredMacroID != nil), expandedCandidates == nil else { return }
        let macros = AndroidTextMacroCandidatePolicy.ordered(in: personalLexicon.textMacros)
            .filter { $0.enabled && (requiredMacroID == nil || $0.id == requiredMacroID) }
        guard !macros.isEmpty else { return }
        let palette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark,
                                      saturation: saturation, brightness: brightness)
        let panel = KeyboardTextMacroPanel(macros: macros, palette: palette,
                                           canUseContext: textMacroContextAllowed,
                                           hasSelection: textMacroSelectionAvailable)
        panel.onClose = { [weak self] in self?.closeExpandedCandidates() }
        panel.onSelect = { [weak self] id, clipboard in
            guard let self else { return }
            self.closeExpandedCandidates()
            self.cancelLearning()
            self.executeTextMacro?(id, clipboard)
        }
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        stack.accessibilityElementsHidden = true
        expandedCandidates = panel
    }
    private func showExpandedCandidates() {
        guard !presentedCandidates.isEmpty, expandedCandidates == nil else { return }
        let palette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark, saturation: saturation, brightness: brightness)
        let panel = UIView()
        panel.accessibilityIdentifier = "candidate-expanded-panel"
        panel.backgroundColor = palette.background
        panel.accessibilityViewIsModal = true
        let close = UIButton(type: .system)
        close.setTitle("候補欄を閉じる", for: .normal)
        close.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        close.tintColor = palette.foreground
        close.addAction(UIAction { [weak self] _ in self?.closeExpandedCandidates() }, for: .touchUpInside)
        let list = CandidateBar()
        list.clipboardAccessAllowed = false
        list.useExpandedLayout()
        list.applyPalette(palette)
        list.setCandidates(presentedCandidates.map {
            CandidateBar.Presentation(text: $0.text, annotation: $0.textMacroID == nil ? $0.displayAnnotation : "定型マクロ")
        })
        list.selectedIndex = selectedCandidate
        list.onSelect = { [weak self] index in
            self?.closeExpandedCandidates()
            self?.chooseCandidate(index)
        }
        for view in [panel, close, list] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(panel); panel.addSubview(close); panel.addSubview(list)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.topAnchor.constraint(equalTo: panel.topAnchor), close.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            close.heightAnchor.constraint(equalToConstant: 44), close.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            list.topAnchor.constraint(equalTo: close.bottomAnchor), list.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: panel.leadingAnchor), list.trailingAnchor.constraint(equalTo: panel.trailingAnchor)
        ])
        stack.accessibilityElementsHidden = true
        expandedCandidates = panel
    }
    private func moveCompositionCursor(by offset: Int) {
        if var session = currentBunsetsuSession {
            if session.moveFocus(by: offset) {
                bunsetsuSession = session
                renderBunsetsuSession()
                loadNextBunsetsuCandidates()
            }
            return
        }
        if composition.moveCursor(by: offset) {
            tapCycle.reset()
            refreshConversion()
        } else if offset < 0 { moveCursorLeft?() } else { moveCursorRight?() }
    }
    private func markReading() {
        if let updateMarkedSelection {
            updateMarkedSelection(composition.reading, NSRange(location: composition.cursorUTF16, length: 0))
        } else { updateMarkedText?(composition.reading) }
    }
    /// Adopt a host caret in the unchanged reading, never in a converted
    /// preview surface or an externally modified marked range.
    func synchronizeCompositionSelection(markedText: String, selection: NSRange) -> Bool {
        let generation = composition.generation
        guard composition.synchronizeCursor(markedText: markedText, selection: selection) else { return false }
        tapCycle.reset()
        if composition.generation != generation { refreshConversion() }
        return true
    }
    private func refreshConversion() {
        spaceConvertKanaToggleState = nil
        if let remainder = learningRemainder, !remainder.utf16.elementsEqual(composition.reading.utf16) { cancelLearning() }
        clearBunsetsuSession()
        closeExpandedCandidates()
        if inputMode == .tenKey || inputMode == .sumire || inputMode == .kana { updateModeConversionLanguage() }
        selectedCandidate = nil
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        bunsetsuActionHandled = false
        let reading = composition.reading
        // Preserve the last accepted frame instead of submitting an empty list
        // between keystrokes. Pending candidates cannot be selected or expanded.
        candidateBar.isUpdating = !reading.isEmpty
        if reading.isEmpty { candidateBar.candidates = [] }
        updateSumireKeys()
        markReading()
        status.text = reading.isEmpty ? "Sumire · C++変換" : reading
        guard !reading.isEmpty else { englishComposition = false; converter.reset(); return }
        let generation = composition.generation
        let query = containsRomaji ? (romaji?.flush(reading) ?? reading) : reading
        requestConversion(query: query, generation: generation)
    }
    private func startBunsetsuConversion() {
        clearBunsetsuSession()
        if containsRomaji, let romaji {
            _ = composition.flushRomaji(using: romaji)
            containsRomaji = false
        }
        let reading = composition.reading
        guard !reading.isEmpty else { return }
        closeExpandedCandidates()
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        selectedCandidate = nil
        candidateBar.candidates = []
        candidateBar.isUpdating = true
        composition.optionsChanged()
        composition.select()
        markReading()
        status.text = reading + " · 文節を探索中"
        let generation = composition.generation
        converter.convert(reading, generation: generation, editStart: 0,
                          omission: omissionSearch, includeBunsetsu: true, bunsetsuSearch: true) { [weak self] response in
            guard let self else { return }
            self.beforeInput?()
            guard self.composition.accepts(generation) else { return }
            switch response {
            case .success(let result):
                guard result.generation == generation else { return }
                guard let snapshot = result.bunsetsuSnapshot else {
                    self.requestFollowingBunsetsu(reading, statusNote: " · 文節情報なし")
                    return
                }
                do {
                    self.bunsetsuSession = try BunsetsuConversionSession(
                        rawInput: reading, conversionInput: reading,
                        wholeDisplayText: result.candidates.first?.text ?? reading,
                        generation: generation, snapshot: snapshot,
                        orderedDisplayCandidates: result.orderedDisplayIdentities)
                    self.bunsetsuOwnerGeneration = generation
                    self.bunsetsuActionHandled = true
                    self.renderBunsetsuSession()
                    self.loadNextBunsetsuCandidates()
                } catch {
                    self.requestFollowingBunsetsu(reading, statusNote: " · 文節情報を通常変換に切替")
                }
            case .failure:
                // Fall back to the ordinary conversion path without changing the composing text.
                self.requestFollowingBunsetsu(reading, statusNote: " · 文節検索を通常変換に切替")
            }
        }
    }
    @discardableResult private func startBunsetsuConversionIfNeeded() -> Bool {
        guard bunsetsuSeparation, !englishComposition, hasComposition,
              !bunsetsuActionHandled,
              composition.cursorUTF16 == composition.reading.utf16.count else { return false }
        startBunsetsuConversion()
        return true
    }
    private var currentBunsetsuSession: BunsetsuConversionSession? {
        guard let session = bunsetsuSession, let owner = bunsetsuOwnerGeneration,
              composition.accepts(owner),
              composition.reading.utf16.elementsEqual(session.rawInput.utf16) else { return nil }
        return session
    }

    private func clearBunsetsuSession() {
        bunsetsuSession = nil
        bunsetsuOwnerGeneration = nil
        bunsetsuCandidateItems = []
    }

    private func renderBunsetsuSession() {
        guard let session = currentBunsetsuSession else { return }
        bunsetsuCandidateItems = session.focusedCandidateBarItems
        candidateBar.setCandidates(bunsetsuCandidateItems.map { CandidateBar.Presentation(text: $0.text) })
        candidateBar.selectedIndex = session.focusedSegment?.selectedIndex
        candidateBar.isUpdating = session.focusedSegment?.isLoadingCandidates == true
        updateMarkedText?(session.displayText)
        status.text = "文節 \(session.focusedSegmentIndex + 1)/\(session.segments.count) · " + session.focusedSegment!.reading
    }

    private func loadNextBunsetsuCandidates() {
        guard var session = currentBunsetsuSession,
              let index = session.candidatePreparationSegmentIndices.first(where: {
                  !session.segments[$0].candidatesLoaded && !session.segments[$0].isLoadingCandidates
              }) else { return }
        bunsetsuRequestGeneration = max(bunsetsuRequestGeneration, session.generation) &+ 1
        guard let token = session.beginLoadingCandidates(forSegmentAt: index,
                    conversionRequestGeneration: bunsetsuRequestGeneration) else { return }
        let owner = bunsetsuOwnerGeneration
        bunsetsuSession = session
        renderBunsetsuSession()
        converter.convert(token.segmentReading, generation: token.conversionRequestGeneration, editStart: 0,
                          omission: omissionSearch) { [weak self] response in
            guard let self else { return }
            self.beforeInput?()
            guard var current = self.currentBunsetsuSession,
                  self.bunsetsuOwnerGeneration == owner,
                  current.sessionID == token.sessionID else { return }
            switch response {
            case let .success(result):
                // A segment row must consume the complete segment: a normal
                // prefix candidate cannot replace the segment's unread suffix.
                let records = result.candidates.filter {
                    $0.range.location == 0 && $0.range.length == token.segmentReading.utf16.count
                }.map {
                    BunsetsuSessionCandidate(text: $0.text,
                        reference: .conversionResult(generation: result.generation, candidateID: $0.id),
                        score: $0.score, leftID: $0.leftID, rightID: $0.rightID,
                        matchedReadingUTF16Length: $0.range.length)
                }
                guard current.installCandidates(records, responseReading: token.segmentReading,
                    responseGeneration: result.generation, for: token) else { return }
            case .failure:
                // Empty alternatives retain the projected/reading fallback.
                guard current.installCandidates([], responseReading: token.segmentReading,
                    responseGeneration: token.conversionRequestGeneration, for: token) else { return }
            }
            self.bunsetsuSession = current
            self.renderBunsetsuSession()
            self.loadNextBunsetsuCandidates()
        }
    }

    private func cycleBunsetsuCandidateIfActive() -> Bool {
        guard var session = currentBunsetsuSession else { return false }
        if session.cycleFocusedCandidate(by: 1) {
            bunsetsuSession = session
            renderBunsetsuSession()
        }
        loadNextBunsetsuCandidates()
        return true
    }

    private func commitBunsetsuPlan(_ plan: BunsetsuFocusedPrefixCommitPlan) {
        guard currentBunsetsuSession != nil,
              plan.learningReading.utf16.elementsEqual(composition.reading.utf16) else { return }
        converter.commitLearningPlan(plan, learnFirst: learnFirstCandidate) { [weak self] message in
            if self?.hasComposition == false { self?.showDataNotice(message) }
        }
        learningRemainder = plan.nextComposingInput.isEmpty ? nil : plan.nextComposingInput
        // Session plans validate UTF-16/scalar boundaries, including boundaries
        // inside a combining grapheme. Do not use Character-only commitPrefix,
        // or reset the composition generation while adopting the remainder.
        _ = composition.commit()
        composition.append(plan.nextComposingInput)
        clearBunsetsuSession()
        containsRomaji = false
        converted = []; presentedCandidates = []; resultGeneration = nil; selectedCandidate = nil
        // Earlier segment references belong to earlier native results. Never
        // pass those IDs to the native latest-result-only commit API. Fragment
        // learning persistence is connected separately from this state route.
        converter.reset()
        if let commitMarkedText { commitMarkedText(plan.committedText) } else { insert?(plan.committedText) }
        refreshConversion()
    }

    private func requestFollowingBunsetsu(_ query: String, statusNote: String) {
        composition.optionsChanged()
        composition.select()
        bunsetsuActionHandled = true
        requestConversion(query: query, generation: composition.generation, statusNote: statusNote)
    }
    private func requestConversion(query: String, generation: UInt64, statusNote: String = "") {
        let reading = composition.reading
        converter.convert(query, generation: generation, editStart: 0,
                          omission: englishComposition ? false : omissionSearch,
                          english: englishComposition) { [weak self] response in
            guard let self else { return }
            self.beforeInput?()
            guard self.composition.accepts(generation) else { return }
            switch response {
            case .success(let result):
                guard result.generation == generation else { return }
                let macros = AndroidTextMacroCandidatePolicy.candidates(
                    in: self.personalLexicon.textMacros,
                    reading: query,
                    contextAllowed: self.textMacroContextAllowed
                ).map { macro in
                    ConversionCandidate(
                        id: 0, text: macro.name, score: Int64.min, range: NSRange(location: 0, length: query.utf16.count),
                        dictionaries: ["text_macro"], correctedReading: macro.reading,
                        textMacroID: macro.id
                    )
                }
                let candidates = result.candidates + macros
                self.converted = result.candidates
                self.presentedCandidates = candidates
                self.resultGeneration = generation
                self.candidateBar.setCandidates(candidates.map { CandidateBar.Presentation(text: $0.text, annotation: $0.textMacroID == nil ? $0.displayAnnotation : "定型マクロ") })
                self.candidateBar.isUpdating = false
                let shouldApplyLivePreview = self.liveConversion && !self.englishComposition
                    && self.physicalFunctionKeyPreviewSuppressionGeneration != generation
                    && self.composition.cursorUTF16 == self.composition.reading.utf16.count
                if let spaceToggle = self.spaceConvertKanaToggleState, spaceToggle.matches(self.composition) {
                    self.renderSpaceConvertKanaToggle(spaceToggle)
                } else if shouldApplyLivePreview || self.composition.phase == .selecting {
                    self.selectedCandidate = result.candidates.isEmpty ? nil : 0
                    if let first = result.candidates.first { self.updateMarkedText?(self.previewText(first)) }
                }
                self.status.text = reading + (result.complete ? "" : " · 探索上限") + (result.warning.map { " · " + $0 } ?? "") + statusNote
            case .failure(let error):
                // Keep every reading character; Return can still commit the reading.
                self.converted = []
                self.presentedCandidates = []
                self.resultGeneration = nil
                self.selectedCandidate = nil
                self.candidateBar.candidates = []
                self.candidateBar.isUpdating = false
                self.status.text = reading + " · " + error.localizedDescription + statusNote
            }
        }
    }
    private func previewText(_ candidate: ConversionCandidate) -> String {
        var preview = composition
        guard candidate.range.location == 0,
              preview.commitPrefix(candidate.text, readingUTF16Length: candidate.range.length) != nil else {
            return composition.reading
        }
        return candidate.text + preview.reading
    }
    private func chooseCandidate(_ index: Int) {
        spaceConvertKanaToggleState = nil
        beforeInput?()
        if var session = currentBunsetsuSession {
            guard !candidateBar.isUpdating, bunsetsuCandidateItems.indices.contains(index) else { return }
            let selection = session.selectFocusedCandidateBarItem(bunsetsuCandidateItems[index])
            bunsetsuSession = session
            if case let .segmentCandidateSelected(plan?) = selection { commitBunsetsuPlan(plan) }
            return
        }
        guard let generation = resultGeneration, composition.accepts(generation),
              presentedCandidates.indices.contains(index) else { return }
        if let macroID = presentedCandidates[index].textMacroID {
            selectedCandidate = nil
            cancelLearning()
            executeTextMacro?(macroID, nil)
            return
        }
        guard converted.indices.contains(index) else { return }
        selectedCandidate = index
        commitComposition()
    }
    private func commitRawAtCursorAndSpace() {
        cancelLearning()
        clearBunsetsuSession()
        guard let commitRawTextAndSpace else {
            showDataNotice("この入力先では読みの確定と空白挿入を実行できません")
            return
        }
        let parts = composition.commitRawAtCursorAndSpace()
        // This action commits raw text, never the selected surface or a learned
        // candidate. Clearing the generation also rejects in-flight results.
        containsRomaji = false
        englishComposition = false
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        selectedCandidate = nil
        candidateBar.isUpdating = false
        candidateBar.candidates = []
        converter.reset()
        commitRawTextAndSpace(parts.left, parts.tail)
        status.text = "Sumire · C++変換"
        updateSumireKeys()
    }

    private func commitComposition() {
        if var session = currentBunsetsuSession {
            _ = session.moveFocus(by: session.segments.count)
            guard let plan = session.focusedPrefixCommitPlan() else { return }
            commitBunsetsuPlan(plan)
            return
        }
        if let spaceToggle = spaceConvertKanaToggleState,
           spaceToggle.matches(composition), composition.phase != .selecting {
            spaceConvertKanaToggleState = nil
            cancelLearning()
            guard let text = composition.commit(spaceToggle.displayText) else { return }
            containsRomaji = false
            if let commitMarkedText { commitMarkedText(text) } else { insert?(text) }
            converted = []
            presentedCandidates = []
            resultGeneration = nil
            selectedCandidate = nil
            candidateBar.isUpdating = false
            candidateBar.candidates = []
            status.text = "Sumire · C++変換"
            englishComposition = false
            updateSumireKeys()
            converter.reset()
            return
        }
        if selectedCandidate == nil, containsRomaji, let romaji {
            _ = composition.flushRomaji(using: romaji)
        }
        let originalInput = composition.reading
        var learningSelection: (UInt64, ConversionCandidate, Int)?
        var candidate: ConversionCandidate?
        if let generation = resultGeneration, composition.accepts(generation),
           let index = selectedCandidate, converted.indices.contains(index) {
            candidate = converted[index]
            learningSelection = (generation, converted[index], index)
        }
        let text: String?
        if let candidate {
            guard candidate.range.location == 0 else { return }
            text = composition.commitPrefix(candidate.text, readingUTF16Length: candidate.range.length)
        } else { text = composition.commit() }
        guard let text else { return }
        if let (generation, selected, rank) = learningSelection {
            converter.commitSelection(generation: generation, candidate: selected, rank: rank,
                input: originalInput, remaining: composition.reading, learnFirst: learnFirstCandidate) { [weak self] message in
                if self?.hasComposition == false { self?.showDataNotice(message) }
            }
            learningRemainder = composition.reading.isEmpty ? nil : composition.reading
        } else { cancelLearning() }
        containsRomaji = false
        if let commitMarkedText { commitMarkedText(text) } else { insert?(text) }
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        selectedCandidate = nil
        candidateBar.isUpdating = !composition.reading.isEmpty
        if composition.reading.isEmpty { candidateBar.candidates = [] }
        status.text = "Sumire · C++変換"
        englishComposition = false
        updateSumireKeys()
        converter.reset()
        if !composition.reading.isEmpty { refreshConversion() }
    }
    private var keyboardChoices: [(title: String, mode: InputMode, customID: String?)] {
        let builtins: [(KeyboardKind, InputMode, String)] = [
            (.tenKey, .tenKey, "テンキー"), (.english, .english, "ABC"), (.gojuon, .kana, "50音"),
            (.sumire, .sumire, "Sumire"), (.romaji, .romaji, "ローマ字")]
        let choices: [(id: String, title: String, mode: InputMode, customID: String?)] =
            builtins.map { ("builtin:" + $0.0.rawValue, $0.2, $0.1, nil) } +
            customLayouts.map { ("custom:" + $0.id, $0.name, .custom, Optional($0.id)) }
        let selected = KeyboardSelection.load(defaults: settingsDefaults, available: choices.map(\.id))
        return selected.ids.compactMap { id in
            choices.first { $0.id == id }.map { ($0.title, $0.mode, $0.customID) }
        }
    }
    private func selectionID(mode: InputMode, customID: String?) -> String {
        switch mode {
        case .kana: return "builtin:gojuon"
        case .tenKey: return "builtin:tenKey"
        case .sumire: return "builtin:sumire"
        case .romaji: return "builtin:romaji"
        case .english: return "builtin:english"
        case .custom: return "custom:" + (customID ?? "")
        }
    }
    private func rememberKeyboard() {
        guard !isAppearancePreview else { return }
        writableSettings.set(selectionID(mode: inputMode, customID: activeCustomID), forKey: "keyboard.lastUsed")
        onSettingsWritten?(["keyboard.lastUsed"])
    }
    private func selectKeyboard(_ mode: InputMode, customID: String?) {
        beforeInput?(); tapCycle.reset()
        let previousEnglishComposition = englishComposition
        customShift = .off
        customPresentationOwner = nil
        if mode == .custom, let customID { customModeOverrides.removeValue(forKey: customID) }
        inputMode = mode
        if let customID { activeCustomID = customID }
        rememberKeyboard()
        updateModeConversionLanguage()
        if hasComposition && englishComposition != previousEnglishComposition {
            composition.optionsChanged()
            refreshConversion()
        }
        shifted = false
        qwertyCapsLock = false; qwertyLastShiftTap = 0
        rebuild()
    }
    private func configureKeyboardSwitch(_ key: UIButton, cycleOnTap: Bool = true) {
        key.accessibilityIdentifier = "keyboard-switch"
        key.accessibilityLabel = "キーボード切替"
        key.accessibilityHint = "タップで次の配列、長押しで配列を選択"
        key.menu = UIMenu(title: "キーボード", children: keyboardChoices.map { choice in
            UIAction(title: choice.title, state: inputMode == choice.mode &&
                     (choice.mode != .custom || activeCustomID == choice.customID) ? .on : .off) { [weak self] _ in
                self?.selectKeyboard(choice.mode, customID: choice.customID)
            }
        } + [UIAction(title: "次のシステムキーボード") { [weak self] _ in
            self?.commitComposition(); self?.nextKeyboard?()
        }])
        key.showsMenuAsPrimaryAction = false
        guard cycleOnTap else { return }
        key.addAction(UIAction { [weak self] _ in
            self?.cycleKeyboard()
        }, for: .touchUpInside)
    }
    private func cycleKeyboard() {
        let choices = keyboardChoices
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex { $0.mode == inputMode &&
            ($0.mode != .custom || $0.customID == activeCustomID) } ?? -1
        let next = choices[(current + 1) % choices.count]
        selectKeyboard(next.mode, customID: next.customID)
    }

    var physicalKeyboardShortcutContext: PhysicalKeyboardShortcutContext {
        guard hasComposition else { return .any }
        return composition.phase == .selecting ? .conversion : .composition
    }

    /// Executes only actions this keyboard surface can perform without reading host
    /// text or bypassing the keyboard's existing Full Access clipboard gate. Returning
    /// false leaves the press in UIKit's responder chain for host-handled edit commands.
    @discardableResult
    func performPhysicalKeyboardShortcut(_ action: PhysicalKeyboardShortcutAction) -> Bool {
        switch action {
        case .convertToHiragana, .convertToFullKatakana, .convertToHalfWidth,
             .convertToFullAlphanumeric, .convertToHalfAlphanumeric:
            break
        default:
            physicalFunctionKeyConversionSource.reset()
        }
        switch action {
        case .copy, .cut, .selectAll:
            return false
        case .paste:
            guard candidateBar.clipboardAccessAllowed else { return false }
            beforeInput?()
            sumireAction(.paste)
            return true
        case .switchToJapanese:
            beforeInput?()
            if hasComposition, physicalKeyboardMode == .japanese {
                pressed("空白")
            } else {
                if hasComposition { commitComposition() }
                setPhysicalKeyboardMode(.japanese)
            }
            return true
        case .switchToEnglish:
            beforeInput?()
            if hasComposition { commitComposition() }
            setPhysicalKeyboardMode(.english)
            return true
        case .cycleInputMode:
            beforeInput?()
            let next = physicalKeyboardMode.next
            if hasComposition { commitComposition() }
            setPhysicalKeyboardMode(next)
            return true
        case .convert:
            guard hasComposition else { return false }
            pressed("空白")
            return true
        case .commit:
            guard hasComposition else { return false }
            beforeInput?()
            commitComposition()
            return true
        case .cancel:
            guard hasComposition else { return false }
            beforeInput?()
            if composition.phase == .selecting { cancelPhysicalConversion() }
            return true
        case .convertNext:
            guard composition.phase == .selecting else { return false }
            beforeInput?()
            return movePhysicalConversionCandidate(by: 1)
        case .convertPrevious:
            guard composition.phase == .selecting else { return false }
            beforeInput?()
            return movePhysicalConversionCandidate(by: -1)
        case .convertToHiragana:
            return transformPhysicalComposition(.hiragana)
        case .convertToFullKatakana:
            return transformPhysicalComposition(.fullKatakana)
        case .convertToHalfWidth:
            return transformPhysicalComposition(.halfWidth)
        case .convertToFullAlphanumeric, .convertToHalfAlphanumeric,
             .segmentFocusLeft, .segmentFocusRight,
             .segmentWidthShrink, .segmentWidthExpand:
            switch action {
            case .convertToFullAlphanumeric:
                return transformPhysicalComposition(.fullAlphanumeric)
            case .convertToHalfAlphanumeric:
                return transformPhysicalComposition(.halfAlphanumeric)
            default:
                // Bunsetsu segment navigation remains unavailable until the iOS
                // conversion surface has a matching segmented composition model.
                return false
            }
        }
    }

    private var physicalKeyboardMode: TenKeyMode {
        switch inputMode {
        case .sumire: return sumireMode
        case .tenKey: return tenKeyMode
        case .kana: return gojuonMode
        case .custom:
            if customEnglishVisible { return .english }
            if customNumberVisible { return .number }
            return .japanese
        case .romaji: return romajiLatin ? .english : .japanese
        case .english: return .english
        }
    }

    private func setPhysicalKeyboardMode(_ mode: TenKeyMode) {
        switch inputMode {
        case .sumire:
            setSumireMode(mode)
        case .tenKey:
            beforeInput?(); tapCycle.reset(); tenKeyMode = mode; rebuild()
        case .kana:
            beforeInput?(); tapCycle.reset(); gojuonMode = mode; rebuild()
        case .custom:
            switch mode {
            case .japanese: setCustomEnglishPresentation(false)
            case .english: setCustomEnglishPresentation(true)
            case .number: showCustomNumberPresentation()
            }
        case .romaji:
            if mode == .number {
                tenKeyMode = .number
                selectKeyboard(.tenKey, customID: nil)
            } else {
                beforeInput?(); tapCycle.reset(); romajiLatin = mode == .english; rebuild()
            }
        case .english:
            if mode != .english {
                if mode == .number {
                    tenKeyMode = .number
                    selectKeyboard(.tenKey, customID: nil)
                } else {
                    gojuonMode = .japanese
                    selectKeyboard(.kana, customID: nil)
                }
            }
        }
    }

    private func movePhysicalConversionCandidate(by offset: Int) -> Bool {
        guard !converted.isEmpty else { return false }
        let current = selectedCandidate ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + converted.count) % converted.count
        composition.select()
        selectedCandidate = next
        updateMarkedText?(previewText(converted[next]))
        return true
    }

    private func cancelPhysicalConversion() {
        cancelLearning()
        guard hasComposition else { return }
        composition.optionsChanged() // Invalidates pending results and returns to editing.
        containsRomaji = false
        converted = []
        presentedCandidates = []
        resultGeneration = nil
        selectedCandidate = nil
        bunsetsuActionHandled = false
        candidateBar.candidates = []
        candidateBar.isUpdating = false
        converter.reset()
        markReading()
        status.text = "Sumire · C++変換"
    }

    private enum PhysicalCompositionTransform {
        case hiragana, fullKatakana, halfWidth, fullAlphanumeric, halfAlphanumeric
    }

    private func transformPhysicalComposition(_ transform: PhysicalCompositionTransform) -> Bool {
        guard hasComposition else {
            physicalFunctionKeyConversionSource.reset()
            // Android consumes F6–F10 even when there is no active reading;
            // there is no composition to mutate, but the function key must
            // not fall through and trigger a host/system command.
            return true
        }
        beforeInput?()
        if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
        containsRomaji = false
        let currentPrefix = String(composition.reading.prefix(composition.cursor))
        let source = physicalFunctionKeyConversionSource.source(
            for: currentPrefix, generation: composition.generation)
        let scriptSource = PhysicalKeyboardJapaneseScriptConversion.source(source, using: romaji)
        let output: String
        switch transform {
        case .hiragana:
            output = scriptSource.applyingTransform(.hiraganaToKatakana, reverse: true) ?? scriptSource
        case .fullKatakana:
            output = scriptSource.applyingTransform(.hiraganaToKatakana, reverse: false) ?? scriptSource
        case .halfWidth:
            let katakana = scriptSource.applyingTransform(.hiraganaToKatakana, reverse: false) ?? scriptSource
            output = katakana.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? katakana
        case .fullAlphanumeric:
            output = PhysicalKeyboardAlphabeticConversion.convert(source, to: .full, using: romaji)
        case .halfAlphanumeric:
            output = PhysicalKeyboardAlphabeticConversion.convert(source, to: .half, using: romaji)
        }
        composition.transformPrefix { _ in output }
        physicalFunctionKeyPreviewSuppressionGeneration = composition.generation
        physicalFunctionKeyConversionSource.record(output: output, generation: composition.generation)
        refreshConversion()
        return true
    }

    private func pressed(_ value: String) {
        physicalFunctionKeyConversionSource.reset()
        customTapController?.interrupt()
        beforeInput?()
        katakanaCycle.reset()
        tapCycle.reset()
        switch value {
        case "🌐":
            commitComposition()
            nextKeyboard?()
        case "カスタム":
            inputMode = .custom; rememberKeyboard(); rebuild()
        case "Sumire", "テンキー", "50音":
            inputMode = value == "Sumire" ? .sumire : value == "テンキー" ? .tenKey : .kana
            rememberKeyboard(); rebuild()
        case "→":
            break
        case "゛":
            if let last = composition.characterBeforeCursor, let modified = KanaInput.modified(last) {
                _ = composition.replaceLast(String(modified))
                refreshConversion()
            }
        case "かな", "ABC", "ローマ字":
            inputMode = value == "かな" ? .kana : value == "ABC" ? .english : .romaji
            rememberKeyboard()
            shifted = false
            rebuild()
        case "⇧":
            let now = ProcessInfo.processInfo.systemUptime
            if now - qwertyLastShiftTap < 0.3 {
                qwertyCapsLock = true; shifted = true; qwertyLastShiftTap = 0
            } else {
                if qwertyCapsLock { qwertyCapsLock = false; shifted = false }
                else { shifted.toggle() }
                qwertyLastShiftTap = now
            }
            updateQwertyCase()
        case "⌫":
            cancelLearning()
            if composition.deleteBackward() { refreshConversion() } else { delete?() }
        case "空白":
            if englishComposition { commitComposition(); insert?(" "); return }
            if composition.reading.isEmpty { insert?(" ") }
            else {
                if cycleBunsetsuCandidateIfActive() || startBunsetsuConversionIfNeeded() { return }
                composition.select()
                if !converted.isEmpty {
                    selectedCandidate = ((selectedCandidate ?? -1) + 1) % converted.count
                    updateMarkedText?(previewText(converted[selectedCandidate!]))
                }
            }
        case "改行":
            if englishComposition { commitComposition(); insert?("\n"); consumeQwertyShift(); return }
            if composition.reading.isEmpty { insert?("\n") } else { commitComposition() }
            consumeQwertyShift()
        default:
            defer { consumeQwertyShift() }
            if displayedInputMode == .english { insertEnglish(value) }
            else if inputMode == .romaji && romajiLatin { commitComposition(); insert?(value) }
            else if inputMode == .romaji, let romaji {
                containsRomaji = true
                appendLearningRomaji(value, using: romaji)
                refreshConversion()
            } else {
                if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
                containsRomaji = false
                appendLearningInput(value)
                refreshConversion()
            }
        }
    }
    private func updateModeConversionLanguage() {
        let englishMode = displayedInputMode == .english
            || (inputMode == .tenKey && tenKeyMode == .english)
            || (inputMode == .sumire && sumireMode == .english)
            || (inputMode == .kana && gojuonMode == .english)
        // Keep mixed kana/Latin compositions in the Japanese lattice. Mode
        // changes must not discard their existing reading.
        englishComposition = englishMode && !composition.reading.isEmpty
            && composition.reading.unicodeScalars.allSatisfy { $0.isASCII }
    }
    private func insertEnglish(_ text: String) {
        let isWord = !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || $0 == "'"
        }
        guard isWord else { commitComposition(); insert?(text); return }
        if !englishComposition && !composition.reading.isEmpty { commitComposition() }
        englishComposition = true
        containsRomaji = false
        appendLearningInput(text)
        refreshConversion()
    }
    private func consumeQwertyShift() {
        guard displayedInputMode == .english || inputMode == .romaji else { return }
        qwertyLastShiftTap = 0
        if shifted && !qwertyCapsLock { shifted = false; updateQwertyCase() }
    }
}

/// Platform runtime for the settings policy above. The short PCM click is
/// generated in memory, so the extension needs no extra resource or shared
/// container access. AVAudioSession's ambient category follows the iOS silent
/// switch and mixes with audio from the host app.
@MainActor
private final class KeyboardKeyFeedbackRuntime {
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private var players: [String: AVAudioPlayer] = [:]
    private var didConfigureAudioSession = false

    func dispatch(_ moment: KeyFeedbackMoment, kind: KeyFeedbackKeyKind,
                  settings: KeyFeedbackSettings, isKeyboardLayoutEditing: Bool) {
        if settings.shouldVibrate(at: moment, isKeyboardLayoutEditing: isKeyboardLayoutEditing) {
            haptic.impactOccurred(intensity: 0.45)
            haptic.prepare()
        }

        // iOS exposes no public silent-switch query. The ambient category below
        // suppresses playback when silent mode is active, matching Android's
        // normal-ringer-only policy without private APIs.
        guard settings.shouldPlaySound(
            at: moment,
            isRingerModeNormal: true,
            isKeyboardLayoutEditing: isKeyboardLayoutEditing
        ) else { return }
        guard let volume = settings.soundVolumeMultiplier else {
            UIDevice.current.playInputClick()
            return
        }
        play(kind.soundType, volume: volume)
    }

    private func play(_ type: KeyFeedbackSoundType, volume: Double) {
        let session = AVAudioSession.sharedInstance()
        if !didConfigureAudioSession {
            // `.ambient` already mixes with other app audio and respects the
            // Ring/Silent switch; `.mixWithOthers` is only explicitly valid
            // for other playback categories.
            guard (try? session.setCategory(.ambient)) != nil else { return }
            didConfigureAudioSession = true
        }
        guard let player = audioPlayer(for: type) else { return }
        // Zero delegates to the system output volume. Applying outputVolume
        // here as well would multiply it twice (once per player and once by
        // the audio route).
        player.volume = Float(min(1, max(0, volume)))
        player.currentTime = 0
        player.play()
    }

    private func audioPlayer(for type: KeyFeedbackSoundType) -> AVAudioPlayer? {
        if let player = players[type.rawValue] { return player }
        guard let player = try? AVAudioPlayer(data: makeClickWave(for: type)) else { return nil }
        player.prepareToPlay()
        players[type.rawValue] = player
        return player
    }

    private func makeClickWave(for type: KeyFeedbackSoundType) -> Data {
        let sampleRate: UInt32 = 22_050
        let frameCount = Int(sampleRate / 50) // 20 ms
        let dataLength = UInt32(frameCount * MemoryLayout<Int16>.size)
        let frequency: Double
        switch type {
        case .standard: frequency = 1_900
        case .delete: frequency = 1_250
        case .enter: frequency = 2_300
        }

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLE(36 + dataLength, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data) // PCM
        appendLE(UInt16(1), to: &data) // mono
        appendLE(sampleRate, to: &data)
        appendLE(sampleRate * 2, to: &data)
        appendLE(UInt16(2), to: &data) // block alignment
        appendLE(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLE(dataLength, to: &data)

        var noiseState: UInt32 = 0x51A7
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            let noise = Double(noiseState >> 16) / 32_767.5 - 1
            let tone = sin(2 * .pi * frequency * time) * 0.55
                + sin(2 * .pi * frequency * 2.4 * time) * 0.15
            let transient = noise * exp(-time * 900) * 0.22
            let sample = min(1, max(-1, (tone * exp(-time * 165) + transient) * 0.7))
            appendLE(UInt16(bitPattern: Int16(sample * Double(Int16.max))), to: &data)
        }
        return data
    }

    private func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00ff))
        data.append(UInt8((value >> 8) & 0x00ff))
    }

    private func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000ff))
        data.append(UInt8((value >> 8) & 0x000000ff))
        data.append(UInt8((value >> 16) & 0x000000ff))
        data.append(UInt8((value >> 24) & 0x000000ff))
    }
}
