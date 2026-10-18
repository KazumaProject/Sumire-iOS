import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Horizontally scrolling, reusable candidate cells. No mock conversion candidates.
final class CandidateBar: UIView, UICollectionViewDelegateFlowLayout {
    var onExpand: (() -> Void)?
    private let expand = UIButton(type: .system)
    private var collectionTrailing: NSLayoutConstraint!
    private var expanded = false
    var onResize: (() -> Void)?
    var onPasteText: ((String) -> Void)?
    var onClipboardNotice: ((String) -> Void)?
    var automaticallyPreviewClipboard = false {
        didSet { if automaticallyPreviewClipboard != oldValue { clipboardReadGeneration = -1; refreshClipboard() } }
    }
    var clipboardAccessAllowed = true { didSet { refreshClipboard() } }
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
            clipboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshClipboard() })
        }
        refreshClipboard()
    }
    deinit { clipboardObservers.forEach(NotificationCenter.default.removeObserver) }

    func refreshClipboard() {
        guard window != nil, clipboardAccessAllowed else { clipboard.isHidden = true; pasteControl.isHidden = true; return }
        let board = UIPasteboard.general
        let generation = board.changeCount
        if generation != clipboardGeneration {
            clipboardGeneration = generation
            clipboard.setImage(nil, for: .normal)
            // Type detection does not pull the clipboard payload or ask for paste permission.
            clipboard.setTitle(board.hasImages ? "コピーした画像" : "コピーした文字", for: .normal)
        }
        clipboard.isHidden = !showsShortcuts || generation == dismissedGeneration || !(board.hasImages || board.hasStrings)
        pasteControl.isHidden = clipboard.isHidden
        if automaticallyPreviewClipboard, !clipboard.isHidden, clipboardReadGeneration != generation {
            clipboardReadGeneration = generation
            loadClipboard(itemProviders: board.itemProviders, insertText: false)
        }
    }
    override func paste(itemProviders: [NSItemProvider]) {
        loadClipboard(itemProviders: itemProviders, insertText: true)
    }
    private func loadClipboard(itemProviders: [NSItemProvider], insertText: Bool) {
        guard clipboardAccessAllowed, showsShortcuts, let provider = itemProviders.first else { return }
        let generation = UIPasteboard.general.changeCount
        clipboardRequest = UUID()
        let request = clipboardRequest
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, error in
                var thumbnail: CGImage?
                if let url, url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size <= 16 * 1024 * 1024, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 80,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                DispatchQueue.main.async {
                    guard let self, self.window != nil, self.clipboardAccessAllowed, self.clipboardRequest == request,
                          (insertText || self.automaticallyPreviewClipboard),
                          UIPasteboard.general.changeCount == generation else { return }
                    if let thumbnail {
                        self.clipboard.setImage(UIImage(cgImage: thumbnail).withRenderingMode(.alwaysOriginal), for: .normal)
                        self.clipboard.setTitle("入力欄で貼り付け", for: .normal)
                        if insertText { self.onClipboardNotice?("画像は入力先の貼り付けメニューから挿入してください") }
                    } else { self.onClipboardNotice?("この画像のプレビューを読み込めませんでした") }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                DispatchQueue.main.async {
                    guard let self, self.window != nil, self.clipboardAccessAllowed, self.clipboardRequest == request,
                          (insertText || self.automaticallyPreviewClipboard), self.showsShortcuts,
                          UIPasteboard.general.changeCount == generation else { return }
                    guard let text = object as? String, !text.isEmpty else {
                        self.onClipboardNotice?("クリップボードを読み込めませんでした"); return
                    }
                    if insertText {
                        self.onPasteText?(text)
                        self.dismissedGeneration = generation
                        self.refreshClipboard()
                    } else {
                        self.clipboard.setTitle(String(text.prefix(120)), for: .normal)
                    }
                }
            }
        }
    }
    var showsShortcuts = true { didSet { guard showsShortcuts != oldValue else { return }; clipboardRequest = UUID(); collection.isHidden = showsShortcuts; resize.isHidden = !showsShortcuts; updateExpansionButton(); refreshClipboard() } }
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
        expand.tintColor = value.foreground
        resize.tintColor = value.foreground
        clipboard.tintColor = value.foreground
        refreshVisibleCells()
    }
    var candidates: [String] = [] {
        didSet {
            guard candidates != oldValue else { return }
            updateCandidateSnapshot()
            updateExpansionButton()
        }
    }
    var rowCount = 1 {
        didSet {
            let count = min(3, max(1, rowCount))
            if rowCount != count { rowCount = count }
            height.constant = CGFloat(count) * 44
            collection.collectionViewLayout.invalidateLayout()
        }
    }
    private let collection: UICollectionView
    private struct Item: Hashable {
        let text: String
        let occurrence: Int
    }
    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collection) { [weak self] collection, path, item in
        guard let self else { return nil }
        let cell = collection.dequeueReusableCell(withReuseIdentifier: "candidate", for: path)
        self.configure(cell, item: item)
        return cell
    }
    private var height: NSLayoutConstraint!
    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "candidate")
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
        resize.accessibilityLabel = "キーボードのサイズ変更"
        resize.addAction(UIAction { [weak self] _ in self?.onResize?() }, for: .touchUpInside)
        resize.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resize)
        NSLayoutConstraint.activate([resize.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     resize.topAnchor.constraint(equalTo: topAnchor),
                                     resize.widthAnchor.constraint(equalToConstant: 44),
                                     resize.heightAnchor.constraint(equalToConstant: 44)])
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier])
        pasteControl.target = self
        pasteControl.accessibilityIdentifier = "clipboard-preview"
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteControl)
        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: resize.trailingAnchor, constant: 8),
            pasteControl.topAnchor.constraint(equalTo: topAnchor),
            pasteControl.widthAnchor.constraint(equalToConstant: 100),
            pasteControl.heightAnchor.constraint(equalToConstant: 44)
        ])
        clipboard.accessibilityIdentifier = "clipboard-description"
        clipboard.isUserInteractionEnabled = false
        clipboard.titleLabel?.lineBreakMode = .byTruncatingTail
        clipboard.imageView?.contentMode = .scaleAspectFit
        clipboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipboard)
        NSLayoutConstraint.activate([
            clipboard.leadingAnchor.constraint(equalTo: pasteControl.trailingAnchor, constant: 8),
            clipboard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clipboard.topAnchor.constraint(equalTo: topAnchor),
            clipboard.heightAnchor.constraint(equalToConstant: 44)
        ])
        clipboard.isHidden = true
        pasteControl.isHidden = true
        collection.isHidden = true
        accessibilityLabel = "変換候補"
    }
    private func updateExpansionButton() {
        let visible = !expanded && !showsShortcuts && !candidates.isEmpty
        expand.isHidden = !visible
        collectionTrailing?.constant = visible ? -44 : 0
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
        let items = candidates.map { text -> Item in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return Item(text: text, occurrence: occurrence)
        }
        let offset = collection.contentOffset
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        // Stable identities preserve existing cells. Per-keystroke movement or
        // cross-fades would make a fast list harder to follow, so apply atomically.
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collection.layoutIfNeeded()
            let inset = collection.adjustedContentInset
            let x = min(max(-inset.left, offset.x), max(-inset.left, collection.contentSize.width - collection.bounds.width + inset.right))
            let y = min(max(-inset.top, offset.y), max(-inset.top, collection.contentSize.height - collection.bounds.height + inset.bottom))
            collection.setContentOffset(CGPoint(x: x, y: y), animated: false)
            refreshVisibleCells()
        }
    }
    private func refreshVisibleCells() {
        UIView.performWithoutAnimation {
            for path in collection.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: path),
                      let cell = collection.cellForItem(at: path) else { continue }
                configure(cell, item: item)
            }
        }
    }
    private func configure(_ cell: UICollectionViewCell, item: Item) {
        var content = UIListContentConfiguration.cell()
        content.text = item.text
        content.textProperties.numberOfLines = 1
        content.textProperties.font = .systemFont(ofSize: 18)
        let selected = selectedIndex.map { dataSource.indexPath(for: item)?.item == $0 } ?? false
        content.textProperties.color = selected ? palette.accentForeground : palette.foreground
        cell.backgroundColor = selected ? palette.accent : .clear
        cell.layer.cornerRadius = 8
        cell.contentConfiguration = content
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        if isUpdating { cell.accessibilityTraits.insert(.notEnabled) }
        cell.accessibilityLabel = item.text
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let text = dataSource.itemIdentifier(for: indexPath)?.text ?? ""
        let width = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18)]).width
        return CGSize(width: min(max(44, width + 32), max(44, collection.bounds.width)), height: 44)
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isUpdating, let item = dataSource.itemIdentifier(for: indexPath),
              candidates.indices.contains(indexPath.item), candidates[indexPath.item] == item.text else { return }
        onSelect?(indexPath.item)
    }
}
