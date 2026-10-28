import SwiftUI
import UniformTypeIdentifiers
import SumireCore

private struct DictionaryImportOutcomeView: View {
    let outcome: DictionaryImportOutcome
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(outcome.succeeded ? "取り込み完了" : "取り込み失敗") {
                    Text(outcome.message)
                        .foregroundColor(outcome.succeeded ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dictionary-import-outcome-message")
                }
                if !outcome.convertedFiles.isEmpty {
                    Section("有効化した辞書") {
                        ForEach(outcome.convertedFiles, id: \.self) { Text($0) }
                    }
                }
                if !outcome.storedLegacyAggregateIDs.isEmpty {
                    Section("保存した旧分類集約辞書（未有効化）") {
                        ForEach(outcome.storedLegacyAggregateIDs, id: \.self) { Text($0) }
                    }
                }
                if !outcome.preservedUnclassifiedCategoryIDs.isEmpty {
                    Section("分類未判定の既存辞書（未有効化）") {
                        Text("旧世代の分類情報は判定できないため、内容を別領域に保持しています。現在のキーボード変換には使われません。正しい分類のZIPを選んで再取り込みしてください。")
                            .font(.caption)
                        ForEach(outcome.preservedUnclassifiedCategoryIDs, id: \.self) { Text($0) }
                    }
                }
                if !outcome.skippedGroups.isEmpty {
                    Section("不足項目などによりスキップ") {
                        ForEach(outcome.skippedGroups, id: \.self) { Text($0) }
                    }
                }
                if !outcome.diagnostics.isEmpty {
                    Section("確認事項") {
                        ForEach(Array(outcome.diagnostics.prefix(100).enumerated()), id: \.offset) { _, item in
                            Text(item).font(.footnote).textSelection(.enabled)
                        }
                        if outcome.diagnostics.count > 100 {
                            Text("ほか \(outcome.diagnostics.count - 100) 件")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("辞書の取り込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

private enum DictionaryArchiveImportMode: String, CaseIterable, Identifiable, Sendable {
    case releaseLeaf
    case legacyAggregate

    var id: String { rawValue }

    var categoryInterpretation: DictionarySourceArchiveConverter.CategoryInterpretation {
        switch self {
        case .releaseLeaf: .releaseLeaf
        case .legacyAggregate: .legacyAggregate
        }
    }

    var storeImportMode: DictionaryGenerationStore.ImportMode {
        switch self {
        case .releaseLeaf: .releaseLeaf
        case .legacyAggregate: .typedLegacyAggregate
        }
    }
}

struct DictionarySettings: View {
    @Binding var categoryMask: Int
    @Binding var englishReadingEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategories = DictionaryCategoryCatalog.selection(defaults: KeyboardSettings.appDefaults)
    @State private var importingArchive = false
    @State private var importInProgress = false
    @State private var importOutcome: DictionaryImportOutcome?
    @State private var archiveImportMode: DictionaryArchiveImportMode = .releaseLeaf

    static let names = ["address":"住所", "agreement":"条約・協定", "award":"賞", "character":"キャラクター",
                         "event":"出来事", "facility":"施設", "initiative":"事業・計画", "kampo":"漢方",
                         "lineage":"家系", "medical":"医学", "mythological_figure":"神話の人物", "organization":"組織",
                         "person":"人名", "place":"地名", "product":"製品", "station":"駅", "term":"用語",
                         "transport_route":"交通路線", "vehicle":"乗り物", "work_anime":"アニメ", "work_book":"書籍",
                         "work_film":"映画", "work_franchise":"作品シリーズ", "work_game":"ゲーム", "work_manga":"漫画",
                         "work_music":"音楽", "work_other":"その他の作品", "work_periodical":"定期刊行物",
                         "work_program":"番組", "work_stage":"舞台"]

    private var sharedDictionaryStoreAvailable: Bool {
        PersonalDataLocation.dictionaryGenerationStore(allowShared: true) != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("システム辞書は常に有効です。分類辞書は必要なものを選べます。")
                    Button("すべて有効") { saveCategories(DictionaryCategoryCatalog.ids) }
                    Button("分類辞書をすべて無効") { saveCategories([]) }
                    Text("旧作品・キャラクター設定は共通の対象層分類にも引き継がれます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("英単語読み辞書") {
                    Toggle("かなから英単語を表示", isOn: $englishReadingEnabled)
                    Text("学習済み・ユーザー辞書の英単語は、この設定とは別に表示されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("外部辞書") {
                    if sharedDictionaryStoreAvailable {
                        Button {
                            importingArchive = true
                        } label: {
                            Label("Android辞書ZIPを取り込む", systemImage: "archivebox")
                        }
                        .accessibilityIdentifier("dictionary-import-android-zip")
                        .disabled(importInProgress)

                        Picker("分類形式", selection: $archiveImportMode) {
                            Text("release個別分類").tag(DictionaryArchiveImportMode.releaseLeaf)
                            Text("旧Android集約分類").tag(DictionaryArchiveImportMode.legacyAggregate)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("dictionary-import-mode")
                        .disabled(importInProgress)

                        Text(archiveImportMode == .releaseLeaf
                             ? "個別分類IDとして辞書を取り込みます。"
                             : "旧Android分類を型付きで保存します。現行キーボードの変換にはまだ使われません。")
                            .font(.caption).foregroundStyle(.secondary)

                        if importInProgress {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("ZIPを検証し、辞書を変換しています…")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }

                        Text("選択したZIPを検証・変換し、ネイティブ辞書として共有領域に一括反映します。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("共有領域を利用できません", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("App Groupsの共有コンテナが見つからないため、取り込んだ辞書をキーボード拡張へ反映できません。共有設定が使えるビルドで再度お試しください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("分類辞書") {
                    ForEach(DictionaryCategoryCatalog.categories) { category in
                        Toggle(category.label, isOn: Binding(
                            get: { selectedCategories.contains(category.id) },
                            set: { enabled in
                                var selected = Set(selectedCategories)
                                if enabled { selected.insert(category.id) } else { selected.remove(category.id) }
                                saveCategories(Array(selected))
                            }))
                            .accessibilityIdentifier("category-" + category.id)
                    }
                }
            }
            .navigationTitle("辞書")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear(perform: seedUITestArchiveIfRequested)
            .fileImporter(isPresented: $importingArchive, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let archive = urls.first else {
                        importOutcome = .failure("選択したファイルを取得できませんでした")
                        return
                    }
                    startImport(archive, mode: archiveImportMode)
                case .failure(let error):
                    if (error as? CocoaError)?.code == .userCancelled { return }
                    importOutcome = .failure(error.localizedDescription)
                }
            }
            .sheet(item: $importOutcome) { outcome in
                DictionaryImportOutcomeView(outcome: outcome)
            }
        }
    }

    private func saveCategories(_ ids: [String]) {
        selectedCategories = DictionaryCategoryCatalog.normalize(ids)
        DictionaryCategoryCatalog.save(selectedCategories, defaults: KeyboardSettings.appDefaults)
        categoryMask = Int(DictionaryCategoryCatalog.legacyMask(for: selectedCategories))
    }

    private func seedUITestArchiveIfRequested() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let fixtureName: String
        let fixtureData: Data
        if arguments.contains("-seed-invalid-dictionary-import-zip") {
            fixtureName = "sumire-ui-invalid-dictionary.zip"
            fixtureData = Data("not a ZIP archive; intentionally malformed test fixture".utf8)
        } else if arguments.contains("-seed-valid-dictionary-import-zip"),
                  let encoded = ProcessInfo.processInfo.environment["SUMIRE_UI_DICTIONARY_ARCHIVE_BASE64"],
                  let decoded = Data(base64Encoded: encoded), decoded.count <= 1_048_576 {
            fixtureName = "sumire-ui-valid-dictionary.zip"
            fixtureData = decoded
        } else {
            return
        }

        try? fixtureData.write(to: documents.appendingPathComponent(fixtureName), options: .atomic)
#endif
    }

    private func startImport(_ archive: URL, mode: DictionaryArchiveImportMode) {
        guard let sharedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettings.groupIdentifier) else {
            importOutcome = .failure("App Groupsの共有コンテナを取得できません")
            return
        }
        guard archive.startAccessingSecurityScopedResource() else {
            importOutcome = .failure("選択したZIPを読み取る権限を取得できませんでした")
            return
        }
        importInProgress = true
        let categoryInterpretation = mode.categoryInterpretation
        let storeImportMode = mode.storeImportMode
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                defer { archive.stopAccessingSecurityScopedResource() }
                return DictionaryArchiveImporter.perform(
                    archive: archive,
                    sharedContainer: sharedContainer,
                    categoryInterpretation: categoryInterpretation,
                    storeImportMode: storeImportMode,
                    bundledSupport: ConversionService.bundledDictionary)
            }.value
            importOutcome = outcome
            importInProgress = false
        }
    }
}
