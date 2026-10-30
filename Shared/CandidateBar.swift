import UIKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import SumireCore

@MainActor
protocol KeyboardToolbarActionRouting: AnyObject {
    var keyboardToolbarLiveConversionEnabled: Bool { get }
    @discardableResult func toggleKeyboardToolbarLiveConversion() -> Bool
    var keyboardToolbarLearningPaused: Bool { get }
    @discardableResult func toggleKeyboardToolbarLearningPause() -> Bool
}

/// Horizontally scrolling, reusable candidate cells. No mock conversion candidates.
final class CandidateBar: UIView, UICollectionViewDelegateFlowLayout {
    var onExpand: (() -> Void)?
    var onSizingChange: (() -> Void)?
    private let expand = UIButton(type: .system)
    private let keyboardPicker = UIButton(type: .system)
    private let liveConversionToggle = UIButton(type: .system)
    private let learningPauseToggle = UIButton(type: .system)
    private let datePicker = UIButton(type: .system)
    private let toolbarStack = UIStackView()
    private let pasteGroup = UIStackView()
    private var toolbarActions: [KeyboardToolbarAction] = []
    private var collectionTrailing: NSLayoutConstraint!
    private var expanded = false
    var onResize: (() -> Void)?
    var onClipboardCaptured: ((String?, Data?) -> Void)?
    var captureClipboardHistory = false
    var onSymbols: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onTemplates: (() -> Void)?
    var onTextMacros: (() -> Void)?
    private let symbols = UIButton(type: .system)
    private let clipboardShortcut = UIButton(type: .system)
    private let templates = UIButton(type: .system)
    private let textMacros = UIButton(type: .system)
    var onPasteText: ((String) -> Void)?
    var onInsertShortcutText: ((String) -> Void)?
    var onClipboardNotice: ((String) -> Void)?
    var automaticallyPreviewClipboard = false {
        didSet { if automaticallyPreviewClipboard != oldValue { clipboardReadGeneration = -1; refreshClipboard() } }
    }
    var clipboardAccessAllowed = true {
        didSet {
            guard clipboardAccessAllowed != oldValue else { return }
            clipboardRequest = UUID()
            refreshClipboard()
        }
    }
    private let clipboard = UIButton(type: .system)
    private let pasteControl: UIPasteControl = {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        return UIPasteControl(configuration: configuration)
    }()
    private var clipboardObservers: [NSObjectProtocol] = []
    private var clipboardReadGeneration = -1
    private var clipboardRequest = UUID()
    private var clipboardGeneration = -1
    private var dismissedGeneration = -1

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clipboardRequest = UUID()
        clipboardObservers.forEach(NotificationCenter.default.removeObserver)
        clipboardObservers.removeAll()
        guard window != nil else { return }
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
            clipboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reloadToolbarSettings()
                self?.refreshClipboard()
            })
        }
        reloadToolbarSettings()
        refreshClipboard()
    }
    deinit { clipboardObservers.forEach(NotificationCenter.default.removeObserver) }

    func refreshClipboard() {
        guard window != nil, showsShortcuts, toolbarActions.contains(.paste) else {
            clipboard.isHidden = true; pasteControl.isHidden = true; pasteGroup.isHidden = true; return
        }

        // UIPasteControl is the system's explicit, user-initiated paste path.
        // Keep it available with Full Access OFF; only hide the ambient
        // clipboard preview, which reads UIPasteboard directly.
        pasteControl.isHidden = false
        pasteGroup.isHidden = false
        guard clipboardAccessAllowed else {
            clipboard.isHidden = true
            clipboardReadGeneration = -1
            return
        }

        let board = UIPasteboard.general
        let generation = board.changeCount
        if generation != clipboardGeneration {
            clipboardGeneration = generation
            clipboard.setImage(nil, for: .normal)
            // Type detection does not pull the clipboard payload or ask for paste permission.
            clipboard.setTitle(board.hasImages ? "コピーした画像" : "コピーした文字", for: .normal)
        }
        clipboard.isHidden = generation == dismissedGeneration || !(board.hasImages || board.hasStrings)
        if automaticallyPreviewClipboard, !clipboard.isHidden, clipboardReadGeneration != generation {
            clipboardReadGeneration = generation
            loadClipboard(itemProviders: board.itemProviders, insertText: false)
        }
    }
    override func paste(itemProviders: [NSItemProvider]) {
        guard window != nil, showsShortcuts, toolbarActions.contains(.paste) else { return }
        loadClipboard(itemProviders: itemProviders, insertText: true)
    }
    private func loadClipboard(itemProviders: [NSItemProvider], insertText: Bool) {
        guard showsShortcuts, let provider = itemProviders.first else { return }
        // A paste control supplies providers only after an explicit user action.
        // In that path, never query UIPasteboard or capture the supplied data in
        // local clipboard history when Full Access is disabled.
        guard insertText || clipboardAccessAllowed else { return }
        let generation = clipboardAccessAllowed ? UIPasteboard.general.changeCount : nil
        clipboardRequest = UUID()
        let request = clipboardRequest
        let captureHistory = clipboardAccessAllowed && captureClipboardHistory
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, error in
                var thumbnail: CGImage?
                var encoded: Data?
                if let url, url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size <= 16 * 1024 * 1024, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    if captureHistory, size <= 4 * 1024 * 1024, let handle = try? FileHandle(forReadingFrom: url) {
                        encoded = try? handle.read(upToCount: 4 * 1024 * 1024 + 1)
                        try? handle.close()
                    }
                    thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 80,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                DispatchQueue.main.async {
                    guard let self, self.acceptClipboardResult(request: request, insertText: insertText, generation: generation) else { return }
                    if captureHistory, let encoded { self.onClipboardCaptured?(nil, encoded) }
                    if let thumbnail {
                        self.clipboard.setImage(UIImage(cgImage: thumbnail).withRenderingMode(.alwaysOriginal), for: .normal)
                        self.clipboard.setTitle("入力欄で貼り付け", for: .normal)
                        if insertText && !self.clipboardAccessAllowed { self.clipboard.isHidden = false }
                        if insertText { self.onClipboardNotice?("画像は入力先の貼り付けメニューから挿入してください") }
                    } else { self.onClipboardNotice?("この画像のプレビューを読み込めませんでした") }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                DispatchQueue.main.async {
                    guard let self, self.acceptClipboardResult(request: request, insertText: insertText, generation: generation) else { return }
                    guard let text = object as? String, !text.isEmpty else {
                        self.onClipboardNotice?("クリップボードを読み込めませんでした"); return
                    }
                    if captureHistory { self.onClipboardCaptured?(text, nil) }
                    if insertText {
                        self.onPasteText?(text)
                        if let generation {
                            self.dismissedGeneration = generation
                            self.refreshClipboard()
                        }
                    } else {
                        self.clipboard.setTitle(String(text.prefix(120)), for: .normal)
                    }
                }
            }
        }
    }
    private func acceptClipboardResult(request: UUID, insertText: Bool, generation: Int?) -> Bool {
        guard window != nil, showsShortcuts, clipboardRequest == request else { return false }
        if insertText { return true }
        guard clipboardAccessAllowed, automaticallyPreviewClipboard, let generation else { return false }
        return UIPasteboard.general.changeCount == generation
    }
    var showsShortcuts = true {
        didSet {
            guard showsShortcuts != oldValue else { return }
            clipboardRequest = UUID()
            height.constant = displayedHeight
            updateVerticalScrolling()
            onSizingChange?()
            collection.isHidden = showsShortcuts
            toolbarStack.isHidden = !showsShortcuts
            updateExpansionButton()
            refreshClipboard()
        }
    }
    private let resize = UIButton(type: .system)
    var onSelect: ((Int) -> Void)?
    private var palette = KeyboardPalette(hue: 0.73, dark: false)
    /// Keep the last accepted frame visible while a newer generation is being
    /// computed. It cannot be selected or expanded until that request completes.
    var isUpdating = false {
        didSet {
            guard isUpdating != oldValue else { return }
            collection.isUserInteractionEnabled = !isUpdating
            expand.isEnabled = !isUpdating
            refreshVisibleCells()
        }
    }
    var selectedIndex: Int? {
        didSet { if selectedIndex != oldValue { refreshVisibleCells() } }
    }
    func applyPalette(_ value: KeyboardPalette) {
        palette = value
        toolbarStack.tintColor = value.foreground
        symbols.tintColor = value.foreground
        expand.tintColor = value.foreground
        resize.tintColor = value.foreground
        clipboard.tintColor = value.foreground
        liveConversionToggle.tintColor = value.foreground
        learningPauseToggle.tintColor = value.foreground
        clipboardShortcut.tintColor = value.foreground
        templates.tintColor = value.foreground
        textMacros.tintColor = value.foreground
        refreshVisibleCells()
    }

    /// Rebuilds the visible toolbar from the same app-group preference the app
    /// edits. This reads settings only and does not inspect host text.
    func reloadToolbarSettings(defaults: UserDefaults? = nil) {
        let source = defaults ?? KeyboardSettings.sharedDefaults ?? .standard
        let actions = KeyboardToolbarPreferences.load(defaults: source)
        if actions != toolbarActions {
            toolbarActions = actions
            for view in toolbarStack.arrangedSubviews {
                toolbarStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for action in actions {
                switch action {
                case .emoji: toolbarStack.addArrangedSubview(symbols)
                case .paste: toolbarStack.addArrangedSubview(pasteGroup)
                case .template: toolbarStack.addArrangedSubview(templates)
                case .textMacros: toolbarStack.addArrangedSubview(textMacros)
                case .clipboard: toolbarStack.addArrangedSubview(clipboardShortcut)
                case .resize: toolbarStack.addArrangedSubview(resize)
                case .selectDate: toolbarStack.addArrangedSubview(datePicker)
                case .keyboardPicker: toolbarStack.addArrangedSubview(keyboardPicker)
                case .liveConversionToggle: toolbarStack.addArrangedSubview(liveConversionToggle)
                case .learningPause: toolbarStack.addArrangedSubview(learningPauseToggle)
                }
            }
            for view in toolbarStack.arrangedSubviews.dropLast() { toolbarStack.setCustomSpacing(0, after: view) }
            for index in actions.indices.dropLast() where actions[index + 1] == .paste {
                toolbarStack.setCustomSpacing(8, after: toolbarStack.arrangedSubviews[index])
            }
        }
        refreshLiveConversionToggle()
        refreshLearningPauseToggle()
        refreshClipboard()
    }

    /// Connects the globe control to UIInputViewController's documented input
    /// mode-list handler. UIKit needs the original UIControl event to distinguish
    /// a tap (advance) from a long press or swipe (show the enabled-keyboard list).
    func bindKeyboardPicker(target: Any?, action: Selector) {
        keyboardPicker.addTarget(target, action: action, for: .allTouchEvents)
    }
    struct Presentation: Equatable {
        let text: String
        var annotation: String? = nil
    }
    private var presentations: [Presentation] = []
    private var candidateTexts: [String] = []
    var candidates: [String] {
        get { candidateTexts }
        set { setCandidates(newValue.map { Presentation(text: $0) }) }
    }
    func setCandidates(_ values: [Presentation]) {
        guard values != presentations else { return }
        presentations = values
        candidateTexts = values.map(\.text)
        updateCandidateSnapshot()
        collection.collectionViewLayout.invalidateLayout()
        updateExpansionButton()
    }
    private var storedRowCount = 1
    private var displayedHeightLimit: CGFloat?
    var rowCount: Int {
        get { storedRowCount }
        set {
            let count = min(3, max(1, newValue))
            guard storedRowCount != count else { return }
            storedRowCount = count
            (collection.collectionViewLayout as? CandidateRowsLayout)?.setRowCount(count)
            height.constant = displayedHeight
            updateVerticalScrolling()
            collection.collectionViewLayout.invalidateLayout()
            clampContentOffset()
            onSizingChange?()
        }
    }
    // Keep the host keyboard frame stable when shortcuts give way to candidates.
    // Shortcut controls occupy one row; the configured rows remain reserved.
    var requestedDisplayedHeight: CGFloat { CGFloat(min(3, max(1, rowCount))) * 44 }
    var displayedHeight: CGFloat { configuredDisplayedHeight }
    func setDisplayedHeightLimit(_ limit: CGFloat) {
        let normalized = max(44, limit.isFinite ? limit : 44)
        guard displayedHeightLimit.map({ abs($0 - normalized) > 0.5 }) ?? true else { return }
        displayedHeightLimit = normalized
        height.constant = displayedHeight
        updateVerticalScrolling()
        collection.collectionViewLayout.invalidateLayout()
        clampContentOffset()
    }
    private var configuredDisplayedHeight: CGFloat {
        let requested = CGFloat(min(3, max(1, storedRowCount))) * 44
        guard let displayedHeightLimit else { return requested }
        let visibleRows = max(1, min(storedRowCount, Int(floor(displayedHeightLimit / 44))))
        return CGFloat(visibleRows) * 44
    }
    private func updateVerticalScrolling() {
        let canScrollRows = !showsShortcuts && displayedHeight < requestedDisplayedHeight
        collection.alwaysBounceVertical = canScrollRows
        collection.showsVerticalScrollIndicator = canScrollRows
    }
    private let collection: UICollectionView
    private struct Item: Hashable {
        let text: String
        let occurrence: Int
    }
    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collection) { [weak self] collection, path, item in
        guard let self else { return nil }
        guard let cell = collection.dequeueReusableCell(withReuseIdentifier: "candidate", for: path) as? CandidateCell else { return nil }
        self.configure(cell, item: item)
        return cell
    }
    private var annotations: [Item: String] = [:]
    private var height: NSLayoutConstraint!
    override init(frame: CGRect) {
        let layout = CandidateRowsLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collection.backgroundColor = .clear
        // KeyboardSurface already places this strip within its safe area. UIKit
        // automatic scroll insets would offset the first row and clip the last.
        collection.contentInsetAdjustmentBehavior = .never
        collection.delegate = self
        collection.register(CandidateCell.self, forCellWithReuseIdentifier: "candidate")
        _ = dataSource
        collection.accessibilityIdentifier = "candidate-items"
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)
        collectionTrailing = collection.trailingAnchor.constraint(equalTo: trailingAnchor)
        height = heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([height, collection.topAnchor.constraint(equalTo: topAnchor), collection.bottomAnchor.constraint(equalTo: bottomAnchor), collection.leadingAnchor.constraint(equalTo: leadingAnchor), collectionTrailing])
        expand.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expand.accessibilityLabel = "変換候補をすべて表示"
        expand.accessibilityIdentifier = "candidate-expand"
        expand.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        expand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expand)
        NSLayoutConstraint.activate([expand.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     expand.topAnchor.constraint(equalTo: topAnchor),
                                     expand.widthAnchor.constraint(equalToConstant: 44),
                                     expand.heightAnchor.constraint(equalToConstant: 44)])
        updateExpansionButton()
        resize.setImage(KeyboardIcon.resize.image, for: .normal)
        resize.accessibilityIdentifier = "toolbar-resize"
        resize.accessibilityLabel = "キーボードのサイズ変更"
        resize.addAction(UIAction { [weak self] _ in self?.onResize?() }, for: .touchUpInside)
        resize.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([resize.widthAnchor.constraint(equalToConstant: 44),
                                     resize.heightAnchor.constraint(equalToConstant: 44)])
        symbols.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        symbols.accessibilityLabel = "絵文字・顔文字・記号・クリップボード"
        symbols.accessibilityIdentifier = "symbol-open"
        symbols.addAction(UIAction { [weak self] _ in self?.onSymbols?() }, for: .touchUpInside)
        symbols.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([symbols.widthAnchor.constraint(equalToConstant: 44),
                                     symbols.heightAnchor.constraint(equalToConstant: 44)])
        clipboardShortcut.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        clipboardShortcut.accessibilityIdentifier = "toolbar-clipboard"
        clipboardShortcut.accessibilityLabel = "クリップボード履歴"
        clipboardShortcut.addAction(UIAction { [weak self] _ in self?.onClipboard?() }, for: .touchUpInside)
        clipboardShortcut.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([clipboardShortcut.widthAnchor.constraint(equalToConstant: 44),
                                     clipboardShortcut.heightAnchor.constraint(equalToConstant: 44)])
        templates.setImage(UIImage(systemName: "text.quote"), for: .normal)
        templates.accessibilityIdentifier = "toolbar-template"
        templates.accessibilityLabel = "定型文"
        templates.addAction(UIAction { [weak self] _ in self?.onTemplates?() }, for: .touchUpInside)
        templates.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([templates.widthAnchor.constraint(equalToConstant: 44),
                                     templates.heightAnchor.constraint(equalToConstant: 44)])
        textMacros.setImage(UIImage(systemName: "text.badge.plus"), for: .normal)
        textMacros.accessibilityIdentifier = "toolbar-text-macros"
        textMacros.accessibilityLabel = "定型マクロ"
        textMacros.addAction(UIAction { [weak self] _ in self?.onTextMacros?() }, for: .touchUpInside)
        textMacros.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([textMacros.widthAnchor.constraint(equalToConstant: 44),
                                     textMacros.heightAnchor.constraint(equalToConstant: 44)])
        keyboardPicker.setImage(UIImage(systemName: "globe"), for: .normal)
        keyboardPicker.accessibilityIdentifier = "toolbar-keyboard-picker"
        keyboardPicker.accessibilityLabel = "キーボード切替"
        keyboardPicker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([keyboardPicker.widthAnchor.constraint(equalToConstant: 44),
                                     keyboardPicker.heightAnchor.constraint(equalToConstant: 44)])
        datePicker.setImage(UIImage(systemName: "calendar"), for: .normal)
        datePicker.accessibilityIdentifier = "toolbar-date-picker"
        datePicker.accessibilityLabel = "日付を選択"
        let insertDate: (String) -> Void = { [weak self] text in self?.onInsertShortcutText?(text) }
        datePicker.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            let actions = KeyboardToolbarDateOptions.strings().map { text in
                UIAction(title: text) { _ in insertDate(text) }
            }
            completion(actions)
        }])
        datePicker.showsMenuAsPrimaryAction = true
        datePicker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([datePicker.widthAnchor.constraint(equalToConstant: 44),
                                     datePicker.heightAnchor.constraint(equalToConstant: 44)])
        liveConversionToggle.setImage(UIImage(systemName: "textformat"), for: .normal)
        liveConversionToggle.accessibilityIdentifier = "toolbar-live-conversion"
        liveConversionToggle.accessibilityLabel = "ライブ変換"
        liveConversionToggle.accessibilityHint = "このキーボードのライブ変換を切り替えます"
        liveConversionToggle.layer.cornerRadius = 8
        liveConversionToggle.addAction(UIAction { [weak self] _ in self?.toggleLiveConversionAction() }, for: .touchUpInside)
        liveConversionToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([liveConversionToggle.widthAnchor.constraint(equalToConstant: 44),
                                     liveConversionToggle.heightAnchor.constraint(equalToConstant: 44)])
        learningPauseToggle.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        learningPauseToggle.setImage(UIImage(systemName: "play.fill"), for: .selected)
        learningPauseToggle.accessibilityIdentifier = "toolbar-learning-pause"
        learningPauseToggle.layer.cornerRadius = 8
        learningPauseToggle.addAction(UIAction { [weak self] _ in self?.toggleLearningPauseAction() }, for: .touchUpInside)
        learningPauseToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([learningPauseToggle.widthAnchor.constraint(equalToConstant: 44),
                                     learningPauseToggle.heightAnchor.constraint(equalToConstant: 44)])
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier])
        pasteControl.target = self
        pasteControl.accessibilityIdentifier = "clipboard-preview"
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([pasteControl.widthAnchor.constraint(equalToConstant: 100),
                                     pasteControl.heightAnchor.constraint(equalToConstant: 44)])
        clipboard.accessibilityIdentifier = "clipboard-description"
        clipboard.isUserInteractionEnabled = false
        clipboard.titleLabel?.lineBreakMode = .byTruncatingTail
        clipboard.imageView?.contentMode = .scaleAspectFit
        clipboard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([clipboard.heightAnchor.constraint(equalToConstant: 44)])
        pasteGroup.axis = .horizontal
        pasteGroup.alignment = .center
        pasteGroup.distribution = .fill
        pasteGroup.spacing = 8
        pasteGroup.accessibilityIdentifier = "toolbar-paste-group"
        pasteGroup.addArrangedSubview(pasteControl)
        pasteGroup.addArrangedSubview(clipboard)
        toolbarStack.axis = .horizontal
        toolbarStack.alignment = .center
        toolbarStack.distribution = .fill
        toolbarStack.spacing = 0
        toolbarStack.accessibilityIdentifier = "keyboard-toolbar-actions"
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // Keep the toolbar in the first candidate row while the configured
            // height reserves the remaining rows for candidates. Centering it
            // in a two- or three-row bar makes the controls jump vertically
            // when the composition becomes empty.
            toolbarStack.topAnchor.constraint(equalTo: topAnchor),
            toolbarStack.heightAnchor.constraint(equalToConstant: 44)
        ])
        reloadToolbarSettings(defaults: KeyboardSettings.sharedDefaults ?? .standard)
        clipboard.isHidden = true
        pasteControl.isHidden = true
        pasteGroup.isHidden = true
        collection.isHidden = true
        toolbarStack.isHidden = false
        accessibilityLabel = "変換候補"
    }
    private func updateExpansionButton() {
        let visible = !expanded && !showsShortcuts && !candidates.isEmpty
        expand.isHidden = !visible
        collectionTrailing?.constant = visible ? -44 : 0
    }

    private func toggleLiveConversionAction() {
        guard let router = toolbarActionRouter() else { return }
        let enabled = router.toggleKeyboardToolbarLiveConversion()
        setLiveConversionToggle(enabled: enabled)
    }

    private func refreshLiveConversionToggle() {
        guard let router = toolbarActionRouter() else { return }
        setLiveConversionToggle(enabled: router.keyboardToolbarLiveConversionEnabled)
    }

    private func toggleLearningPauseAction() {
        guard let router = toolbarActionRouter() else { return }
        setLearningPause(paused: router.toggleKeyboardToolbarLearningPause())
    }

    private func refreshLearningPauseToggle() {
        guard let router = toolbarActionRouter() else { return }
        setLearningPause(paused: router.keyboardToolbarLearningPaused)
    }

    private func setLearningPause(paused: Bool) {
        learningPauseToggle.isSelected = paused
        learningPauseToggle.accessibilityLabel = paused ? "変換学習を再開" : "変換学習を一時停止"
        learningPauseToggle.accessibilityHint = paused
            ? "このキーボードセッション中の学習記録を再開します"
            : "このキーボードセッション中の学習記録を一時停止します"
        learningPauseToggle.accessibilityValue = paused ? "一時停止中" : "有効"
        learningPauseToggle.backgroundColor = paused ? UIColor.secondarySystemFill : .clear
    }

    private func setLiveConversionToggle(enabled: Bool) {
        liveConversionToggle.isSelected = enabled
        liveConversionToggle.accessibilityValue = enabled ? "オン" : "オフ"
        liveConversionToggle.backgroundColor = enabled ? UIColor.secondarySystemFill : .clear
    }

    private func toolbarActionRouter() -> KeyboardToolbarActionRouting? {
        var ancestor: UIView? = self
        while let view = ancestor {
            if let router = view as? KeyboardToolbarActionRouting { return router }
            ancestor = view.superview
        }
        return nil
    }
    func useExpandedLayout() {
        expanded = true
        height.isActive = false
        showsShortcuts = false
        if let layout = collection.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .vertical
            layout.invalidateLayout()
        }
        collection.alwaysBounceVertical = true
        updateExpansionButton()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateCandidateSnapshot() {
        var occurrences: [String: Int] = [:]
        annotations.removeAll(keepingCapacity: true)
        let items = presentations.map { presentation -> Item in
            let occurrence = occurrences[presentation.text, default: 0]
            occurrences[presentation.text] = occurrence + 1
            let item = Item(text: presentation.text, occurrence: occurrence)
            if let annotation = presentation.annotation, !annotation.isEmpty { annotations[item] = annotation }
            return item
        }
        let offset = collection.contentOffset
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        // Stable identities preserve existing cells. Per-keystroke movement or
        // cross-fades would make a fast list harder to follow, so apply atomically.
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collection.setContentOffset(offset, animated: false)
            self.clampContentOffset()
            refreshVisibleCells()
        }
    }
    private func clampContentOffset() {
        collection.layoutIfNeeded()
        let inset = collection.adjustedContentInset
        let offset = collection.contentOffset
        let x = min(max(-inset.left, offset.x), max(-inset.left, collection.contentSize.width - collection.bounds.width + inset.right))
        let y = min(max(-inset.top, offset.y), max(-inset.top, collection.contentSize.height - collection.bounds.height + inset.bottom))
        collection.setContentOffset(CGPoint(x: x, y: y), animated: false)
    }
    private func refreshVisibleCells() {
        UIView.performWithoutAnimation {
            for path in collection.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: path),
                      let cell = collection.cellForItem(at: path) as? CandidateCell else { continue }
                configure(cell, item: item)
            }
        }
    }
    private func configure(_ cell: CandidateCell, item: Item) {
        let selected = selectedIndex.map { dataSource.indexPath(for: item)?.item == $0 } ?? false
        cell.backgroundColor = selected ? palette.accent : .clear
        cell.layer.cornerRadius = 8
        cell.label.attributedText = HistoricKanaFont.attributed(item.text)
        cell.label.textColor = selected ? palette.accentForeground : palette.foreground
        let annotation = annotations[item]
        cell.annotation.attributedText = annotation.map { HistoricKanaFont.attributed($0, size: 11) }
        cell.annotation.textColor = (selected ? palette.accentForeground : palette.foreground).withAlphaComponent(0.8)
        cell.annotation.isHidden = annotation == nil
        cell.annotationWidth.isActive = annotation == nil
        cell.annotationGap.constant = annotation == nil ? 0 : 4
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        if isUpdating { cell.accessibilityTraits.insert(.notEnabled) }
        cell.accessibilityLabel = item.text
        cell.accessibilityValue = annotation
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let item = dataSource.itemIdentifier(for: indexPath)
        let text = item?.text ?? ""
        let detail = item.flatMap { annotations[$0] }
        let width = HistoricKanaFont.attributed(text).size().width +
            (detail.map { HistoricKanaFont.attributed($0, size: 11).size().width + 4 } ?? 0)
        return CGSize(width: min(max(44, width + 32), max(44, collection.bounds.width)), height: 44)
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isUpdating, let item = dataSource.itemIdentifier(for: indexPath),
              candidates.indices.contains(indexPath.item), candidates[indexPath.item] == item.text else { return }
        onSelect?(indexPath.item)
    }
}

private final class CandidateCell: UICollectionViewCell {
    let label = UILabel()
    let annotation = UILabel()
    var annotationWidth: NSLayoutConstraint!
    var annotationGap: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 18)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        annotation.translatesAutoresizingMaskIntoConstraints = false
        annotation.font = .systemFont(ofSize: 11)
        annotation.lineBreakMode = .byTruncatingTail
        annotation.accessibilityIdentifier = "candidate-annotation"
        label.setContentCompressionResistancePriority(UILayoutPriority(751), for: .horizontal)
        annotation.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        contentView.addSubview(label)
        contentView.addSubview(annotation)
        annotationWidth = annotation.widthAnchor.constraint(equalToConstant: 0)
        annotationGap = annotation.leadingAnchor.constraint(equalTo: label.trailingAnchor)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            label.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor),
            annotationGap,
            annotation.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            annotation.lastBaselineAnchor.constraint(equalTo: label.lastBaselineAnchor),
            annotation.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            annotation.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Horizontal flow layout aligns each column to its widest candidate, leaving
/// holes beside shorter candidates. Keep candidate order top-to-bottom while
/// packing each row independently; expanded mode retains normal vertical flow.
private final class CandidateRowsLayout: UICollectionViewFlowLayout {
    private var packed: [UICollectionViewLayoutAttributes] = []
    private var packedSize = CGSize.zero
    private var rowCount = 1
    func setRowCount(_ value: Int) {
        let count = min(3, max(1, value))
        guard rowCount != count else { return }
        rowCount = count
        invalidateLayout()
    }
    override func prepare() {
        guard scrollDirection == .horizontal, let collectionView else { super.prepare(); return }
        var ends = Array(repeating: CGFloat.zero, count: rowCount)
        packed.removeAll(keepingCapacity: true)
        let delegate = collectionView.delegate as? UICollectionViewDelegateFlowLayout
        guard collectionView.numberOfSections > 0 else { packedSize = collectionView.bounds.size; return }
        for index in 0..<collectionView.numberOfItems(inSection: 0) {
            let path = IndexPath(item: index, section: 0)
            let width = delegate?.collectionView?(collectionView, layout: self, sizeForItemAt: path).width ?? 44
            let row = index % rowCount
            let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
            attributes.frame = CGRect(x: ends[row], y: CGFloat(row) * 44, width: ceil(width), height: 44)
            packed.append(attributes)
            ends[row] = attributes.frame.maxX + minimumLineSpacing
        }
        packedSize = CGSize(width: max(collectionView.bounds.width, (ends.max() ?? 0) - minimumLineSpacing),
                            height: max(collectionView.bounds.height, CGFloat(rowCount) * 44))
    }
    override var collectionViewContentSize: CGSize {
        scrollDirection == .horizontal ? packedSize : super.collectionViewContentSize
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        scrollDirection == .horizontal ? packed.filter { $0.frame.intersects(rect) } : super.layoutAttributesForElements(in: rect)
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard scrollDirection == .horizontal else { return super.layoutAttributesForItem(at: indexPath) }
        return indexPath.section == 0 && packed.indices.contains(indexPath.item) ? packed[indexPath.item] : nil
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        scrollDirection == .horizontal ? collectionView?.bounds.size != newBounds.size : super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

/// Local fallback for historic kana absent from the system font. Candidate values
/// remain unchanged; only the glyphs used by the keyboard are selected here.
enum HistoricKanaFont {
    static let assetName = "NotoSerifHentaigana-Regular"
    static let assetSHA256 = "2231394c949fa1cea871d943cf7ff7c0552308fca9067d70b88a533351d6bb5c"
    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func fallback(size: CGFloat) -> UIFont? {
        _ = registered
        return UIFont(name: assetName, size: size)
    }

    private static let supportedScalars: CharacterSet? = {
        guard let font = fallback(size: 18) else { return nil }
        return CTFontCopyCharacterSet(font as CTFont) as CharacterSet
    }()

    static func attributed(_ text: String, size: CGFloat = 18) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size)])
        guard let font = fallback(size: size), let supported = supportedScalars else { return result }
        var offset = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            if (0x1B000...0x1B16F).contains(scalar.value), supported.contains(scalar) {
                result.addAttribute(.font, value: font, range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return result
    }
}
