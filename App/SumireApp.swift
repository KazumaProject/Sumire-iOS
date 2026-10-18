import SwiftUI
import UIKit
import SumireCore

@main
struct SumireApp: App {
    @StateObject private var personalLibrary = PersonalLibrary()
    var body: some Scene { WindowGroup { HomeView(personalLibrary: personalLibrary) } }
}

struct HomeView: View {
    @ObservedObject var personalLibrary: PersonalLibrary
    @State private var showPersonal = false
    @State private var confirmClearLearning = false
    @State private var learningNotice: String?
    @State private var clearingLearning = false
    @AppStorage("learningEnabled", store: KeyboardSettings.appDefaults) private var learningEnabled = true
    @AppStorage("learnFirstCandidate", store: KeyboardSettings.appDefaults) private var learnFirstCandidate = false
    @State private var showRomaji = false
    @State private var showCustomKeyboard = false
    @State private var showBackup = false
    @AppStorage(DeletionBoundary.settingsKey, store: KeyboardSettings.appDefaults) private var deleteBoundarySymbols = DeletionBoundary.defaultSymbols
    @AppStorage("theme.hue", store: KeyboardSettings.appDefaults) private var hue = 0.73
    @AppStorage("theme.mode", store: KeyboardSettings.appDefaults) private var colorMode = KeyboardColorMode.system.rawValue
    @State private var custom = true
    @State private var showDictionaries = false
    @State private var showKeyAppearance = false
    @State private var showKeyboardSelection = false
    @State private var appearanceRevision = 0
    @AppStorage("englishReadingEnabled", store: KeyboardSettings.appDefaults) private var englishReadingEnabled = true
    @AppStorage("categoryMask", store: KeyboardSettings.appDefaults) private var categoryMask = 0
    @AppStorage("candidateRowCount", store: KeyboardSettings.appDefaults) private var candidateRowCount = 1
    @AppStorage("clipboardAutomaticPreview", store: KeyboardSettings.appDefaults) private var clipboardAutomaticPreview = false
    @AppStorage("liveConversion", store: KeyboardSettings.appDefaults) private var liveConversion = false
    @AppStorage("omissionSearch", store: KeyboardSettings.appDefaults) private var omissionSearch = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Sumire の入力面を試す", isOn: $custom)
                Picker("候補欄の段数", selection: $candidateRowCount) {
                    ForEach(1...3, id: \.self) { Text("\($0)段").tag($0) }
                }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(uiImage: UIImage(named: "SumireLogo.png") ?? UIImage())
                                .resizable().scaledToFit().frame(width: 48, height: 48)
                                .accessibilityHidden(true)
                            Text("入力基盤の実機検証").font(.title2.bold())
                        }
                        Text("C++辞書変換の検証版です。かなを入力して候補を選ぶか、改行キーで読みを確定します。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(KeyboardSettings.sharedDefaults == nil
                             ? "共有領域を利用できません。入力設定はこのアプリ内に保存します。"
                             : "入力設定は共有領域に保存します。拡張での反映にはフルアクセスが必要です。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let notice = personalLibrary.notice { Text(notice).font(.caption).foregroundStyle(.red) }
                        Button("ユーザー辞書・定型文") { showPersonal = true }
                        Button("辞書のバックアップ") { showBackup = true }
                        Button("Custom Keyboard") { showCustomKeyboard = true }
                        Button("カスタムローマ字") { showRomaji = true }
                        Button("キーボードの選択・順序") { showKeyboardSelection = true }
                        Button("キー・文字サイズ") { showKeyAppearance = true }
                        NavigationLink("ライセンス・出典") { LicenseSettingsView() }
                        Button("分類辞書（\(categoryMask.nonzeroBitCount)/30）") { showDictionaries = true }
                        Toggle("コピー内容を変換欄に自動表示", isOn: $clipboardAutomaticPreview)
                        Text("ONでは文字・画像の内容を読み取るため、iOSがペーストの許可を求めることがあります。OFFでも種類を検知し、貼り付けボタンを表示します。画像の挿入は入力先の貼り付けメニューを使用します。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("削除キー左フリックの区切り記号", text: $deleteBoundarySymbols)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("空白・改行も区切りになります。直前が区切り記号なら、その1文字だけを削除します。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("ライブ変換", isOn: $liveConversion)
                        Toggle("修飾キー省略", isOn: $omissionSearch)
                        Toggle("変換を学習", isOn: $learningEnabled)
                        Toggle("第1候補も学習", isOn: $learnFirstCandidate).disabled(!learningEnabled)
                        Button("学習データをすべて削除", role: .destructive) { confirmClearLearning = true }.disabled(clearingLearning)
                        if let learningNotice { Text(learningNotice).font(.caption) }
                        Picker("キーボードの配色", selection: $colorMode) {
                            ForEach(KeyboardColorMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }.accessibilityIdentifier("keyboardColorMode")
                        HStack {
                            Text("テーマ色")
                            Slider(value: $hue, in: 0...1)
                                .accessibilityLabel("テーマの色相")
                        }
                        Text("OFF にすると標準キーボードを比較できます。配色は保存され、キーボードの次回表示にも反映します。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("キーボード拡張は、設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → Sumire で有効化します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 310)
                InputHarness(preserveCompositionForAppearance: showKeyAppearance, clipboardAutomaticPreview: clipboardAutomaticPreview, personalLexicon: personalLibrary.lexicon, learningEnabled: learningEnabled, learnFirstCandidate: learnFirstCandidate, appearanceRevision: appearanceRevision, hue: hue, colorMode: KeyboardColorMode(rawValue: colorMode) ?? .system, custom: custom, candidateRowCount: candidateRowCount, liveConversion: liveConversion, omissionSearch: omissionSearch, englishReadingEnabled: englishReadingEnabled, categoryMask: UInt32(categoryMask & 0x3fff_ffff))
                    .frame(minHeight: 80, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Sumire")
            .confirmationDialog("学習データをすべて削除しますか？", isPresented: $confirmClearLearning, titleVisibility: .visible) {
                Button("削除する", role: .destructive) {
                    clearingLearning = true
                    learningNotice = nil
                    let url = PersonalDataLocation.learningURL(allowShared: true)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let message: String
                        do {
                            if FileManager.default.fileExists(atPath: url.path) { try LearningStore(url: url).clear() }
                            message = "学習データを削除しました"
                        } catch { message = error.localizedDescription }
                        DispatchQueue.main.async {
                            learningNotice = message; clearingLearning = false; appearanceRevision += 1
                        }
                    }
                }
            }
            .sheet(isPresented: $showBackup) { PersonalBackupSettings(library: personalLibrary, onRestore: { appearanceRevision += 1 }) }
            .sheet(isPresented: $showCustomKeyboard, onDismiss: { appearanceRevision += 1 }) { CustomKeyboardSettings() }
            .sheet(isPresented: $showRomaji, onDismiss: { appearanceRevision += 1 }) { RomajiSettings() }
            .sheet(isPresented: $showPersonal) { PersonalDictionarySettings(library: personalLibrary) }
            .sheet(isPresented: $showKeyboardSelection, onDismiss: { appearanceRevision += 1 }) { KeyboardSelectionSettings() }
            .sheet(isPresented: $showKeyAppearance, onDismiss: { appearanceRevision += 1 }) { KeyAppearanceSettings() }
            .sheet(isPresented: $showDictionaries) { DictionarySettings(categoryMask: $categoryMask, englishReadingEnabled: $englishReadingEnabled) }
        }
    }
}

struct InputHarness: UIViewRepresentable {
    let preserveCompositionForAppearance: Bool
    let clipboardAutomaticPreview: Bool
    let personalLexicon: PersonalLexicon
    let learningEnabled: Bool
    let learnFirstCandidate: Bool
    let appearanceRevision: Int
    let hue: Double
    let colorMode: KeyboardColorMode
    let custom: Bool
    let candidateRowCount: Int
    let liveConversion: Bool
    let omissionSearch: Bool
    let englishReadingEnabled: Bool
    let categoryMask: UInt32
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        #if DEBUG
        // Device UI-test runners cannot write the system pasteboard in the background.
        // Seed only explicit test fixtures in the foreground harness, never in Release.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--clipboard-test-text") {
            UIPasteboard.general.setItems([["public.utf8-plain-text": "すみれ clipboard 🪻"]], options: [.localOnly: true])
        } else if arguments.contains("--clipboard-test-image") {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
                UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            }
            if let data = image.pngData() { UIPasteboard.general.setItems([["public.png": data]], options: [.localOnly: true]) }
        }
        #endif
        let text = UITextView()
        text.font = .preferredFont(forTextStyle: .body)
        text.backgroundColor = .secondarySystemBackground
        text.layer.cornerRadius = 12
        text.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        text.accessibilityLabel = "入力テスト"
        let coordinator = context.coordinator
        let surface = coordinator.surface
        coordinator.textView = text
        surface.settingsDefaults = KeyboardSettings.appDefaults
        surface.onHeightChange = { [weak text] _ in
            text?.inputView?.invalidateIntrinsicContentSize()
            text?.inputView?.superview?.setNeedsLayout()
        }
        surface.reloadSizing()
        text.delegate = coordinator
        surface.beforeInput = { [weak coordinator] in coordinator?.validateContext() }
        surface.insert = { [weak text, weak coordinator] value in
            coordinator?.perform { text?.insertText(value) }
        }
        surface.delete = { [weak text, weak coordinator] in
            coordinator?.perform { text?.deleteBackward() }
        }
        surface.deleteUntilBoundary = { [weak text, weak coordinator] in
            coordinator?.perform {
                guard let text else { return }
                let symbols = KeyboardSettings.appDefaults.string(forKey: DeletionBoundary.settingsKey) ?? DeletionBoundary.defaultSymbols
                if text.selectedRange.length > 0 { text.deleteBackward(); return }
                guard let range = Range(NSRange(location: 0, length: text.selectedRange.location), in: text.text) else { return }
                let count = DeletionBoundary.backwardCount(context: String(text.text[range]), symbols: symbols)
                for _ in 0..<count { text.deleteBackward() }
            }
        }
        let mark: (String, NSRange) -> Void = { [weak text, weak coordinator] value, selection in
            coordinator?.perform {
                guard let text else { return }
                text.setMarkedText(value, selectedRange: selection)
                if value.isEmpty { text.unmarkText() }
            }
        }
        surface.updateMarkedSelection = mark
        surface.updateMarkedText = { mark($0, NSRange(location: $0.utf16.count, length: 0)) }
        surface.commitMarkedText = { [weak text, weak coordinator] value in
            coordinator?.perform {
                guard let text else { return }
                text.insertText(value)
            }
        }
        surface.moveCursorLeft = { [weak text, weak coordinator] in
            coordinator?.perform {
                guard let text, text.selectedRange.location > 0 else { return }
                let range = (text.text as NSString).rangeOfComposedCharacterSequence(at: text.selectedRange.location - 1)
                text.selectedRange = NSRange(location: range.location, length: 0)
            }
        }
        surface.moveCursorRight = { [weak text, weak coordinator] in
            coordinator?.perform {
                guard let text, text.selectedRange.location < (text.text as NSString).length else { return }
                let range = (text.text as NSString).rangeOfComposedCharacterSequence(at: text.selectedRange.location)
                text.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
            }
        }
        surface.nextKeyboard = { [weak text] in text?.resignFirstResponder() }
        return text
    }
    func updateUIView(_ text: UITextView, context: Context) {
        let surface = context.coordinator.surface
        context.coordinator.prepareAppearanceEditing(preserveCompositionForAppearance)
        surface.settingsDefaults = KeyboardSettings.appDefaults
        if context.coordinator.settingsRevision != appearanceRevision {
            surface.reloadRomaji()
            surface.reloadCustomLayouts()
            surface.reloadLearningResults()
            context.coordinator.settingsRevision = appearanceRevision
        }
        surface.reloadAppearance()
        surface.personalLexicon = personalLexicon
        surface.configureLearning(url: learningEnabled ? PersonalDataLocation.learningURL(allowShared: true) : nil)
        surface.learnFirstCandidate = learnFirstCandidate
        let rows = min(3, max(1, candidateRowCount))
        if surface.candidateRowCount != rows {
            surface.candidateRowCount = rows
            text.reloadInputViews()
        }
        surface.candidateBar.automaticallyPreviewClipboard = clipboardAutomaticPreview
        surface.liveConversion = liveConversion
        surface.omissionSearch = omissionSearch
        surface.englishReadingEnabled = englishReadingEnabled
        surface.categoryMask = categoryMask
        if surface.hue != CGFloat(hue) { surface.hue = CGFloat(hue) }
        surface.colorMode = colorMode
        if (text.inputView != nil) != custom {
            if !custom { context.coordinator.perform { text.unmarkText() }; surface.invalidateComposition() }
            text.inputView = custom ? surface : nil
            text.reloadInputViews()
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var settingsRevision: Int?
        weak var textView: UITextView?
        private var appearanceMarkedRange: NSRange?
        private var appearanceText: String?
        private var preservingAppearance = false
        func prepareAppearanceEditing(_ active: Bool) {
            if active && !preservingAppearance, let textView, let marked = textView.markedTextRange {
                appearanceMarkedRange = NSRange(location: textView.offset(from: textView.beginningOfDocument, to: marked.start),
                    length: textView.offset(from: marked.start, to: marked.end))
                appearanceText = textView.text
            }
            preservingAppearance = active
        }
        private var changing = false
        private var expectedText = ""
        private var expectedSelection = NSRange(location: 0, length: 0)
        func perform(_ action: () -> Void) {
            changing = true
            action()
            expectedText = textView?.text ?? ""
            expectedSelection = textView?.selectedRange ?? NSRange(location: 0, length: 0)
            changing = false
        }
        func validateContext() {
            guard !changing, let textView else { return }
            if expectedText != textView.text || expectedSelection != textView.selectedRange {
                appearanceMarkedRange = nil; appearanceText = nil
                surface.invalidateComposition()
                expectedText = textView.text
                expectedSelection = textView.selectedRange
            }
        }
        func textViewDidChange(_ textView: UITextView) { validateContext() }
        func textViewDidChangeSelection(_ textView: UITextView) { validateContext() }
        func textViewDidEndEditing(_ textView: UITextView) {
            if !preservingAppearance || appearanceMarkedRange == nil { surface.invalidateComposition() }
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let range = appearanceMarkedRange, let original = appearanceText else { return }
            appearanceMarkedRange = nil; appearanceText = nil
            guard textView.text == original, NSMaxRange(range) <= (original as NSString).length else {
                surface.invalidateComposition(); return
            }
            perform {
                textView.selectedRange = range
                let value = (original as NSString).substring(with: range)
                textView.setMarkedText(value, selectedRange: NSRange(location: value.utf16.count, length: 0))
            }
        }
        let surface = KeyboardSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 464))
    }
}
