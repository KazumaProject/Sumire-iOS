import UIKit
import SumireCore
import UniformTypeIdentifiers

struct SymbolClipboardItem {
    let id: String
    let text: String?
    let image: UIImage?
    let pinned: Bool
    let isImage: Bool
    init(id: String, text: String?, image: UIImage?, pinned: Bool, isImage: Bool = false) {
        self.id = id; self.text = text; self.image = image; self.pinned = pinned
        self.isImage = isImage || image != nil
    }
}

/// An overlay owned by the keyboard. Closing invokes a callback; it never switches the underlying layout.
final class SymbolKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClipboardProviders: (([NSItemProvider]) -> Void)?
    var onClipboardThumbnailRequested: ((String) -> Void)?
    var clipboardAccessAllowed = true {
        didSet {
            // UIPasteControl is a system-mediated, user-initiated selection and
            // remains available with Full Access OFF. The host still gates
            // automatic reads and persistent history separately.
            pasteControl.isEnabled = true
            if mode == .clipboard {
                rebuildCategories()
                reloadItems()
            }
        }
    }
    private let pasteControl: UIPasteControl = {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        return UIPasteControl(configuration: configuration)
    }()
    var onClipboardRequested: (() -> Void)?
    var onClipboardPaste: ((String) -> Void)?
    var onClipboardPin: ((String, Bool) -> Void)?
    var onClipboardDelete: ((String) -> Void)?
    var onClipboardHistoryChanged: ((Bool) -> Void)?
    var onDefaultSkinToneChanged: ((EmojiSkinTone) -> Void)?
    var onSettingsWritten: (([String]) -> Void)?
    var defaultSkinTone: EmojiSkinTone {
        didSet {
            guard defaultSkinTone != oldValue else { return }
            defaultSkinTone.save(defaults: writableDefaults)
            onSettingsWritten?([EmojiSkinTone.settingsKey])
            if mode == .emoji { reloadItems() }
        }
    }
    private var skinTonePopup: UIView?
    private lazy var skinToneHold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(showSkinTones(_:)))
        gesture.minimumPressDuration = 0.4
        gesture.delegate = self
        return gesture
    }()
    var clipboardHistoryEnabled = false { didSet { clipboardSwitch.isOn = clipboardHistoryEnabled } }
    private(set) var mode: SymbolKeyboardMode
    private let defaults: UserDefaults
    private let writableDefaults: UserDefaults
    private let catalog: [SymbolKeyboardCategory]
    private var history: SymbolKeyboardHistory
    private var categories: [SymbolKeyboardCategory] = []
    private var selectedCategory = 0
    private var clipboardItems: [SymbolClipboardItem] = []
    private let categoryScroll = UIScrollView()
    private let categoryStack = UIStackView()
    private let bottom = UIStackView()
    private let clipboardSwitch = UISwitch()
    private let emptyLabel = UILabel()
    private var modeButtons: [SymbolKeyboardMode: UIButton] = [:]
    private let collection: UICollectionView
    private var palette = KeyboardPalette(hue: 0.73, dark: false)

    init(defaults: UserDefaults, writableDefaults: UserDefaults? = nil, catalog: [SymbolKeyboardCategory], initialMode: SymbolKeyboardMode? = nil) {
        self.defaults = defaults; self.catalog = catalog
        self.writableDefaults = writableDefaults ?? defaults
        mode = initialMode ?? .initialMode(defaults: defaults)
        history = SymbolKeyboardHistory(defaults: defaults)
        defaultSkinTone = EmojiSkinTone.load(defaults: defaults)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4; layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        accessibilityIdentifier = "symbol-keyboard"
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier])
        pasteControl.target = self
        pasteControl.accessibilityIdentifier = "symbol-clipboard-load"
        collection.register(SymbolCell.self, forCellWithReuseIdentifier: "symbol")
        collection.register(SymbolHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        collection.dataSource = self; collection.delegate = self
        collection.addGestureRecognizer(skinToneHold)
        collection.alwaysBounceVertical = true
        collection.accessibilityIdentifier = "symbol-items"
        categoryStack.spacing = 8; categoryStack.alignment = .fill
        categoryScroll.showsHorizontalScrollIndicator = false
        categoryScroll.addSubview(categoryStack)
        bottom.axis = .horizontal; bottom.distribution = .fillEqually; bottom.spacing = 2
        let close = button("戻る", image: "keyboard") { [weak self] in self?.onClose?() }
        close.accessibilityIdentifier = "symbol-close"
        bottom.addArrangedSubview(close)
        let icons = ["face.smiling", "textformat", "star", "clipboard"]
        for (index, mode) in SymbolKeyboardMode.allCases.enumerated() {
            let tab = button(mode.title, image: icons[index]) { [weak self] in self?.selectMode(mode) }
            tab.accessibilityIdentifier = "symbol-mode-" + mode.rawValue
            modeButtons[mode] = tab; bottom.addArrangedSubview(tab)
        }
        let delete = RepeatingKey(type: .system)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.accessibilityLabel = "削除"; delete.accessibilityIdentifier = "symbol-delete"
        delete.repeatEnabled = true
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        bottom.addArrangedSubview(delete)
        clipboardSwitch.accessibilityLabel = "クリップボード履歴を保存"
        clipboardSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.onClipboardHistoryChanged?(self.clipboardSwitch.isOn)
        }, for: .valueChanged)
        emptyLabel.textAlignment = .center; emptyLabel.numberOfLines = 0
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.isUserInteractionEnabled = false
        for view in [categoryScroll, collection, bottom, emptyLabel] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            categoryScroll.topAnchor.constraint(equalTo: topAnchor), categoryScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryScroll.trailingAnchor.constraint(equalTo: trailingAnchor), categoryScroll.heightAnchor.constraint(equalToConstant: 44),
            categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 6),
            categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -6),
            categoryStack.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor),
            categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor),
            categoryStack.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor), bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor), bottom.heightAnchor.constraint(equalToConstant: 52),
            collection.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor), collection.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor), collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: collection.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: collection.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: collection.widthAnchor, constant: -24)
        ])
        selectMode(mode)
        applyPalette(palette)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPalette(_ palette: KeyboardPalette) {
        self.palette = palette; backgroundColor = palette.background; collection.backgroundColor = palette.background
        emptyLabel.textColor = palette.foreground
        bottom.arrangedSubviews.forEach { $0.tintColor = palette.foreground; $0.backgroundColor = palette.function }
        updateSelectionAppearance(); collection.reloadData()
    }

    /// The host supplies content after its own pasteboard permission/history handling.
    func setClipboardItems(_ items: [SymbolClipboardItem]) {
        var seen = Set<String>()
        clipboardItems = items.filter { seen.insert($0.id).inserted }
        if mode == .clipboard { reloadItems() }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        // This delegate is reached for an explicit system paste action. Do not
        // inspect UIPasteboard here; the provider contains only the selection
        // the user approved through UIPasteControl.
        onClipboardProviders?(itemProviders)
    }
    /// Thumbnails live in the host's bounded cache or visible cells, not in every metadata row.
    func isClipboardItemVisible(id: String) -> Bool {
        guard mode == .clipboard else { return false }
        return collection.indexPathsForVisibleItems.contains { path in
            let entries = clipboardSection(path.section)
            return entries.indices.contains(path.item) && entries[path.item].id == id
        }
    }
    func setClipboardThumbnail(id: String, image: UIImage) {
        guard mode == .clipboard else { return }
        for path in collection.indexPathsForVisibleItems {
            let entries = clipboardSection(path.section)
            guard entries.indices.contains(path.item), entries[path.item].id == id,
                  let cell = collection.cellForItem(at: path) as? SymbolCell else { continue }
            cell.set(text: entries[path.item].text ?? "画像", image: image, size: 16, palette: palette)
        }
    }
    func showNotice(_ text: String) {
        emptyLabel.text = text; emptyLabel.isHidden = false
        emptyLabel.backgroundColor = palette.background.withAlphaComponent(0.95)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func selectMode(_ mode: SymbolKeyboardMode) {
        dismissSkinTones()
        self.mode = mode; selectedCategory = 0
        categories = catalog.filter { $0.mode == mode }
        let recent = history.symbols(for: mode)
        if !recent.isEmpty { categories.insert(.init(mode: mode, id: "history", title: "履歴", symbols: recent), at: 0) }
        rebuildCategories(); reloadItems()
        if mode == .clipboard { onClipboardRequested?() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && mode == .clipboard { onClipboardRequested?() }
    }
    override func layoutSubviews() { super.layoutSubviews(); collection.collectionViewLayout.invalidateLayout() }

    private func button(_ title: String, image: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = title
        if let image { button.setImage(UIImage(systemName: image), for: .normal) }
        else { button.setTitle(title, for: .normal) }
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func rebuildCategories() {
        categoryStack.arrangedSubviews.forEach { categoryStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if mode == .clipboard {
            let label = UILabel()
            label.text = clipboardAccessAllowed ? "履歴を保存" : "フルアクセスOFF"
            label.textColor = palette.foreground
            categoryStack.addArrangedSubview(label)
            if clipboardAccessAllowed { categoryStack.addArrangedSubview(clipboardSwitch) }
            categoryStack.addArrangedSubview(pasteControl)
        } else {
            for (index, category) in categories.enumerated() {
                let tab = button(category.title) { [weak self] in
                    guard let self else { return }; self.selectedCategory = index; self.updateSelectionAppearance(); self.reloadItems()
                }
                tab.accessibilityIdentifier = "symbol-category-" + category.id
                categoryStack.addArrangedSubview(tab)
            }
        }
        categoryScroll.setContentOffset(.zero, animated: false)
        updateSelectionAppearance()
    }
    private func updateSelectionAppearance() {
        for (key, button) in modeButtons {
            button.isSelected = key == mode
            button.backgroundColor = key == mode ? palette.accent : palette.function
            button.tintColor = key == mode ? palette.accentForeground : palette.foreground
            button.accessibilityTraits = key == mode ? [.button, .selected] : .button
        }
        for (index, view) in categoryStack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            let selected = mode != .clipboard && index == selectedCategory
            button.backgroundColor = selected ? palette.accent : palette.background
            button.setTitleColor(selected ? palette.accentForeground : palette.foreground, for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }
    private var isHistory: Bool { categories.indices.contains(selectedCategory) && categories[selectedCategory].id == "history" }
    private var symbols: [String] = []
    private func clipboardSection(_ section: Int) -> [SymbolClipboardItem] { clipboardItems.filter { $0.pinned == (section == 0) } }
    private func reloadItems() {
        dismissSkinTones()
        let values = categories.indices.contains(selectedCategory) ? categories[selectedCategory].symbols : []
        symbols = mode == .emoji && !isHistory ? values.map { EmojiSkinToneVariants.applying(defaultSkinTone, to: $0) } : values
        collection.reloadData(); collection.setContentOffset(.zero, animated: false)
        emptyLabel.isHidden = mode == .clipboard ? !clipboardItems.isEmpty : !symbols.isEmpty
        if mode == .clipboard {
            emptyLabel.text = clipboardAccessAllowed
                ? "コピーした内容はここに表示します。\n上のペーストボタンで読み込みます。"
                : "フルアクセスOFFでは、システムのペーストボタンで選択した文字を入力します。履歴には保存しません。"
        } else {
            emptyLabel.text = "このカテゴリには項目がありません。"
        }
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { mode == .clipboard ? 2 : 1 }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        mode == .clipboard ? clipboardSection(section).count : symbols.count
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "symbol", for: indexPath) as! SymbolCell
        if mode == .clipboard {
            let item = clipboardSection(indexPath.section)[indexPath.item]
            cell.set(text: item.text ?? "画像", image: item.image, size: 16, palette: palette)
            cell.showSkinToneIndicator(false)
            cell.accessibilityIdentifier = "symbol-clipboard-" + item.id
        } else {
            cell.set(text: symbols[indexPath.item], image: nil, size: mode == .emoji ? (traitCollection.verticalSizeClass == .compact ? 30 : 36) : (mode == .emoticon ? 14 : 13), palette: palette)
            cell.showSkinToneIndicator(mode == .emoji && !isHistory && !EmojiSkinToneVariants.variants(for: symbols[indexPath.item]).isEmpty)
            cell.accessibilityIdentifier = "symbol-item-" + String(indexPath.item)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard mode == .clipboard else { return }
        let item = clipboardSection(indexPath.section)[indexPath.item]
        if item.isImage && item.image == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isClipboardItemVisible(id: item.id) else { return }
                self.onClipboardThumbnailRequested?(item.id)
            }
        }
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if mode == .clipboard { onClipboardPaste?(clipboardSection(indexPath.section)[indexPath.item].id) }
        else {
            let value = symbols[indexPath.item]
            history.record(value, mode: mode, defaults: writableDefaults)
            onSettingsWritten?([SymbolKeyboardHistory.storageKey]); onInsert?(value)
        }
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns = mode == .emoji ? 7 : (mode == .emoticon ? 3 : (mode == .symbol ? 5 : (bounds.width > 600 ? 4 : 2)))
        return CGSize(width: max(1, (collectionView.bounds.width - 12 - CGFloat(columns - 1) * 4) / CGFloat(columns)), height: mode == .clipboard ? 96 : 48)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: mode == .clipboard && !clipboardSection(section).isEmpty ? 28 : 0)
    }
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! SymbolHeader
        view.label.text = indexPath.section == 0 ? "ピン留め" : "ピン留めなし"; view.label.textColor = palette.foreground
        return view
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === skinToneHold else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard mode == .emoji, !isHistory,
              let index = collection.indexPathForItem(at: gestureRecognizer.location(in: collection)),
              symbols.indices.contains(index.item) else { return false }
        return !EmojiSkinToneVariants.variants(for: symbols[index.item]).isEmpty
    }
    @objc private func showSkinTones(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, mode == .emoji, !isHistory,
              let index = collection.indexPathForItem(at: gesture.location(in: collection)),
              symbols.indices.contains(index.item), let cell = collection.cellForItem(at: index) else { return }
        let variants = EmojiSkinToneVariants.variants(for: symbols[index.item])
        guard !variants.isEmpty else { return }
        dismissSkinTones()
        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.accessibilityViewIsModal = true
        overlay.accessibilityIdentifier = "symbol-skin-tone-popup"
        let outside = button("肌色選択を閉じる") { [weak self] in self?.dismissSkinTones() }
        outside.setTitle(nil, for: .normal)
        outside.frame = overlay.bounds; outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(outside)
        let anchor = cell.convert(cell.bounds, to: self)
        let width = min(max(1, bounds.width - 12), CGFloat(variants.count) * 44 + 12)
        let x = max(6, min(bounds.width - width - 6, anchor.midX - width / 2))
        let y = max(0, min(bounds.height - 56, anchor.minY >= 56 ? anchor.minY - 56 : anchor.maxY))
        let scroll = UIScrollView(frame: CGRect(x: x, y: y, width: width, height: 56))
        scroll.backgroundColor = palette.key; scroll.layer.cornerRadius = 12
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentSize = CGSize(width: CGFloat(variants.count) * 44 + 12, height: 56)
        for (position, variant) in variants.enumerated() {
            let choice = button(variant) { [weak self] in
                guard let self else { return }
                self.dismissSkinTones()
                let tone = EmojiSkinTone.tone(in: variant)
                self.defaultSkinTone = tone; self.onDefaultSkinToneChanged?(tone)
                self.history.record(variant, mode: .emoji, defaults: self.defaults)
                self.onInsert?(variant)
            }
            choice.accessibilityLabel = variant + "、" + EmojiSkinTone.tone(in: variant).title
            choice.accessibilityIdentifier = "symbol-skin-tone-" + EmojiSkinTone.tone(in: variant).rawValue
            choice.titleLabel?.font = .systemFont(ofSize: 30)
            choice.frame = CGRect(x: 6 + CGFloat(position) * 44, y: 6, width: 44, height: 44)
            scroll.addSubview(choice)
        }
        overlay.addSubview(scroll); addSubview(overlay); skinTonePopup = overlay
        UIAccessibility.post(notification: .layoutChanged, argument: scroll.subviews.first)
    }
    private func dismissSkinTones() {
        skinTonePopup?.removeFromSuperview(); skinTonePopup = nil
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === collection { dismissSkinTones() }
    }
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        if mode == .clipboard {
            let item = clipboardSection(indexPath.section)[indexPath.item]
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var actions = [UIAction(title: "貼り付け") { _ in self?.onClipboardPaste?(item.id) }]
                if item.id != "current" {
                    actions.append(UIAction(title: item.pinned ? "ピン留めを解除" : "ピン留め") { _ in self?.onClipboardPin?(item.id, !item.pinned) })
                }
                actions.append(UIAction(title: "削除", attributes: .destructive) { _ in self?.onClipboardDelete?(item.id) })
                return UIMenu(children: actions)
            }
        }
        guard categories.indices.contains(selectedCategory), categories[selectedCategory].id == "history" else { return nil }
        let value = symbols[indexPath.item]; let selectedMode = mode
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "履歴から削除", attributes: .destructive) { _ in
                guard let self else { return }
                self.history.remove(value, mode: selectedMode, defaults: self.writableDefaults)
                self.onSettingsWritten?([SymbolKeyboardHistory.storageKey]); self.selectMode(selectedMode)
            }])
        }
    }
}

private final class SymbolCell: UICollectionViewCell {
    private let label = UILabel()
    private let image = UIImageView()
    private let indicator = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center; label.numberOfLines = 2; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.6
        image.contentMode = .scaleAspectFit
        for view in [image, label] {
            contentView.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4), view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4), view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)])
        }
        indicator.text = "▾"; indicator.font = .systemFont(ofSize: 9); indicator.isHidden = true
        contentView.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([indicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2), indicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1)])
        isAccessibilityElement = true; accessibilityTraits = .button
        contentView.layer.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showSkinToneIndicator(_ visible: Bool) {
        indicator.isHidden = !visible
        accessibilityHint = visible ? "長押しして肌色を選択" : nil
    }
    func set(text: String, image: UIImage?, size: CGFloat, palette: KeyboardPalette) {
        label.text = text; label.font = .systemFont(ofSize: size); label.textColor = palette.foreground
        self.image.image = image; label.isHidden = image != nil
        indicator.textColor = palette.foreground
        contentView.backgroundColor = palette.key; accessibilityLabel = text
    }
}
private final class SymbolHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) { super.init(frame: frame); label.font = .preferredFont(forTextStyle: .caption1); addSubview(label) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = bounds.insetBy(dx: 8, dy: 2) }
}
