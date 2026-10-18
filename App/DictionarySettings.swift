import SwiftUI
import UniformTypeIdentifiers
import SumireCore

private struct DictionaryImportOutcome: Identifiable, Sendable {
    let id = UUID()
    let succeeded: Bool
    let message: String
    let convertedFiles: [String]
    let skippedGroups: [String]
    let diagnostics: [String]

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, message: message, convertedFiles: [], skippedGroups: [], diagnostics: [])
    }
}

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
                }
                if !outcome.convertedFiles.isEmpty {
                    Section("有効化した辞書") {
                        ForEach(outcome.convertedFiles, id: \.self) { Text($0) }
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

struct DictionarySettings: View {
    @Binding var categoryMask: Int
    @Binding var englishReadingEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var importingArchive = false
    @State private var importInProgress = false
    @State private var importOutcome: DictionaryImportOutcome?

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
                    Button("すべて有効") { categoryMask = 0x3fff_ffff }
                    Button("分類辞書をすべて無効") { categoryMask = 0 }
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
                        .disabled(importInProgress)

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
                    ForEach(0..<Int(sumire_category_count()), id: \.self) { index in
                        let id = String(cString: sumire_category_name(index))
                        Toggle(Self.names[id] ?? id, isOn: Binding(
                            get: { categoryMask & (1 << index) != 0 },
                            set: { enabled in
                                if enabled { categoryMask |= 1 << index }
                                else { categoryMask &= ~(1 << index) }
                            }))
                            .accessibilityIdentifier("category-" + id)
                    }
                }
            }
            .navigationTitle("辞書")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .fileImporter(isPresented: $importingArchive, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let archive = urls.first else {
                        importOutcome = .failure("選択したファイルを取得できませんでした")
                        return
                    }
                    startImport(archive)
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

    private func startImport(_ archive: URL) {
        guard let sharedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettings.groupIdentifier) else {
            importOutcome = .failure("App Groupsの共有コンテナを取得できません")
            return
        }
        importInProgress = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performImport(archive: archive, sharedContainer: sharedContainer)
            }.value
            importOutcome = outcome
            importInProgress = false
        }
    }

    nonisolated private static func performImport(archive: URL, sharedContainer: URL) -> DictionaryImportOutcome {
        guard archive.startAccessingSecurityScopedResource() else {
            return .failure("選択したZIPを読み取る権限を取得できませんでした")
        }
        defer { archive.stopAccessingSecurityScopedResource() }

        let store = DictionaryGenerationStore(
            directory: sharedContainer.appendingPathComponent("Sumire/Dictionaries", isDirectory: true))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sumire-dictionary-source-\(UUID().uuidString)", isDirectory: true)
        do {
            let report = try DictionarySourceArchiveConverter.convert(archiveAt: archive, into: staging)
            defer { try? FileManager.default.removeItem(at: report.outputDirectory) }

            var base: URL?
            let baseCandidates = store.loadCandidates().map(\.directory) + [ConversionService.bundledDictionary].compactMap { $0 }
            for candidate in baseCandidates {
                do {
                    try Self.validateNativeDictionaries(at: candidate)
                    base = candidate
                    break
                } catch { continue }
            }
            guard let base else {
                throw ImportError(message: "変換の基準となる辞書が見つかりません")
            }
            let files = Dictionary(uniqueKeysWithValues: report.convertedFiles.map {
                ($0, report.outputDirectory.appendingPathComponent($0))
            })
            let loaded = try store.publish(importedFiles: files, from: base) { directory in
                try Self.validateNativeDictionaries(at: directory)
            }
            return DictionaryImportOutcome(
                succeeded: true,
                message: "検証済みの辞書世代を有効化しました（\(loaded.generation)）。",
                convertedFiles: report.convertedFiles,
                skippedGroups: report.skippedGroups,
                diagnostics: report.diagnostics)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    nonisolated private static func validateNativeDictionaries(at directory: URL) throws {
        var engine: OpaquePointer?
        var error = [CChar](repeating: 0, count: 1024)
        let hasEnglish = FileManager.default.fileExists(atPath: directory.appendingPathComponent("english.sud").path)
        let hasEnglishReading = FileManager.default.fileExists(atPath: directory.appendingPathComponent("english_reading.sud").path)
        let flags: UInt32 = (hasEnglish ? 1 : 0) | (hasEnglishReading ? 2 : 0)
        let status = directory.path.withCString { path in
            sumire_engine_open_with_dictionaries(path, 0x3fff_ffff, flags, &engine, &error, error.count)
        }
        guard status == 0, let engine else {
            throw ImportError(message: String(cString: error))
        }
        sumire_engine_close(engine)
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
