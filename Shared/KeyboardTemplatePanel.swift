import UIKit
import SumireCore

/// Read-only template selection for the keyboard toolbar. Selecting an entry
/// returns its text to the host; this view does not read or write shared data.
final class KeyboardTemplatePanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let templates: [PersonalWord]
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let titleLabel = UILabel()
    private let list: UICollectionView
    private let emptyLabel = UILabel()
    private var palette = KeyboardPalette(hue: 0.73, dark: false)

    init(templates: [PersonalWord]) {
        self.templates = templates
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        list = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        accessibilityIdentifier = "keyboard-template-panel"
        list.accessibilityIdentifier = "keyboard-template-list"
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        list.register(KeyboardTemplateCell.self, forCellWithReuseIdentifier: "template")

        titleLabel.text = "定型文"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.accessibilityIdentifier = "keyboard-template-title"

        let close = UIButton(type: .system)
        close.setTitle("戻る", for: .normal)
        close.accessibilityIdentifier = "keyboard-template-close"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), close])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "定型文は登録されていません"
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "keyboard-template-empty"
        emptyLabel.isHidden = !templates.isEmpty
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(list)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 44),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -24)
        ])
        applyPalette(palette)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func ordered(_ templates: [PersonalWord]) -> [PersonalWord] {
        templates.enumerated().sorted { left, right in
            if left.element.reading != right.element.reading {
                return left.element.reading.utf8.lexicographicallyPrecedes(right.element.reading.utf8)
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    var orderedTemplateWords: [String] { templates.map(\.word) }

    func applyPalette(_ palette: KeyboardPalette) {
        self.palette = palette
        backgroundColor = palette.background
        list.backgroundColor = palette.background
        titleLabel.textColor = palette.foreground
        emptyLabel.textColor = palette.foreground
        list.reloadData()
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        templates.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "template", for: indexPath) as! KeyboardTemplateCell
        let entry = templates[indexPath.item]
        cell.configure(word: entry.word, reading: entry.reading, palette: palette)
        cell.accessibilityIdentifier = "keyboard-template-item-\(indexPath.item)"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectTemplate(at: indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: max(1, collectionView.bounds.width - 16), height: 56)
    }

    func selectTemplate(at index: Int) {
        guard templates.indices.contains(index) else { return }
        onInsert?(templates[index].word)
    }
}

private final class KeyboardTemplateCell: UICollectionViewCell {
    private let wordLabel = UILabel()
    private let readingLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wordLabel.font = .preferredFont(forTextStyle: .body)
        wordLabel.numberOfLines = 1
        wordLabel.lineBreakMode = .byTruncatingTail
        readingLabel.font = .preferredFont(forTextStyle: .caption1)
        readingLabel.numberOfLines = 1
        readingLabel.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [wordLabel, readingLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        contentView.layer.cornerRadius = 8
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(word: String, reading: String, palette: KeyboardPalette) {
        wordLabel.text = word
        wordLabel.textColor = palette.foreground
        readingLabel.text = reading
        readingLabel.textColor = palette.foreground.withAlphaComponent(0.65)
        contentView.backgroundColor = palette.key
        accessibilityLabel = word + "、" + reading
    }
}
