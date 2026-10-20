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

final class InputHostViewController: UIViewController {
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
        let stack = UIStackView(arrangedSubviews: [title, note, fieldLabel, field, textLabel, text])
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
    }
}
