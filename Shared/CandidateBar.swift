import UIKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Horizontally scrolling, reusable candidate cells. No mock conversion candidates.
final class CandidateBar: UIView, UICollectionViewDelegateFlowLayout {
    var onExpand: (() -> Void)?
    var onSizingChange: (() -> Void)?
    private let expand = UIButton(type: .system)
    private var collectionTrailing: NSLayoutConstraint!
    private var expanded = false
    var onResize: (() -> Void)?
    var onClipboardCaptured: ((String?, Data?) -> Void)?
    var captureClipboardHistory = false
    var onSymbols: (() -> Void)?
    private let symbols = UIButton(type: .system)
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
        let captureHistory = captureClipboardHistory
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
                    guard let self, self.window != nil, self.clipboardAccessAllowed, self.clipboardRequest == request,
                          (insertText || self.automaticallyPreviewClipboard),
                          UIPasteboard.general.changeCount == generation else { return }
                    if self.captureClipboardHistory, let encoded { self.onClipboardCaptured?(nil, encoded) }
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
                    if self.captureClipboardHistory { self.onClipboardCaptured?(text, nil) }
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
    var showsShortcuts = true {
        didSet {
            guard showsShortcuts != oldValue else { return }
            clipboardRequest = UUID()
            height.constant = displayedHeight
            updateVerticalScrolling()
            onSizingChange?()
            collection.isHidden = showsShortcuts
            resize.isHidden = !showsShortcuts
            symbols.isHidden = !showsShortcuts
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
        symbols.tintColor = value.foreground
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
        resize.accessibilityLabel = "キーボードのサイズ変更"
        resize.addAction(UIAction { [weak self] _ in self?.onResize?() }, for: .touchUpInside)
        resize.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resize)
        NSLayoutConstraint.activate([resize.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     resize.topAnchor.constraint(equalTo: topAnchor),
                                     resize.widthAnchor.constraint(equalToConstant: 44),
                                     resize.heightAnchor.constraint(equalToConstant: 44)])
        symbols.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        symbols.accessibilityLabel = "絵文字・顔文字・記号・クリップボード"
        symbols.accessibilityIdentifier = "symbol-open"
        symbols.addAction(UIAction { [weak self] _ in self?.onSymbols?() }, for: .touchUpInside)
        symbols.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbols)
        NSLayoutConstraint.activate([symbols.leadingAnchor.constraint(equalTo: resize.trailingAnchor),
                                     symbols.topAnchor.constraint(equalTo: topAnchor),
                                     symbols.widthAnchor.constraint(equalToConstant: 44),
                                     symbols.heightAnchor.constraint(equalToConstant: 44)])
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier])
        pasteControl.target = self
        pasteControl.accessibilityIdentifier = "clipboard-preview"
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteControl)
        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: symbols.trailingAnchor, constant: 8),
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
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        if isUpdating { cell.accessibilityTraits.insert(.notEnabled) }
        cell.accessibilityLabel = item.text
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let text = dataSource.itemIdentifier(for: indexPath)?.text ?? ""
        let width = HistoricKanaFont.attributed(text).size().width
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 18)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor)
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
