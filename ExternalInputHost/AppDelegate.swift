import UIKit

// Deliberately independent of SumireCore/Shared and App Groups: all text is volatile.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Input Host", sessionRole: session.role)
        configuration.delegateClass = InputHostSceneDelegate.self
        return configuration
    }
}

final class InputHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = InputHostViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Read the editor at accessibility-query time: unmarkText need not emit an
/// editing notification. This observer never changes input or marked ranges.
private final class LiveInputStateLabel: UILabel {
    var snapshot: (() -> String)?
    override var accessibilityLabel: String? {
        get { snapshot?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
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
        let fieldState = LiveInputStateLabel()
        fieldState.text = "入力状態"
        fieldState.font = .preferredFont(forTextStyle: .caption2)
        fieldState.accessibilityIdentifier = "external-input-field-state"
        fieldState.isAccessibilityElement = true
        fieldState.snapshot = { [weak field] in
            guard let field else { return "unavailable" }
            let marked = field.markedTextRange
            let length = marked.map { field.offset(from: $0.start, to: $0.end) }
            return "marked=\(marked != nil);markedUTF16=\(length.map(String.init) ?? "-");sampleUptime=\(ProcessInfo.processInfo.systemUptime)"
        }
        let stack = UIStackView(arrangedSubviews: [title, note, fieldLabel, field, fieldState, textLabel, text])
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
