import UIKit
import UniformTypeIdentifiers
import SumireCore

/// A keyboard-local macro picker. Clipboard text is accepted only through the
/// visible paste control and remains in memory only for this open panel.
final class KeyboardTextMacroPanel: UIView {
    var onSelect: ((String, String?) -> Void)?
    var onClose: (() -> Void)?

    private struct Item {
        let macro: PersonalTextMacro
        let requirements: Set<AndroidTextMacroContextRequirement>
    }

    private var palette: KeyboardPalette
    private let canUseContext: Bool
    private let hasSelection: Bool
    private let closeButton = UIButton(type: .system)
    private let pasteControl: UIPasteControl = {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        return UIPasteControl(configuration: configuration)
    }()
    private let status = UILabel()
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private let pasteStatus = UILabel()
    private var items: [Item] = []
    private var clipboardText: String?

    init(macros: [PersonalTextMacro], palette: KeyboardPalette,
         canUseContext: Bool, hasSelection: Bool) {
        self.palette = palette
        self.canUseContext = canUseContext
        self.hasSelection = hasSelection
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = palette.background
        accessibilityIdentifier = "text-macro-panel"
        accessibilityViewIsModal = true

        closeButton.setTitle("マクロを閉じる", for: .normal)
        closeButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        closeButton.tintColor = palette.foreground
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        closeButton.accessibilityIdentifier = "text-macro-close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        pasteControl.target = self
        pasteControl.accessibilityLabel = "クリップボードの文字を明示的に許可"
        pasteControl.accessibilityIdentifier = "text-macro-clipboard-paste"
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        pasteControl.isHidden = !canUseContext || !macros.contains { macro in
            guard macro.enabled else { return false }
            return (try? AndroidTextMacroCompiler.compile(macro.body).requirements.contains(.clipboard)) == true
        }

        status.text = canUseContext ? "使うマクロを選択してください" : "安全性を確認できないため、選択文字・クリップボードを使うマクロは停止しています"
        status.textColor = palette.functionForeground
        status.font = .preferredFont(forTextStyle: .footnote)
        status.numberOfLines = 0

        pasteStatus.textColor = palette.functionForeground
        pasteStatus.font = .preferredFont(forTextStyle: .caption1)
        pasteStatus.numberOfLines = 1
        pasteStatus.lineBreakMode = .byTruncatingTail

        rows.axis = .vertical
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        addSubview(closeButton)
        addSubview(pasteControl)
        addSubview(status)
        addSubview(pasteStatus)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 144),
            pasteControl.topAnchor.constraint(equalTo: topAnchor),
            pasteControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pasteControl.heightAnchor.constraint(equalToConstant: 44),
            pasteControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 124),
            status.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pasteStatus.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 2),
            pasteStatus.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            pasteStatus.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pasteStatus.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -10),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -10)
        ])
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier])
        setMacros(macros)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPalette(_ palette: KeyboardPalette) {
        self.palette = palette
        backgroundColor = palette.background
        closeButton.tintColor = palette.foreground
        status.textColor = palette.functionForeground
        pasteStatus.textColor = palette.functionForeground
        refreshRows()
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard canUseContext,
              let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            pasteStatus.text = "クリップボードに文字がありません"
            return
        }
        provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let text = object as? String, !text.isEmpty else {
                    self.pasteStatus.text = "クリップボードの文字を読み込めませんでした"
                    return
                }
                self.clipboardText = text
                self.pasteStatus.text = "クリップボードの文字をこの操作だけで利用できます"
                self.refreshRows()
            }
        }
    }

    private func setMacros(_ macros: [PersonalTextMacro]) {
        items = macros.filter(\.enabled).compactMap { macro in
            guard let compiled = try? AndroidTextMacroCompiler.compile(macro.body) else { return nil }
            return Item(macro: macro, requirements: compiled.requirements)
        }
        refreshRows()
    }

    private func refreshRows() {
        rows.arrangedSubviews.forEach { view in
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items {
            let available = item.requirements.isEmpty || (
                canUseContext && (!item.requirements.contains(.selection) || hasSelection) &&
                (!item.requirements.contains(.clipboard) || clipboardText != nil)
            )
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = item.macro.name
            let detail = item.macro.reading.map { "読み: \($0)" } ?? String(item.macro.body.prefix(80))
            configuration.subtitle = detail
            configuration.titleAlignment = .leading
            configuration.cornerStyle = .medium
            configuration.baseBackgroundColor = palette.function
            configuration.baseForegroundColor = palette.foreground
            button.configuration = configuration
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "text-macro-\(item.macro.id)"
            if !available {
                button.configuration?.subtitle = unavailableReason(for: item)
            }
            button.isEnabled = available
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onSelect?(item.macro.id, self.clipboardText)
            }, for: .touchUpInside)
            rows.addArrangedSubview(button)
        }
        if items.isEmpty {
            let empty = UILabel()
            empty.text = "有効な定型マクロがありません"
            empty.textColor = palette.functionForeground
            empty.font = .preferredFont(forTextStyle: .body)
            rows.addArrangedSubview(empty)
        }
    }

    private func unavailableReason(for item: Item) -> String {
        if !canUseContext { return "この入力欄ではコンテキスト利用を停止しています" }
        if item.requirements.contains(.selection) && !hasSelection { return "使う文字を先に選択してください" }
        if item.requirements.contains(.clipboard) && clipboardText == nil { return "先にクリップボードの文字を許可してください" }
        return "このマクロは現在使えません"
    }
}
