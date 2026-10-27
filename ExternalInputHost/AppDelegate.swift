import UIKit

// Deliberately independent of SumireCore/Shared and App Groups: all text is volatile.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Input Host", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = InputHostSceneDelegate.self
        return configuration
    }
}

final class InputHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = InputHostViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}

/// Read the editor itself whenever XCTest requests state. Unmarking need not
/// emit an editing notification, so a cached UILabel.text is not evidence of
/// the current markedTextRange. This getter never changes host input.
private final class LiveInputStateLabel: UILabel {
    var snapshot: (() -> String)?
    override var accessibilityLabel: String? {
        get { snapshot?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }
}

final class InputHostViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private weak var field: UITextField?
    private weak var otherField: UITextField?
    private weak var matchingContextField: UITextField?
    private weak var forwardDeleteField: UITextField?
    private weak var forwardDeleteSelectionStatus: UILabel?
    private weak var text: UITextView?
    private let fieldState = LiveInputStateLabel()
    private let otherFieldState = LiveInputStateLabel()
    private let matchingContextFieldState = LiveInputStateLabel()
    private let textState = LiveInputStateLabel()
    private let lifecycleState = UILabel()
    private var lifecycleEvents: [String] = []
    private var hostEventSequence = 0
    private var replacementMarkSeen = false
    private var originalFieldEndEditingBoundary: String?
    private var firstOriginalUnmarkedCallbackAfterEndEditing: String?

    private var usesIdenticalContextFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--identical-context-owner")
    }

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
        let forwardDeleteScenario = ForwardDeleteScenario(arguments: ProcessInfo.processInfo.arguments)
        field.text = forwardDeleteScenario?.text ?? (usesIdenticalContextFixture ? "あ" : nil)
        field.accessibilityIdentifier = "external-input-field"
        field.accessibilityLabel = "テスト用一行入力"
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(textFieldContentChanged), for: .editingChanged)
        self.field = field
        fieldState.accessibilityIdentifier = "external-input-field-state"
        fieldState.isAccessibilityElement = true
        let selectionStatus = UILabel()
        selectionStatus.accessibilityIdentifier = "external-input-test-selection-status"
        selectionStatus.text = "not-set"
        forwardDeleteField = field
        forwardDeleteSelectionStatus = selectionStatus
        let otherFieldLabel = UILabel()
        otherFieldLabel.text = "UITextField (別文脈)"
        let otherField = UITextField()
        otherField.borderStyle = .roundedRect
        otherField.text = "別"
        otherField.accessibilityIdentifier = "external-input-other-field"
        otherField.accessibilityLabel = "別文脈テスト入力"
        otherField.autocorrectionType = .no
        otherField.spellCheckingType = .no
        otherField.delegate = self
        self.otherField = otherField
        otherFieldState.accessibilityIdentifier = "external-input-other-field-state"
        otherFieldState.isAccessibilityElement = true
        let matchingContextLabel = UILabel()
        matchingContextLabel.text = "UITextField (同文脈)"
        let matchingContextField = UITextField()
        matchingContextField.borderStyle = .roundedRect
        matchingContextField.text = usesIdenticalContextFixture ? "あい" : "あ"
        matchingContextField.accessibilityIdentifier = "external-input-matching-context-field"
        matchingContextField.accessibilityLabel = "同文脈テスト入力"
        matchingContextField.autocorrectionType = .no
        matchingContextField.spellCheckingType = .no
        matchingContextField.delegate = self
        self.matchingContextField = matchingContextField
        matchingContextFieldState.accessibilityIdentifier = "external-input-matching-context-field-state"
        matchingContextFieldState.isAccessibilityElement = true
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
        lifecycleState.accessibilityIdentifier = "external-input-lifecycle-state"
        lifecycleState.isAccessibilityElement = true
        lifecycleState.text = "replacement-mark-observed=false"
        let stack = UIStackView(arrangedSubviews: [title, note, fieldLabel, field, fieldState,
                                                   otherFieldLabel, otherField, otherFieldState,
                                                   matchingContextLabel, matchingContextField, matchingContextFieldState,
                                                   textLabel, text, textState, lifecycleState])
        if let forwardDeleteScenario {
            let positionButton = UIButton(type: .system)
            positionButton.setTitle("Set forward-delete test selection", for: .normal)
            positionButton.accessibilityIdentifier = "external-input-test-set-selection"
            positionButton.addAction(UIAction { [weak self, weak field] _ in
                guard let field, field.becomeFirstResponder(),
                      let start = field.position(from: field.beginningOfDocument,
                                                 offset: forwardDeleteScenario.selectionStart),
                      let end = field.position(from: start,
                                               offset: forwardDeleteScenario.selectionLength),
                      let range = field.textRange(from: start, to: end) else { return }
                field.selectedTextRange = range
                self?.updateForwardDeleteSelectionStatus()
            }, for: .touchUpInside)
            stack.insertArrangedSubview(positionButton, at: 2)
            stack.insertArrangedSubview(selectionStatus, at: 3)
        }
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 36),
            otherField.heightAnchor.constraint(equalToConstant: 36),
            matchingContextField.heightAnchor.constraint(equalToConstant: 36),
            text.heightAnchor.constraint(equalToConstant: 64)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(recordDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        fieldState.snapshot = { [weak self] in self.map { $0.sampledState(of: $0.field) } ?? "unavailable" }
        otherFieldState.snapshot = { [weak self] in self.map { $0.sampledState(of: $0.otherField) } ?? "unavailable" }
        matchingContextFieldState.snapshot = { [weak self] in self.map { $0.sampledState(of: $0.matchingContextField) } ?? "unavailable" }
        textState.snapshot = { [weak self] in self.map { $0.sampledState(of: $0.text) } ?? "unavailable" }
        refreshInputState()
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        recordHostEvent("field-selection")
        refreshInputState()
        updateForwardDeleteSelectionStatus()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        recordHostEvent("view-selection")
        refreshInputState()
    }

    func textViewDidChange(_ textView: UITextView) {
        recordHostEvent("view-text-changed")
        refreshInputState()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === field {
            // Start a fresh diagnostic window for this original-field editing
            // session so a relaunch/reused host cannot expose a stale marker.
            originalFieldEndEditingBoundary = nil
            firstOriginalUnmarkedCallbackAfterEndEditing = nil
        }
        if textField === matchingContextField || (usesIdenticalContextFixture && textField === field) {
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
        recordHostEvent("field-begin-editing")
        refreshInputState()
    }

    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        recordHostEvent("field-should-end-editing", originalFieldEndEditingBoundary: textField === field)
        return true
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        recordHostEvent("field-should-begin-editing")
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        recordHostEvent("field-end-editing")
        refreshInputState()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        recordHostEvent("view-begin-editing")
        refreshInputState()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        recordHostEvent("view-end-editing")
        refreshInputState()
    }

    @objc private func refreshInputState() {
        fieldState.text = state(of: field)
        otherFieldState.text = state(of: otherField)
        matchingContextFieldState.text = state(of: matchingContextField)
        textState.text = state(of: text)
    }

    @objc private func recordWillResignActive() {
        recordHostEvent("will-resign-active")
    }

    @objc private func recordDidBecomeActive() {
        recordHostEvent("did-become-active")
        refreshInputState()
    }

    @objc private func textFieldContentChanged(_ textField: UITextField) {
        recordHostEvent("field-text-changed")
        refreshInputState()
    }

    private func recordHostEvent(_ name: String, originalFieldEndEditingBoundary: Bool = false) {
        // This test-only trace stores editor state flags and selection lengths,
        // coarse content classes, and monotonic order; never input text.
        hostEventSequence += 1
        let uptime = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        if originalFieldEndEditingBoundary, self.originalFieldEndEditingBoundary == nil {
            self.originalFieldEndEditingBoundary = "#\(hostEventSequence)@\(uptime)"
        } else if self.originalFieldEndEditingBoundary != nil,
                  firstOriginalUnmarkedCallbackAfterEndEditing == nil,
                  let field,
                  field.markedTextRange == nil {
            // Keep the first post-boundary callback that observes the old field
            // as unmarked, even if its event later ages out of the bounded trace.
            firstOriginalUnmarkedCallbackAfterEndEditing = "#\(hostEventSequence)@\(uptime):\(name)"
        }
        if otherField?.markedTextRange != nil {
            replacementMarkSeen = true
        }
        let snapshot = "#\(hostEventSequence)@\(uptime):\(name){field=\(editState(of: field));view=\(editState(of: text));other=\(editState(of: otherField));matching=\(editState(of: matchingContextField))}"
        lifecycleEvents.append(snapshot)
        if lifecycleEvents.count > 24 { lifecycleEvents.removeFirst() }
        // This sticky boolean survives ring-buffer eviction while still exposing
        // only callback-observed state, never text or document identity.
        let boundary = self.originalFieldEndEditingBoundary ?? "missing"
        let oldFieldClear = firstOriginalUnmarkedCallbackAfterEndEditing ?? "missing"
        lifecycleState.text = lifecycleEvents.joined(separator: "|") +
            "|original-should-end=\(boundary)" +
            "|original-unmarked-after-should-end=\(oldFieldClear)" +
            "|replacement-mark-observed=\(replacementMarkSeen)"
    }

    private func editState(of input: UITextInput?) -> String {
        guard let input else { return "available=false" }
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
        let markLength = input.markedTextRange.map { input.offset(from: $0.start, to: $0.end) }
        let selection = input.selectedTextRange.map {
            input.offset(from: input.beginningOfDocument, to: $0.start)
        }
        let isFirstResponder = (input as? UIView)?.isFirstResponder ?? false
        return "available=true;content=\(contentClass);marked=\(markLength != nil);markLength=\(markLength.map(String.init) ?? "-");selection=\(selection.map(String.init) ?? "-");firstResponder=\(isFirstResponder)"
    }

    private func sampledState(of input: UITextInput?) -> String {
        state(of: input) + ";sampleUptime=" + String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
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
        let firstResponder = (input as? UIView)?.isFirstResponder ?? false
        return "content=\(contentClass);marked=\(marked != nil);markedUTF16=\(markedLength.map(String.init) ?? "-");selectionUTF16=\(selection.map(String.init) ?? "-");firstResponder=\(firstResponder);inputLanguage=\((input as? UIResponder)?.textInputMode?.primaryLanguage ?? "-")"
    }
    private func updateForwardDeleteSelectionStatus() {
        guard let field = forwardDeleteField, let selectionStatus = forwardDeleteSelectionStatus,
              let selection = field.selectedTextRange else {
            forwardDeleteSelectionStatus?.text = "unavailable"
            return
        }
        let start = field.offset(from: field.beginningOfDocument, to: selection.start)
        let length = field.offset(from: selection.start, to: selection.end)
        selectionStatus.text = "\(start):\(length)"
    }
}

private struct ForwardDeleteScenario {
    let text: String
    let selectionStart: Int
    let selectionLength: Int

    init?(arguments: [String]) {
        guard arguments.contains("--sumire-forward-delete-test"),
              let text = Self.value(for: "--sumire-forward-delete-text", in: arguments),
              let start = Self.value(for: "--sumire-forward-delete-start", in: arguments).flatMap(Int.init),
              let length = Self.value(for: "--sumire-forward-delete-length", in: arguments).flatMap(Int.init),
              start >= 0, length >= 0 else { return nil }
        self.text = text
        selectionStart = start
        selectionLength = length
    }

    private static func value(for key: String, in arguments: [String]) -> String? {
        let prefix = key + "="
        return arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
}
