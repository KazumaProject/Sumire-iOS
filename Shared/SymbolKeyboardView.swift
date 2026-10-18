import UIKit
import SumireCore

struct SymbolClipboardItem {
    let id: String
    let text: String?
    let image: UIImage?
    let pinned: Bool
}

/// An overlay owned by the keyboard. Closing invokes a callback; it never switches the underlying layout.
final class SymbolKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClipboardRequested: (() -> Void)?
    var onClipboardPaste: ((String) -> Void)?
    var onClipboardPin: ((String, Bool) -> Void)?
    var onClipboardDelete: ((String) -> Void)?
    var onClipboardHistoryChanged: ((Bool) -> Void)?
    var clipboardHistoryEnabled = false { didSet { clipboardSwitch.isOn = clipboardHistoryEnabled } }
    private(set) var mode: SymbolKeyboardMode
    private let defaults: UserDefaults
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

    init(defaults: UserDefaults, catalog: [SymbolKeyboardCategory], initialMode: SymbolKeyboardMode? = nil) {
        self.defaults = defaults; self.catalog = catalog
        mode = initialMode ?? .initialMode(defaults: defaults)
        history = SymbolKeyboardHistory(defaults: defaults)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4; layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        accessibilityIdentifier = "symbol-keyboard"
        collection.register(SymbolCell.self, forCellWithReuseIdentifier: "symbol")
        collection.register(SymbolHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        collection.dataSource = self; collection.delegate = self
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

    func selectMode(_ mode: SymbolKeyboardMode) {
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
            let label = UILabel(); label.text = "履歴を保存"; label.textColor = palette.foreground
            categoryStack.addArrangedSubview(label); categoryStack.addArrangedSubview(clipboardSwitch)
            let paste = button("コピー内容を表示", image: "arrow.clockwise") { [weak self] in self?.onClipboardRequested?() }
            categoryStack.addArrangedSubview(paste)
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
    private var symbols: [String] { categories.indices.contains(selectedCategory) ? categories[selectedCategory].symbols : [] }
    private func clipboardSection(_ section: Int) -> [SymbolClipboardItem] { clipboardItems.filter { $0.pinned == (section == 0) } }
    private func reloadItems() {
        collection.reloadData(); collection.setContentOffset(.zero, animated: false)
        emptyLabel.isHidden = mode == .clipboard ? !clipboardItems.isEmpty : !symbols.isEmpty
        emptyLabel.text = mode == .clipboard ? "コピーした内容はここに表示します。\n上の更新ボタンで読み込みます。" : "このカテゴリには項目がありません。"
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
            cell.accessibilityIdentifier = "symbol-clipboard-" + item.id
        } else {
            cell.set(text: symbols[indexPath.item], image: nil, size: mode == .emoji ? (traitCollection.verticalSizeClass == .compact ? 30 : 36) : (mode == .emoticon ? 14 : 13), palette: palette)
            cell.accessibilityIdentifier = "symbol-item-" + String(indexPath.item)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if mode == .clipboard { onClipboardPaste?(clipboardSection(indexPath.section)[indexPath.item].id) }
        else {
            let value = symbols[indexPath.item]
            history.record(value, mode: mode, defaults: defaults); onInsert?(value)
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
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        if mode == .clipboard {
            let item = clipboardSection(indexPath.section)[indexPath.item]
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "貼り付け") { _ in self?.onClipboardPaste?(item.id) },
                    UIAction(title: item.pinned ? "ピン留めを解除" : "ピン留め") { _ in self?.onClipboardPin?(item.id, !item.pinned) },
                    UIAction(title: "削除", attributes: .destructive) { _ in self?.onClipboardDelete?(item.id) }
                ])
            }
        }
        guard categories.indices.contains(selectedCategory), categories[selectedCategory].id == "history" else { return nil }
        let value = symbols[indexPath.item]; let selectedMode = mode
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "履歴から削除", attributes: .destructive) { _ in
                guard let self else { return }; self.history.remove(value, mode: selectedMode, defaults: self.defaults); self.selectMode(selectedMode)
            }])
        }
    }
}

private final class SymbolCell: UICollectionViewCell {
    private let label = UILabel()
    private let image = UIImageView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center; label.numberOfLines = 2; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.6
        image.contentMode = .scaleAspectFit
        for view in [image, label] {
            contentView.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4), view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4), view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)])
        }
        isAccessibilityElement = true; accessibilityTraits = .button
        contentView.layer.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(text: String, image: UIImage?, size: CGFloat, palette: KeyboardPalette) {
        label.text = text; label.font = .systemFont(ofSize: size); label.textColor = palette.foreground
        self.image.image = image; label.isHidden = image != nil
        contentView.backgroundColor = palette.key; accessibilityLabel = text
    }
}
private final class SymbolHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) { super.init(frame: frame); label.font = .preferredFont(forTextStyle: .caption1); addSubview(label) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = bounds.insetBy(dx: 8, dy: 2) }
}
