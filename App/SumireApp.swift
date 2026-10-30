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
    @State private var confirmClearLearning = false
    @State private var learningNotice: String?
    @State private var clearingLearning = false
    @AppStorage("learningEnabled", store: KeyboardSettings.appDefaults) private var learningEnabled = true
    @AppStorage("learnFirstCandidate", store: KeyboardSettings.appDefaults) private var learnFirstCandidate = false
    @AppStorage("learnMixedSymbolsAndNumbers", store: KeyboardSettings.appDefaults) private var learnMixedSymbolsAndNumbers = true
    @AppStorage(DeletionBoundary.settingsKey, store: KeyboardSettings.appDefaults) private var deleteBoundarySymbols = DeletionBoundary.defaultSymbols
    @AppStorage("theme.hue", store: KeyboardSettings.appDefaults) private var hue = 0.73
    @AppStorage("theme.mode", store: KeyboardSettings.appDefaults) private var colorMode = KeyboardColorMode.system.rawValue
    @AppStorage("theme.saturation", store: KeyboardSettings.appDefaults) private var saturation = 0.5
    @AppStorage("theme.brightness", store: KeyboardSettings.appDefaults) private var brightness = 0.7
    @State private var custom = true
    @State private var appearanceRevision = 0
    @AppStorage(KotowazaSettings.enabledKey, store: KeyboardSettings.appDefaults) private var kotowazaEnabled = true
    @AppStorage("englishReadingEnabled", store: KeyboardSettings.appDefaults) private var englishReadingEnabled = true
    @AppStorage("categoryMask", store: KeyboardSettings.appDefaults) private var categoryMask = 0
    @AppStorage("candidateRowCount", store: KeyboardSettings.appDefaults) private var candidateRowCount = 1
    @AppStorage("clipboardAutomaticPreview", store: KeyboardSettings.appDefaults) private var clipboardAutomaticPreview = false
    @AppStorage("liveConversion", store: KeyboardSettings.appDefaults) private var liveConversion = false
    @AppStorage("omissionSearch", store: KeyboardSettings.appDefaults) private var omissionSearch = false
    @AppStorage("bunsetsuSeparation", store: KeyboardSettings.appDefaults) private var bunsetsuSeparation = false
    @AppStorage(JapanesePredictionSettings.lookaheadStorageKey, store: KeyboardSettings.appDefaults)
    private var predictionLookaheadCharacterCount = JapanesePredictionSettings.defaultLookaheadCharacterCount
    @AppStorage(JapanesePredictionSettings.aggressivenessStorageKey, store: KeyboardSettings.appDefaults)
    private var predictionAggressivenessRawValue = JapanesePredictionAggressiveness.standard.rawValue
    @AppStorage(TextMacroCandidateSettings.enabledKey, store: KeyboardSettings.appDefaults) private var textMacroCandidatesEnabled = true
    @AppStorage(LegacyTemplateSettings.enabledKey, store: KeyboardSettings.appDefaults) private var legacyTemplatesEnabled = true
    @AppStorage(UserDictionaryPredictionSettings.enabledKey, store: KeyboardSettings.appDefaults) private var userDictionaryPredictionEnabled = true
    @AppStorage(UserDictionaryPredictionSettings.minimumInputLengthKey, store: KeyboardSettings.appDefaults) private var userDictionaryPredictionMinimumInputLength = 2
    @AppStorage(UserDictionaryPredictionSettings.candidateLimitKey, store: KeyboardSettings.appDefaults) private var userDictionaryPredictionCandidateLimit = 4
    @AppStorage(LearnedPredictionSettings.enabledKey, store: KeyboardSettings.appDefaults) private var learnedPredictionEnabled = false
    @AppStorage(LearnedPredictionSettings.minimumInputLengthKey, store: KeyboardSettings.appDefaults) private var learnedPredictionMinimumInputLength = 4
    @AppStorage(LearnedPredictionSettings.candidateLimitKey, store: KeyboardSettings.appDefaults) private var learnedPredictionCandidateLimit = 4
    @State private var destination: SettingsDestination?
    @State private var showPreview = false
    var body: some View {
        NavigationStack {
            SettingsDashboardView(sharingAvailable: KeyboardSettings.sharedDefaults != nil, hasDataNotice: personalLibrary.notice != nil,
                                  openPreview: { showPreview = true }, open: { destination = $0 })
                .navigationDestination(isPresented: $showPreview) { preview }
        }
        .tint(SettingsBrand.purple)
        .sheet(item: $destination, onDismiss: { appearanceRevision += 1 }) { item in
            destinationView(item)
        }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Sumire の入力面を試す", isOn: $custom)
                    Picker("候補欄の段数", selection: $candidateRowCount) {
                        ForEach(1...3, id: \.self) { Text("\($0)段").tag($0) }
                    }.pickerStyle(.segmented)
                    DisclosureGroup("入力オプション") {
                        Toggle("ライブ変換", isOn: $liveConversion)
                        Toggle("修飾キー省略", isOn: $omissionSearch)
                        Toggle("文節ごとに変換", isOn: $bunsetsuSeparation)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .frame(maxHeight: 165)
            InputHarness(preserveCompositionForAppearance: destination != nil, clipboardAutomaticPreview: clipboardAutomaticPreview, personalLexicon: personalLibrary.lexicon, learningEnabled: learningEnabled, learnFirstCandidate: learnFirstCandidate, learnMixedSymbolsAndNumbers: learnMixedSymbolsAndNumbers, appearanceRevision: appearanceRevision, hue: hue, saturation: saturation, brightness: brightness, colorMode: KeyboardColorMode(rawValue: colorMode) ?? .system, custom: custom, candidateRowCount: candidateRowCount, liveConversion: liveConversion, omissionSearch: omissionSearch, bunsetsuSeparation: bunsetsuSeparation, englishReadingEnabled: englishReadingEnabled, kotowazaEnabled: kotowazaEnabled, categoryMask: UInt32(categoryMask & 0x3fff_ffff), categoryIDs: DictionaryCategoryCatalog.selection(defaults: KeyboardSettings.appDefaults), predictionSettings: predictionSettings, learnedPredictionSettings: .init(enabled: learnedPredictionEnabled, minimumInputLength: learnedPredictionMinimumInputLength, candidateLimit: learnedPredictionCandidateLimit), userDictionaryPredictionSettings: .init(enabled: userDictionaryPredictionEnabled, minimumInputLength: userDictionaryPredictionMinimumInputLength, candidateLimit: userDictionaryPredictionCandidateLimit), legacyTemplatesEnabled: legacyTemplatesEnabled, textMacroCandidatesEnabled: textMacroCandidatesEnabled)
                .frame(minHeight: 80, maxHeight: .infinity).padding(.horizontal, 16)
        }
        .navigationTitle("試し書き").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SettingsCategory.allCases) { category in
                        Section(category.title) {
                            ForEach(SettingsDestination.allCases.filter { $0.category == category }) { item in
                                Button(item.title, systemImage: item.icon) { destination = item }
                                    .accessibilityLabel(item.title)
                            }
                        }
                    }
                } label: { Label("設定", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("preview-settings").accessibilityLabel("設定")
            }
        }
    }

    @ViewBuilder private func destinationView(_ item: SettingsDestination) -> some View {
        switch item {
        case .keyboards: KeyboardSelectionSettings()
        case .toolbar: KeyboardToolbarSettingsView()
        case .customKeyboard: CustomKeyboardSettings()
        case .romaji: RomajiSettings()
        case .specialKeys: SpecialKeySettingsView()
        case .physicalShortcuts: PhysicalKeyboardShortcutSettingsView()
        case .flickStyle: detail(title: item.title) { FlickStyleSettingsView() }
        case .touchFeedback: detail(title: item.title) { TouchFeedbackSettingsView() }
        case .appearance: KeyAppearanceSettings()
        case .theme: detail(title: item.title) { ThemeSettingsView() }
        case .dictionaryBrowser: detail(title: item.title) { DictionaryBrowserView() }
        case .personalDictionary: PersonalDictionarySettings(library: personalLibrary)
        case .textMacros: PersonalTextMacroSettings(library: personalLibrary)
        case .dictionaries: DictionarySettings(categoryMask: $categoryMask, englishReadingEnabled: $englishReadingEnabled)
        case .symbols: SymbolKeyboardSettings()
        case .backup: PersonalBackupSettings(library: personalLibrary, onRestore: { appearanceRevision += 1 })
        case .licenses: detail(title: item.title) { LicenseSettingsView() }
        case .conversion: detail(title: item.title) {
            Form {
                Section {
                    Toggle("ライブ変換", isOn: $liveConversion)
                    Toggle("修飾キー省略", isOn: $omissionSearch)
                    Toggle("文節ごとに変換", isOn: $bunsetsuSeparation)
                } header: { Text("変換") } footer: {
                    Text("ONにすると、変換キーを押したときに文節を切り分けて先頭から候補を選べます。選んだ後も残りの読みは未確定のまま続きます。")
                }
                Section {
                    Picker("先読み文字数", selection: $predictionLookaheadCharacterCount) {
                        ForEach(JapanesePredictionSettings.lookaheadRange, id: \.self) { count in
                            Text("\(count)文字").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("prediction-lookahead")
                    Picker("予測の積極性", selection: $predictionAggressivenessRawValue) {
                        ForEach(JapanesePredictionAggressiveness.allCases, id: \.rawValue) { value in
                            Text(value.title).tag(value.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("prediction-aggressiveness")
                } header: { Text("辞書の補完") } footer: {
                    Text("入力済みの読みに追加する先読みの長さと、補完候補の順位を調整します。標準は Android の初期設定です。")
                }
                Section {
                    TextField("削除キー左フリックの区切り記号", text: $deleteBoundarySymbols)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("削除の区切り") } footer: {
                    Text("空白・改行も区切りになります。直前が区切り記号なら、その1文字だけを削除します。")
                }
            }
        }
        case .candidates: detail(title: item.title) {
            Form {
                Section {
                    Picker("候補欄の段数", selection: $candidateRowCount) {
                        ForEach(1...3, id: \.self) { Text("\($0)段").tag($0) }
                    }.pickerStyle(.segmented)
                } footer: { Text("段数を増やすと候補欄が高くなります。通常のキーの大きさは変わりません。狭い画面では使える高さに合わせて表示します。") }
                Section { Button("試し書きで確かめる") { destination = nil; showPreview = true } }
            }
        }
        case .learning: detail(title: item.title) {
            Form {
                Section {
                    Toggle("変換を学習", isOn: $learningEnabled)
                    Toggle("第1候補も学習", isOn: $learnFirstCandidate).disabled(!learningEnabled)
                    Toggle("記号・数字を含む日本語も学習", isOn: $learnMixedSymbolsAndNumbers).disabled(!learningEnabled)
                } footer: { Text("学習データは端末内に保存します。入力文字をネットワークへ送信しません。") }
                Section {
                    Toggle("学習辞書の補完候補", isOn: $learnedPredictionEnabled)
                        .disabled(!learningEnabled).accessibilityIdentifier("learned-prediction-enabled")
                    Stepper("補完を始める文字数: \(learnedPredictionMinimumInputLength)文字",
                            value: $learnedPredictionMinimumInputLength, in: 1...8)
                        .disabled(!learningEnabled || !learnedPredictionEnabled)
                        .accessibilityIdentifier("learned-prediction-minimum")
                    Stepper("学習辞書の候補数: \(learnedPredictionCandidateLimit)",
                            value: $learnedPredictionCandidateLimit, in: 1...8)
                        .disabled(!learningEnabled || !learnedPredictionEnabled)
                        .accessibilityIdentifier("learned-prediction-limit")
                } footer: { Text("入力の先頭に一致する学習辞書の候補を表示します。初期状態はOFFです。") }
                Section {
                    Button("学習データをすべて削除", role: .destructive) { confirmClearLearning = true }.disabled(clearingLearning)
                    if let learningNotice { Text(learningNotice).font(.footnote) }
                }
            }
            .confirmationDialog("学習データをすべて削除しますか？", isPresented: $confirmClearLearning, titleVisibility: .visible) {
                Button("削除する", role: .destructive, action: clearLearning)
            }
        }
        case .clipboard: detail(title: item.title) {
            Form {
                Section {
                    Toggle("コピー内容を変換欄に自動表示", isOn: $clipboardAutomaticPreview)
                } footer: { Text("ONでは文字・画像の内容を読み取るため、iOSがペーストの許可を求めることがあります。OFFでも種類を検知し、貼り付けボタンを表示します。画像の挿入は入力先の貼り付けメニューを使用します。") }
                Section { Text("履歴の保存と削除は「記号・クリップボード」で設定できます。") }
            }
        }
        case .setup: detail(title: item.title) {
            Form {
                Section("設定の保存先") {
                    Text(KeyboardSettings.sharedDefaults == nil
                         ? "共有領域にアクセスできません。設定はこのアプリ内に保存しています。キーボード拡張への設定共有はまだ成立していません。"
                         : "本体アプリから共有領域にアクセスできます。この表示だけではキーボード拡張での読み込みを確認できません。入力先で設定の反映を確認してください。")
                        .accessibilityIdentifier("sharing-status-detail")
                    if KeyboardSettings.sharedDefaults == nil {
                        Text("開発用ビルドではApp Groupsの権限と署名プロファイルの設定が必要です。このアプリから署名の設定を変更することはできません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("キーボードを有効にする") {
                    Text("iOSの「設定」→「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」からSumireを選びます。")
                    Text("入力中は地球儀キーからSumireへ切り替えます。")
                }
                Section("オフラインで使えます") {
                    Text("入力文字をネットワークに送信する機能はありません。フルアクセスをOFFのまま基本入力を利用できます。設定共有の署名状態は上の項目で確認できます。")
                }
                if let notice = personalLibrary.notice { Section("データの状態") { Text(notice).foregroundStyle(.secondary) } }
            }
        }
        }
    }

    private var predictionSettings: JapanesePredictionSettings {
        JapanesePredictionSettings(
            lookaheadCharacterCount: predictionLookaheadCharacterCount,
            aggressiveness: JapanesePredictionAggressiveness(rawValue: predictionAggressivenessRawValue) ?? .standard)
    }

    private func detail<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { destination = nil } } }
        }
    }

    private func clearLearning() {
        clearingLearning = true; learningNotice = nil
        let url = PersonalDataLocation.learningURL(allowShared: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                if FileManager.default.fileExists(atPath: url.path) { try LearningStore(url: url).clear() }
                KeyboardSettings.appDefaults.set(UUID().uuidString, forKey: "learning.resetToken")
                message = "本体の学習データを削除しました。キーボード側は次回表示時に削除します。"
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                learningNotice = message; clearingLearning = false; appearanceRevision += 1
            }
        }
    }
}

struct InputHarness: UIViewRepresentable {
    let preserveCompositionForAppearance: Bool
    let clipboardAutomaticPreview: Bool
    let personalLexicon: PersonalLexicon
    let learningEnabled: Bool
    let learnFirstCandidate: Bool
    let learnMixedSymbolsAndNumbers: Bool
    let appearanceRevision: Int
    let hue: Double
    let saturation: Double
    let brightness: Double
    let colorMode: KeyboardColorMode
    let custom: Bool
    let candidateRowCount: Int
    let liveConversion: Bool
    let omissionSearch: Bool
    let bunsetsuSeparation: Bool
    let englishReadingEnabled: Bool
    var kotowazaEnabled = true
    let categoryMask: UInt32
    var categoryIDs: [String]? = nil
    var predictionSettings = JapanesePredictionSettings()
    var learnedPredictionSettings = LearnedPredictionSettings()
    var userDictionaryPredictionSettings = UserDictionaryPredictionSettings()
    var legacyTemplatesEnabled = true
    var textMacroCandidatesEnabled = true
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
        surface.configureClipboard(accessAllowed: true, allowShared: true)
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
        Self.configureForwardDelete(surface: surface, text: text, coordinator: coordinator)
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
        surface.finishMarkedText = { [weak text, weak coordinator] in
            coordinator?.perform { text?.unmarkText() }
        }
        surface.commitRawTextAndSpace = { [weak text, weak coordinator] left, tail in
            coordinator?.perform {
                guard let text else { return }
                RawSpaceCommit.apply(left: left, tail: tail,
                    setMarked: { text.setMarkedText($0, selectedRange: $1) },
                    unmark: { text.unmarkText() }, insert: { text.insertText($0) })
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
        surface.learnMixedSymbolsAndNumbers = learnMixedSymbolsAndNumbers
        let rows = min(3, max(1, candidateRowCount))
        if surface.candidateRowCount != rows {
            surface.candidateRowCount = rows
            text.reloadInputViews()
        }
        surface.candidateBar.automaticallyPreviewClipboard = clipboardAutomaticPreview
        surface.liveConversion = liveConversion
        surface.omissionSearch = omissionSearch
        surface.bunsetsuSeparation = bunsetsuSeparation
        surface.englishReadingEnabled = englishReadingEnabled
        surface.kotowazaEnabled = kotowazaEnabled
        surface.categoryIDs = categoryIDs
        surface.predictionSettings = predictionSettings
        surface.configureLearnedPrediction(settings: learnedPredictionSettings)
        surface.configureUserDictionaryPrediction(settings: userDictionaryPredictionSettings)
        surface.configureLegacyTemplates(enabled: legacyTemplatesEnabled)
        surface.configureTextMacroCandidates(enabled: textMacroCandidatesEnabled)
        surface.categoryMask = categoryMask
        if surface.hue != CGFloat(hue) { surface.hue = CGFloat(hue) }
        surface.saturation = CGFloat(saturation)
        surface.brightness = CGFloat(brightness)
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
        private var appearanceSelection: NSRange?
        private var preservingAppearance = false
        private func updateSelectionTestState() {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--composition-selection-test-state"), let textView else { return }
            let selected = textView.selectedRange
            let marked: String
            if let range = textView.markedTextRange {
                marked = "\(textView.offset(from: textView.beginningOfDocument, to: range.start)),\(textView.offset(from: range.start, to: range.end))"
            } else { marked = "nil" }
            // Public XCTest identifier exposes ranges and state only when the
            // focused regression test requests it. Never include input text.
            textView.accessibilityIdentifier = "composition-state:selected=\(selected.location),\(selected.length) marked=\(marked) composing=\(surface.hasComposition)"
            #endif
        }
        func prepareAppearanceEditing(_ active: Bool) {
            if active && !preservingAppearance {
                appearanceMarkedRange = nil; appearanceText = nil; appearanceSelection = nil
                if let textView, let marked = textView.markedTextRange {
                    let length = max(0, textView.offset(from: marked.start, to: marked.end))
                    appearanceMarkedRange = NSRange(location: textView.offset(from: textView.beginningOfDocument, to: marked.start), length: length)
                    appearanceText = textView.text
                    if let selected = textView.selectedTextRange {
                        let start = min(length, max(0, textView.offset(from: marked.start, to: selected.start)))
                        let end = min(length, max(start, textView.offset(from: marked.start, to: selected.end)))
                        appearanceSelection = NSRange(location: start, length: end - start)
                    } else {
                        appearanceSelection = NSRange(location: length, length: 0)
                    }
                }
            }
            preservingAppearance = active
        }
        private var changing = false
        private var expectedText = ""
        private var expectedSelection = NSRange(location: 0, length: 0)
        func perform(_ action: () -> Void) {
            let wasChanging = changing
            changing = true
            action()
            expectedText = textView?.text ?? ""
            expectedSelection = textView?.selectedRange ?? NSRange(location: 0, length: 0)
            changing = wasChanging
            updateSelectionTestState()
        }
        func validateContext() {
            guard !changing, let textView else { return }
            let textUnchanged = expectedText.utf16.elementsEqual((textView.text ?? "").utf16)
            if !textUnchanged || expectedSelection != textView.selectedRange {
                if textUnchanged, textView.selectedRange.length == 0,
                   let marked = textView.markedTextRange {
                    let start = textView.offset(from: textView.beginningOfDocument, to: marked.start)
                    let length = textView.offset(from: marked.start, to: marked.end)
                    let total = (textView.text as NSString).length
                    let caret = textView.selectedRange.location
                    if start >= 0, start <= total, length >= 0, length <= total - start,
                       caret >= start, caret <= start + length {
                        let value = (textView.text as NSString).substring(with: NSRange(location: start, length: length))
                        var accepted = false
                        perform {
                            accepted = surface.synchronizeCompositionSelection(markedText: value,
                                selection: NSRange(location: caret - start, length: 0))
                        }
                        if accepted { return }
                    }
                }
                appearanceMarkedRange = nil; appearanceText = nil; appearanceSelection = nil
                surface.invalidateComposition()
                expectedText = textView.text
                expectedSelection = textView.selectedRange
                updateSelectionTestState()
            }
        }
        func textViewDidChange(_ textView: UITextView) { validateContext() }
        func textViewDidChangeSelection(_ textView: UITextView) { validateContext() }
        func textViewDidEndEditing(_ textView: UITextView) {
            if !preservingAppearance || appearanceMarkedRange == nil { surface.invalidateComposition() }
            updateSelectionTestState()
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let range = appearanceMarkedRange, let original = appearanceText else { return }
            let savedSelection = appearanceSelection
            appearanceMarkedRange = nil; appearanceText = nil; appearanceSelection = nil
            let originalLength = (original as NSString).length
            guard (textView.text ?? "").utf16.elementsEqual(original.utf16), range.location >= 0, range.location <= originalLength,
                  range.length >= 0, range.length <= originalLength - range.location else {
                surface.invalidateComposition(); return
            }
            perform {
                textView.selectedRange = range
                let value = (original as NSString).substring(with: range)
                let count = value.utf16.count
                let start = min(count, max(0, savedSelection?.location ?? count))
                let length = min(count - start, max(0, savedSelection?.length ?? 0))
                textView.setMarkedText(value, selectedRange: NSRange(location: start, length: length))
            }
        }
        let surface = KeyboardSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 464))
    }

    static func deleteForward(in text: UITextView?) {
        guard let text else { return }
        let selection = text.selectedRange
        if selection.length > 0 {
            text.deleteBackward()
            return
        }
        let contents = text.text as NSString
        guard selection.location < contents.length else { return }
        let nextCharacter = contents.rangeOfComposedCharacterSequence(at: selection.location)
        guard nextCharacter.location == selection.location else { return }
        text.selectedRange = NSRange(location: NSMaxRange(nextCharacter), length: 0)
        text.deleteBackward()
    }

    static func configureForwardDelete(surface: KeyboardSurface, text: UITextView, coordinator: Coordinator) {
        surface.deleteForward = { [weak text, weak coordinator] in
            coordinator?.perform { deleteForward(in: text) }
        }
    }
}
