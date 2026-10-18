import UIKit
import SumireCore

/// Shared native surface used in the app's diagnostic harness and extension.
/// Reading and selection survive layout changes; conversion runs off the main thread.
final class KeyboardSurface: UIInputView {
    var insert: ((String) -> Void)?
    var delete: (() -> Void)?
    var deleteUntilBoundary: (() -> Void)?
    var nextKeyboard: (() -> Void)?
    var moveCursorRight: (() -> Void)?
    var moveCursorLeft: (() -> Void)?
    var beforeInput: (() -> Void)?
    var updateMarkedText: ((String) -> Void)?
    var updateMarkedSelection: ((String, NSRange) -> Void)?
    var commitMarkedText: ((String) -> Void)?
    var liveConversion = false {
        didSet {
            guard oldValue != liveConversion else { return }
            beforeInput?()
            guard hasComposition else { return }
            if liveConversion && !englishComposition && composition.cursorUTF16 == composition.reading.utf16.count, let first = converted.first {
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
    var onHeightChange: ((CGFloat) -> Void)?
    private var sizeOrientation = KeyboardOrientation.portrait
    private var sizeValue = KeyboardSize.standard(.portrait)
    private var dragSize = KeyboardSize.standard(.portrait)
    private var loadedSizing = false
    private var isAppearancePreview = false
    private var resizeOverlay: KeyboardResizeOverlay?
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    var requestedHeight: CGFloat { preferredHeight.constant }
    func reloadSizing() {
        sizeValue = KeyboardSizingStore(defaults: settingsDefaults).load(sizeOrientation)
        loadedSizing = true
        applySizing()
    }
    private func applySizing() {
        guard preferredHeight != nil else { return }
        let availableHeight = window?.bounds.height ?? 1000
        let rows = CGFloat(min(3, max(1, candidateRowCount))) * 44
        let height = min(sizeValue.height + rows + safeAreaInsets.bottom, max(210, availableHeight * 0.72))
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
        do { try KeyboardSizingStore(defaults: settingsDefaults).save(sizeValue, for: sizeOrientation) }
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
        switch inputMode {
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
    private var learningURL: URL?
    var learnFirstCandidate = false
    func reloadLearningResults() {
        if hasComposition { composition.optionsChanged(); refreshConversion() }
    }
    func configureLearning(url: URL?) {
        guard learningURL != url else { return }
        learningURL = url
        converter.setLearning(url: url)
        if hasComposition { composition.optionsChanged(); refreshConversion() }
    }
    private var composition = CompositionState()
    private var converted: [ConversionCandidate] = []
    private var resultGeneration: UInt64?
    private var selectedCandidate: Int? { didSet { candidateBar.selectedIndex = selectedCandidate } }
    var hasComposition: Bool { !composition.reading.isEmpty }

    var hue: CGFloat = 0.73 { didSet { if hue != oldValue { rebuild() } } }
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
    private var customLayouts: [ImportedCustomLayout] = []
    private var activeCustomID: String?
    private var storedCustomID: String?
    func reloadCustomLayouts() {
        do {
            let library = try CustomKeyboardLibrary.load(defaults: settingsDefaults)
            let layouts = try library.layouts()
            guard layouts != customLayouts || library.activeID != storedCustomID else { return }
            customLayouts = layouts
            storedCustomID = library.activeID
            activeCustomID = library.activeID ?? layouts.first?.id
            rebuild()
        } catch { showDataNotice(error.localizedDescription) }
    }
    private var romaji = try? RomajiConverter.standard()
    func reloadRomaji() {
        do { romaji = try RomajiLibrary.load(defaults: settingsDefaults).converter() }
        catch { showDataNotice("ローマ字設定: " + error.localizedDescription) }
    }
    private var containsRomaji = false
    private var shifted = false
    private var qwertyCapsLock = false
    private var qwertyLastShiftTap: TimeInterval = 0
    private var tapCycle = KanaTapCycle()
    var tenKeyToggle = true
    private let geometry = KeyboardGeometry()
    private var keyRows: [UIStackView] = []
    private let stack = UIStackView()
    private let status = UILabel()
    private var expandedCandidates: UIView?


    init(frame: CGRect = .zero) {
        super.init(frame: frame, inputViewStyle: .keyboard)
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
        candidateBar.onClipboardNotice = { [weak self] in self?.showDataNotice($0) }
        candidateBar.onResize = { [weak self] in self?.beginResize() }
        candidateBar.onExpand = { [weak self] in self?.showExpandedCandidates() }
        candidateBar.onSelect = { [weak self] index in self?.chooseCandidate(index) }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func purgeConversionCache() { converter.purgeCache() }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight.constant)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: preferredHeight.constant)
    }
    private func rebuild() {
        closeExpandedCandidates()
        appearance = .load(keyboardKind, defaults: settingsDefaults)
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        keyRows = []
        let palette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark)
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
            let appearance = self.keyAppearance(special: definition.action != .text)
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
                    } else if definition.action == .changeMode { self.showDataNotice("この操作は移植中です") }
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
            else { composition.append(choice.text) }
        } else { tapCycle.reset(); composition.append(outputs[direction.rawValue]) }
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
            let special = side || definition.action == .modifier
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
        composition.append(text); refreshConversion()
        if gojuonMode == .english && direction == .tap && gojuonShift {
            gojuonShift = false; rebuild()
        }
    }
    private func addQwertyGrid(palette: KeyboardPalette) {
        let japanese = inputMode == .romaji
        let page = japanese ? romajiPage : englishPage
        let pageColumn = japanese ? 1 : 0
        let characters: [String]
        switch page {
        case 1: characters = japanese ? ["1234567890", "-/:@()「」￥&", "。、?!'"] : ["1234567890", "-/:;()¥&@\"", ".,?!'"]
        case 2: characters = japanese ? ["[]{}#%^*+=", "_/;|<>\"'$€", ".,?!・"] : ["[]{}#%^*+=", "_/\\~<>$€£·", ".,?!'"]
        default: characters = shifted ? ["QWERTYUIOP", japanese ? "ASDFGHJKLー" : "ASDFGHJKL", "ZXCVBNM"] : ["qwertyuiop", japanese ? "asdfghjklー" : "asdfghjkl", "zxcvbnm"]
        }
        var values = characters.map { $0.map(String.init) }
        values[2] = [page == 0 ? "⇧" : page == 1 ? "#+=" : "123"] + values[2] + ["⌫"]
        values.append((japanese ? [romajiLatin ? "aあ" : "あa"] : []) + [page == 0 ? "123" : "ABC", "🌐", "空白", "改行"])
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
                else if japanese && row == 3 && column == 0 {
                    key.accessibilityIdentifier = "qwerty-input-mode"
                    key.addAction(UIAction { [weak self] _ in
                        self?.romajiLatin.toggle(); self?.rebuild()
                    }, for: .touchUpInside)
                } else if row == 3 && column == pageColumn || row == 2 && column == 0 && page != 0 {
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
            if self.inputMode == .english {
                self.insertEnglish(output)
            } else {
                if self.containsRomaji, let romaji = self.romaji { _ = self.composition.flushRomaji(using: romaji) }
                self.containsRomaji = false
                self.composition.append(output); self.refreshConversion()
            }
            self.consumeQwertyShift()
        }
    }
    private func addCustomGrid(palette: KeyboardPalette) {
        guard let layout = customLayouts.first(where: { $0.id == activeCustomID }) else {
            status.text = "カスタム配列が選択されていません"
            addRow(["50音", "🌐"], palette: palette, special: true)
            return
        }
        let targets = CustomLayoutTargets(layouts: customLayouts)
        let grid = CustomKeyboardGrid(layout: layout) { [weak self] placement in
            guard let self else { return UIView() }
            let definition = placement.source["key"]
            let appearance = self.keyAppearance(special: definition?["isSpecialKey"] == .bool(true))
            let label = definition?["label"]?.string ?? ""
            let type = definition?["keyType"]?.string ?? "NORMAL"
            let key: UIButton = type == "STANDARD_FLICK" ? FlickKey(type: .custom) : RepeatingKey(type: .custom)
            (key as? FlickKey)?.restingTitle = label
            key.setTitle(label, for: .normal)
            key.accessibilityIdentifier = "custom-" + placement.id
            key.accessibilityLabel = label
            key.backgroundColor = definition?["isSpecialKey"] == .bool(true) ? palette.function : palette.key
            key.setTitleColor(palette.foreground, for: .normal)
            key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
            key.titleLabel?.numberOfLines = 2
            key.layer.cornerRadius = self.geometry.keyCornerRadius
            var action: CustomKeyAction
            if type != "NORMAL" && type != "STANDARD_FLICK" {
                action = .unsupported(raw: type, reason: "このキー入力方式は移植中です")
            } else if let raw = definition?["action"]?.string {
                action = .tap(raw, targets: targets)
            } else if definition?["isSpecialKey"] != .bool(true) {
                action = .text(label)
            } else { action = .unsupported(raw: placement.id, reason: "キーの操作が未設定です") }
            let special = definition?["isSpecialKey"] == .bool(true)
            if special, definition?["doubleTapAction"]?.string != nil, definition?["doubleTapEnabled"] != .bool(false) {
                action = .unsupported(raw: placement.id, reason: "ダブルタップ操作は移植中です")
            }
            let hasExtra = ["circularFlicks", "twoStepFlicks", "longPressFlicks", "twoStepLongPressFlicks"].contains { !(placement.source[$0]?.array ?? []).isEmpty }
            if hasExtra { action = .unsupported(raw: placement.id, reason: "追加ジェスチャーは移植中です") }
            (key as? RepeatingKey)?.repeatEnabled = [.command(.delete), .command(.backspace), .command(.cursorLeft)].contains(action)
            if let key = key as? FlickKey, !hasExtra, !(special && definition?["doubleTapAction"]?.string != nil && definition?["doubleTapEnabled"] != .bool(false)) {
                do {
                    let mapping = try CustomStandardFlick(placement: placement)
                    key.directionalValues = mapping.values
                    key.resolveDirection = { CustomStandardFlick.direction(dx: $0, dy: $1) }
                    key.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
                    key.onFlick = { [weak self] direction in
                        let text = mapping.values[direction.rawValue]
                        if !text.isEmpty { self?.customAction(.text(text), layout: layout) }
                    }
                } catch {
                    let failure = CustomKeyAction.unsupported(raw: placement.id, reason: error.localizedDescription)
                    key.onFlick = { [weak self] _ in self?.customAction(failure, layout: layout) }
                }
            } else {
                let resolved = action
                if let key = key as? FlickKey {
                    key.onFlick = { [weak self] _ in self?.customAction(resolved, layout: layout) }
                } else {
                    key.addAction(UIAction { [weak self] _ in self?.customAction(resolved, layout: layout) }, for: .touchUpInside)
                }
            }
            return SizedKey(key, scale: appearance.keyScale)
        }
        stack.addArrangedSubview(grid)
        addRow(["🌐", "空白", "⌫", "改行"], palette: palette, special: true)
        if let row = keyRows.last {
            let height = row.heightAnchor.constraint(equalToConstant: 44)
            height.priority = .defaultHigh
            height.isActive = true
        }
        let minimum = grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimum.priority = .defaultLow
        minimum.isActive = true
    }
    private func customAction(_ action: CustomKeyAction, layout: ImportedCustomLayout) {
        beforeInput?(); tapCycle.reset()
        switch action {
        case .unsupported(_, let reason): status.text = reason
        case .switchLayout(let id): activeCustomID = id; rememberKeyboard(); rebuild()
        case .inputText:
            status.text = "本家の特殊文字操作は移植中です"
        case .text(let text):
            guard !text.isEmpty else { return }
            if layout.source["layout"]?["isDirectMode"] == .bool(true) {
                commitComposition(); insert?(text)
            } else if layout.source["layout"]?["isRomaji"] == .bool(true), let romaji {
                containsRomaji = true; composition.appendRomaji(text, using: romaji); refreshConversion()
            } else {
                if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
                containsRomaji = false; composition.append(text); refreshConversion()
            }
        case .command(let command):
            switch command {
            case .doNothing: break
            case .delete, .backspace: pressed("⌫")
            case .space: pressed("空白")
            case .convert: if hasComposition { pressed("空白") }
            case .enter, .newLine: pressed("改行")
            case .confirm: commitComposition()
            case .paste: sumireAction(.paste)
            case .cursorLeft: sumireAction(.cursorLeft)
            case .nextKeyboard: pressed("🌐")
            case .modifier: pressed("゛")
            case .changeMode: status.text = "このモード切替操作は移植中です"
            case .forceNewLine: commitComposition(); insert?("\n")
            case .halfSpace, .commitAndSpace: commitComposition(); insert?(" ")
            case .fullSpace: commitComposition(); insert?("　")
            }
        }
    }
    private func addSumireGrid(palette: KeyboardPalette) {
        // The validated built-in definition is fixed at compile time.
        let arrangement = SumireKeyArrangement(rawValue: settingsDefaults.string(forKey: "sumire.keyArrangement") ?? "") ?? .toggle
        guard let grid = try? KeyboardGrid(layout: arrangement.layout(mode: sumireMode),
                                          horizontalGap: geometry.keySpacing,
                                          verticalGap: geometry.rowSpacing, makeKey: { [weak self] definition in
            guard let self else { return UIView() }
            let appearance = keyAppearance(special: definition.action != .text && definition.action != .modifier)
            if definition.action == .text {
                let index = definition.row * 3 + definition.column - 1
                let outputs = self.sumireMode == .japanese ?
                    ["a": "あいうえお", "ka": "かきくけこ", "sa": "さしすせそ",
                     "ta": "たちつてと", "na": "なにぬねの", "ha": "はひふへほ",
                     "ma": "まみむめも", "ya": "や(ゆ)よ", "ra": "らりるれろ",
                     "wa": "わをんー〜", "punctuation": "、。？！…"][definition.id]!.map(String.init) :
                    SumireInput.outputs(self.sumireMode, arrangement: arrangement, index: index)
                let values = outputs.joined()
                let key = FlickKey(type: .custom)
                key.values = values
                key.directionalValues = outputs
                key.restingTitle = definition.label
                key.thresholdShape = .radial
                key.setTitle(definition.label, for: .normal)
                key.accessibilityLabel = String(values.prefix(1))
                key.accessibilityIdentifier = "sumire-" + definition.id
                key.titleLabel?.font = .systemFont(ofSize: appearance.keyFontSize)
                key.titleLabel?.numberOfLines = 2
                key.titleLabel?.textAlignment = .center
                key.titleLabel?.adjustsFontSizeToFitWidth = true
                key.titleLabel?.minimumScaleFactor = 0.5
                key.setTitleColor(palette.foreground, for: .normal)
                key.backgroundColor = palette.key
                key.layer.cornerRadius = geometry.keyCornerRadius
                key.onFlick = { [weak self] direction in
                    self?.sumireFlick(index: index, outputs: outputs, direction: direction)
                }
                if !appearance.guidesVisible, definition.label.contains("\n") {
                    let label = definition.label as NSString
                    let newline = label.range(of: "\n").location
                    let secondarySize = self.settingsDefaults.object(forKey: "appearance.sumire.guideFontSize") == nil
                        ? max(8, appearance.keyFontSize * 0.625) : appearance.guideFontSize
                    let text = NSMutableAttributedString(string: definition.label, attributes: [
                        .font: UIFont.systemFont(ofSize: appearance.keyFontSize), .foregroundColor: palette.foreground])
                    text.addAttribute(.font, value: UIFont.systemFont(ofSize: secondarySize),
                        range: NSRange(location: newline + 1, length: label.length - newline - 1))
                    key.restingAttributedTitle = text; key.setAttributedTitle(text, for: .normal)
                }
                key.configureGuides(visible: appearance.guidesVisible, fontSize: appearance.guideFontSize, color: palette.foreground)
                if appearance.guidesVisible { key.restingTitle = String(values.prefix(1)); key.setTitle(key.restingTitle, for: .normal) }
                return SizedKey(key, scale: appearance.keyScale)
            }
            let directional = definition.action == .cursorLeft || definition.action == .delete || definition.id == "cursor_right_key"
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
            if definition.action == .nextKeyboard {
                self.configureKeyboardSwitch(key)
            } else if definition.action == .changeMode {
                if definition.id == "cursor_right_key" {
                    key.setTitle(nil, for: .normal); key.setImage(KeyboardIcon.right.image, for: .normal)
                }
                key.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if definition.id == "cursor_right_key" {
                        self.beforeInput?(); self.moveCompositionCursor(by: 1)
                    } else if definition.id == "colon_key" || definition.id == "hyphen_key" {
                        self.pressed(definition.label)
                    } else {
                        self.beforeInput?(); self.tapCycle.reset()
                        switch definition.id {
                        case "english_mode": self.sumireMode = .english
                        case "number_mode": self.sumireMode = .number
                        case "kana_mode": self.sumireMode = .japanese
                        default: self.sumireMode = self.sumireMode.next
                        }
                        self.rebuild()
                    }
                }, for: .touchUpInside)
            } else {
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
            if let gestureKey = key as? DirectionalActionKey {
                let cursor = definition.action == .cursorLeft || definition.id == "cursor_right_key"
                gestureKey.repeats = { direction in cursor ? [.tap, .left, .right].contains(direction) : direction == .tap }
                gestureKey.action = { [weak self, weak key] direction in
                    guard let self else { return }
                    self.beforeInput?()
                    if direction == .tap { key?.sendActions(for: .touchUpInside) }
                    else if cursor && direction == .right { self.moveCompositionCursor(by: 1) }
                    else if cursor && direction == .left { self.moveCompositionCursor(by: -1) }
                    else if definition.action == .delete && direction == .left {
                        if self.hasComposition {
                            self.composition.invalidate(); self.containsRomaji = false; self.tapCycle.reset()
                            self.refreshConversion()
                        } else { self.deleteUntilBoundary?() }
                    }
                }
            }
            return SizedKey(key, scale: appearance.keyScale)
        }) else { return }
        stack.addArrangedSubview(grid)
        let minimum = grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 176)
        minimum.priority = .defaultLow
        minimum.isActive = true
        updateSumireKeys()
    }
    private func sumireFlick(index: Int, outputs: [String], direction: FlickDirection) {
        beforeInput?()
        guard outputs.indices.contains(direction.rawValue), !outputs[direction.rawValue].isEmpty else {
            tapCycle.reset(); return
        }
        if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
        containsRomaji = false
        // The reference routes Sumire taps through sendCharTap/getNextInputChar,
        // while flicks append their mapped output. Layout arrangement does not
        // select tap-vs-flick behavior; these are independent settings.
        if direction == .tap && sumireMode != .number {
            let choice = tapCycle.choose(sumireMode.tapCycle(at: index), direction: .tap,
                generation: composition.generation, time: ProcessInfo.processInfo.systemUptime,
                enabled: tenKeyToggle)
            if choice.replacing { _ = composition.replaceLast(choice.text) }
            else { composition.append(choice.text) }
        } else { tapCycle.reset(); composition.append(outputs[direction.rawValue]) }
        refreshConversion()
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
        }
    }
    private func sumireAction(_ action: KeyboardLayout.Action) {
        beforeInput?()
        switch action {
        case .paste:
            // Read only following an explicit tap; iOS controls paste permission.
            if let text = UIPasteboard.general.string {
                tapCycle.reset()
                composition.append(text)
                refreshConversion()
            }
        case .cursorLeft:
            moveCompositionCursor(by: -1)
        case .nextKeyboard: pressed("🌐")
        case .modifier:
            if hasComposition { pressed("゛") }
            else { status.text = "記号・絵文字パネルは移植中です" }
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
        else { composition.append(choice.text) }
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
        closeExpandedCandidates()
        composition.invalidate()
        containsRomaji = false
        converted = []
        resultGeneration = nil
        selectedCandidate = nil
        candidateBar.candidates = []
        status.text = "Sumire · C++変換"
        englishComposition = false
        updateSumireKeys()
        converter.reset()
    }
    private func closeExpandedCandidates() {
        expandedCandidates?.removeFromSuperview()
        expandedCandidates = nil
        stack.accessibilityElementsHidden = false
    }
    private func showExpandedCandidates() {
        guard !converted.isEmpty, expandedCandidates == nil else { return }
        let palette = KeyboardPalette(hue: hue, dark: traitCollection.userInterfaceStyle == .dark)
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
        list.candidates = converted.map(\.text)
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
    private func refreshConversion() {
        closeExpandedCandidates()
        if inputMode == .tenKey || inputMode == .sumire || inputMode == .kana { updateModeConversionLanguage() }
        selectedCandidate = nil
        converted = []
        resultGeneration = nil
        candidateBar.candidates = []
        let reading = composition.reading
        updateSumireKeys()
        markReading()
        status.text = reading.isEmpty ? "Sumire · C++変換" : reading
        guard !reading.isEmpty else { englishComposition = false; converter.reset(); return }
        let generation = composition.generation
        let query = containsRomaji ? (romaji?.flush(reading) ?? reading) : reading
        converter.convert(query, generation: generation, editStart: 0, omission: englishComposition ? false : omissionSearch, english: englishComposition) { [weak self] response in
            guard let self else { return }
            self.beforeInput?()
            guard self.composition.accepts(generation) else { return }
            switch response {
            case .success(let result):
                guard result.generation == generation else { return }
                self.converted = result.candidates
                self.resultGeneration = generation
                self.candidateBar.candidates = result.candidates.map(\.text)
                if (self.liveConversion && !self.englishComposition && self.composition.cursorUTF16 == self.composition.reading.utf16.count) || self.composition.phase == .selecting {
                    self.selectedCandidate = result.candidates.isEmpty ? nil : 0
                    if let first = result.candidates.first { self.updateMarkedText?(self.previewText(first)) }
                }
                self.status.text = reading + (result.complete ? "" : " · 探索上限") + (result.warning.map { " · " + $0 } ?? "")
            case .failure(let error):
                // Keep every reading character; Return can still commit the reading.
                self.status.text = reading + " · " + error.localizedDescription
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
        beforeInput?()
        guard let generation = resultGeneration, composition.accepts(generation),
              converted.indices.contains(index) else { return }
        selectedCandidate = index
        commitComposition()
    }
    private func commitComposition() {
        if selectedCandidate == nil, containsRomaji, let romaji {
            _ = composition.flushRomaji(using: romaji)
        }
        var candidate: ConversionCandidate?
        if let generation = resultGeneration, composition.accepts(generation),
           let index = selectedCandidate, converted.indices.contains(index) {
            candidate = converted[index]
            converter.commit(generation: generation, candidate: converted[index].id, learn: index > 0 || learnFirstCandidate) { [weak self] message in
                if self?.hasComposition == false { self?.showDataNotice(message) }
            }
        }
        let text: String?
        if let candidate {
            guard candidate.range.location == 0 else { return }
            text = composition.commitPrefix(candidate.text, readingUTF16Length: candidate.range.length)
        } else { text = composition.commit() }
        guard let text else { return }
        containsRomaji = false
        if let commitMarkedText { commitMarkedText(text) } else { insert?(text) }
        converted = []
        resultGeneration = nil
        selectedCandidate = nil
        candidateBar.candidates = []
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
        settingsDefaults.set(selectionID(mode: inputMode, customID: activeCustomID), forKey: "keyboard.lastUsed")
    }
    private func selectKeyboard(_ mode: InputMode, customID: String?) {
        beforeInput?(); tapCycle.reset()
        inputMode = mode
        if let customID { activeCustomID = customID }
        rememberKeyboard()
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
            guard let self else { return }
            let choices = self.keyboardChoices
            let current = choices.firstIndex { $0.mode == self.inputMode &&
                ($0.mode != .custom || $0.customID == self.activeCustomID) } ?? -1
            let next = choices[(current + 1) % choices.count]
            self.selectKeyboard(next.mode, customID: next.customID)
        }, for: .touchUpInside)
    }
    private func pressed(_ value: String) {
        beforeInput?()
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
            if composition.deleteBackward() { refreshConversion() } else { delete?() }
        case "空白":
            if englishComposition { commitComposition(); insert?(" "); return }
            if composition.reading.isEmpty { insert?(" ") }
            else {
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
            if inputMode == .english { insertEnglish(value) }
            else if inputMode == .romaji && romajiLatin { commitComposition(); insert?(value) }
            else if inputMode == .romaji, let romaji {
                containsRomaji = true
                composition.appendRomaji(value, using: romaji)
                refreshConversion()
            } else {
                if containsRomaji, let romaji { _ = composition.flushRomaji(using: romaji) }
                containsRomaji = false
                composition.append(value)
                refreshConversion()
            }
        }
    }
    private func updateModeConversionLanguage() {
        let englishMode = (inputMode == .tenKey && tenKeyMode == .english)
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
        composition.append(text)
        refreshConversion()
    }
    private func consumeQwertyShift() {
        guard inputMode == .english || inputMode == .romaji else { return }
        qwertyLastShiftTap = 0
        if shifted && !qwertyCapsLock { shifted = false; updateQwertyCase() }
    }
}
