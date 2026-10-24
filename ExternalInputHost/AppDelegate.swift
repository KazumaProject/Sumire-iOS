import UIKit

// Deliberately independent of SumireCore/Shared and App Groups: all text is volatile.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = InputHostViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class InputHostViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private weak var field: UITextField?
    private weak var text: UITextView?
    private let fieldState = UILabel()
    private let textState = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Sumire 外部入力テスト"
        title.font = .preferredFont(forTextStyle: .headline)
        let note = UILabel()
        note.text = "テスト用の文字だけを入力してください。保存・送信はしません。設定でSumireを有効にして選択してください。"
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .footnote)
        let fieldLabel = UILabel()
        fieldLabel.text = "UITextField"
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.accessibilityIdentifier = "external-input-field"
        field.accessibilityLabel = "テスト用一行入力"
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.delegate = self
        self.field = field
        fieldState.accessibilityIdentifier = "external-input-field-state"
        fieldState.isAccessibilityElement = true
        let textLabel = UILabel()
        textLabel.text = "UITextView"
        let text = UITextView()
        text.font = .preferredFont(forTextStyle: .body)
        text.layer.borderWidth = 1
        text.layer.borderColor = UIColor.separator.cgColor
        text.accessibilityIdentifier = "external-input-view"
        text.accessibilityLabel = "テスト用複数行入力"
        text.autocorrectionType = .no
        text.spellCheckingType = .no
        text.delegate = self
        self.text = text
        textState.accessibilityIdentifier = "external-input-view-state"
        textState.isAccessibilityElement = true
        let stack = UIStackView(arrangedSubviews: [title, note, fieldLabel, field, fieldState,
                                                   textLabel, text, textState])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 36),
            text.heightAnchor.constraint(equalToConstant: 64)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshInputState),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshInputState()
    }

    func textFieldDidChangeSelection(_ textField: UITextField) { refreshInputState() }
    func textViewDidChangeSelection(_ textView: UITextView) { refreshInputState() }

    @objc private func refreshInputState() {
        fieldState.text = state(of: field)
        textState.text = state(of: text)
    }

    private func state(of input: UITextInput?) -> String {
        guard let input else { return "unavailable" }
        let contents = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
            .flatMap { input.text(in: $0) } ?? ""
        let contentClass: String
        switch contents {
        case "": contentClass = "empty"
        case "あ": contentClass = "first"
        case "あい": contentClass = "both"
        case "い": contentClass = "secondOnly"
        default: contentClass = "other"
        }
        let marked = input.markedTextRange
        let markedLength = marked.map { input.offset(from: $0.start, to: $0.end) }
        let selection = input.selectedTextRange.map {
            input.offset(from: input.beginningOfDocument, to: $0.start)
        }
        return "content=\(contentClass);marked=\(marked != nil);markedUTF16=\(markedLength.map(String.init) ?? "-");selectionUTF16=\(selection.map(String.init) ?? "-")"
    }
}
