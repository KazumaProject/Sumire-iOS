import SwiftUI
import UniformTypeIdentifiers
import SumireCore

private struct AndroidPersonalListDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw PersonalDataError("ファイルを読み込めません")
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PersonalDictionarySettings: View {
    @ObservedObject var library: PersonalLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var template = false
    @State private var editing: EditItem?
    @State private var choosingImportFormat = false
    @State private var importing = false
    @State private var importFormat: ImportFormat = .androidBackup
    @State private var exporting = false
    @State private var exportDocument: AndroidPersonalListDocument?
    @State private var exportFilename = "user_dictionary_backup"
    @State private var preview: ImportItem?
    @State private var error: String?
    @State private var transferMessage: String?
    private struct EditItem: Identifiable {
        let id = UUID()
        let index: Int?
        let word: PersonalWord
        let template: Bool
    }
    private struct ImportItem: Identifiable {
        let id = UUID()
        let data: PersonalImportPreview
        let application: PersonalImportApplicationPreview
        let sourceLexicon: PersonalLexicon
        let template: Bool
        let sourceTitle: String
    }
    private enum ImportFormat {
        case androidBackup
        case automaticText
        case googleJapaneseInput
        case microsoftIME

        var isTextImport: Bool {
            switch self {
            case .androidBackup: return false
            case .automaticText, .googleJapaneseInput, .microsoftIME: return true
            }
        }

        var title: String {
            switch self {
            case .androidBackup: return "Android JSONバックアップ"
            case .automaticText: return "自動判定（CSV・TSV）"
            case .googleJapaneseInput: return "Google日本語入力（CSV・TSV）"
            case .microsoftIME: return "Microsoft IME（CSV・TSV）"
            }
        }
    }
    private var entries: [PersonalWord] { template ? library.lexicon.templates : library.lexicon.words }
    var body: some View {
        NavigationStack {
            List {
                Picker("登録先", selection: $template) {
                    Text("ユーザー辞書").tag(false)
                    Text("定型文").tag(true)
                }.pickerStyle(.segmented)
                if let notice = library.notice { Text(notice).foregroundStyle(.red) }
                Section {
                    Button("登録を追加") {
                        editing = EditItem(index: nil, word: PersonalWord(word: "", reading: ""), template: template)
                    }.disabled(!library.writable)
                    Button("外部辞書・Android形式を取り込む") { choosingImportFormat = true }
                        .disabled(!library.writable)
                    if entries.isEmpty {
                        Text("登録がないため書き出せません").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Android形式で書き出す") {
                        do {
                            let snapshot = entries
                            let data = try PersonalAndroidListExport.encode(snapshot)
                            exportDocument = AndroidPersonalListDocument(data: data)
                            exportFilename = template ? "user_template_backup" : "user_dictionary_backup"
                            transferMessage = nil
                            error = nil
                            exporting = true
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!library.writable || entries.isEmpty)
                    if let transferMessage { Text(transferMessage).font(.caption).foregroundStyle(.secondary) }
                    Text(template ? "定型文は読み全体が一致すると候補に表示します。" : "登録した単語を通常の変換探索に加えます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("\(entries.count)件") {
                    ForEach(entries.indices, id: \.self) { index in
                        Button {
                            editing = EditItem(index: index, word: entries[index], template: template)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(entries[index].word).lineLimit(2)
                                Text(entries[index].reading).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!library.writable)
                    }.onDelete { indices in
                        do { try library.remove(indices, template: template) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .navigationTitle("ユーザー辞書・定型文")
            .toolbar { Button("完了") { dismiss() } }
            .sheet(item: $editing) { item in
                PersonalWordEditor(word: item.word, template: item.template, remove: item.index.map { index in
                    {
                        let entries = item.template ? library.lexicon.templates : library.lexicon.words
                        guard entries.indices.contains(index), entries[index] == item.word else {
                            throw PersonalDataError("登録が変更されています。一覧から開き直してください")
                        }
                        try library.remove(IndexSet(integer: index), template: item.template)
                    }
                }) { word in
                    try library.put(word, index: item.index, original: item.word, template: item.template)
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText,
                          defaultFilename: exportFilename) { result in
                switch result {
                case .success: transferMessage = "Android互換形式を保存しました"
                case .failure(let error):
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
                exportDocument = nil
            }
            .confirmationDialog("取り込む辞書形式を選択", isPresented: $choosingImportFormat, titleVisibility: .visible) {
                Button(ImportFormat.androidBackup.title) { beginImport(.androidBackup) }
                if !template {
                    Button(ImportFormat.automaticText.title) { beginImport(.automaticText) }
                    Button(ImportFormat.googleJapaneseInput.title) { beginImport(.googleJapaneseInput) }
                    Button(ImportFormat.microsoftIME.title) { beginImport(.microsoftIME) }
                }
                Button("キャンセル", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .commaSeparatedText, .tabSeparatedText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard let size, size <= 32 * 1024 * 1024 else { throw PersonalDataError("取り込みファイルが大きすぎます") }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while let chunk = try handle.read(upToCount: min(65536, 32 * 1024 * 1024 + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= 32 * 1024 * 1024 else { throw PersonalDataError("取り込みファイルが大きすぎます") }
                    }
                    let parsed: PersonalImportPreview
                    switch importFormat {
                    case .androidBackup:
                        parsed = try PersonalImportPreview.parse(data)
                    case .automaticText:
                        parsed = try PersonalImportPreview.parseText(data, format: .automatic)
                    case .googleJapaneseInput:
                        parsed = try PersonalImportPreview.parseText(data, format: .googleJapaneseInput)
                    case .microsoftIME:
                        parsed = try PersonalImportPreview.parseText(data, format: .microsoftIME)
                    }
                    let sourceLexicon = library.lexicon
                    let application = try parsed.applying(to: sourceLexicon, template: template)
                    preview = ImportItem(data: parsed, application: application, sourceLexicon: sourceLexicon,
                                         template: template, sourceTitle: importFormat.title)
                } catch { self.error = error.localizedDescription }
            }
            .sheet(item: $preview) { item in
                NavigationStack {
                    List {
                        Text("取り込み先：\(item.template ? "定型文" : "ユーザー辞書")")
                        Text("形式：\(item.sourceTitle)")
                        Text("取り込み可能：\(item.data.entries.count)件")
                        Text("不正：\(item.data.rejected)件（反映しません）")
                        if item.data.wasTruncated {
                            Text("100000行を超えたため、残りの行は未確認です。必要ならファイルを分けてください")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("ファイル内の重複：\(item.data.duplicates)件（\(item.data.duplicatePolicy == .keepFirst ? "先の値" : "後の値")を使用）")
                        Text("新規追加：\(item.application.addedEntries)件")
                        Text("登録済みとの重複：\(item.application.existingDuplicates)件（既存登録を保持）")
                        Text("読み・表記が一致する登録は保持し、新しい登録だけ追加します。")
                        if !item.data.entries.isEmpty {
                            Section("読みと表記（先頭50件）") {
                                ForEach(Array(item.data.entries.prefix(50).enumerated()), id: \.offset) { row in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.element.reading)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(row.element.word)
                                            .lineLimit(2)
                                    }
                                }
                                if item.data.entries.count > 50 {
                                    Text("ほか\(item.data.entries.count - 50)件は一覧に表示していません")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(Array(item.data.errors.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
                        Button("新しい登録を反映") {
                            do {
                                guard library.lexicon == item.sourceLexicon else {
                                    throw PersonalDataError("辞書が変更されています。ファイルを選び直してください")
                                }
                                try library.apply(item.application.lexicon)
                                preview = nil
                            } catch { self.error = error.localizedDescription }
                        }.disabled(item.application.addedEntries == 0)
                    }
                    .navigationTitle("取り込み結果の確認")
                    .toolbar { Button("キャンセル") { preview = nil } }
                }
            }
            .alert("反映できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func beginImport(_ format: ImportFormat) {
        guard !template || !format.isTextImport else {
            error = "CSV・TSV形式の外部辞書はユーザー辞書に取り込んでください"
            return
        }
        importFormat = format
        importing = true
    }
}

private struct PersonalWordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var word: PersonalWord
    @State private var score: String
    @State private var error: String?
    let template: Bool
    let save: (PersonalWord) throws -> Void
    let remove: (() throws -> Void)?
    private let parts = ["名詞", "動詞", "形容詞", "副詞", "助動詞", "助詞", "感動詞", "接続詞", "接頭詞", "記号", "連体詞", "その他"]
    init(word: PersonalWord, template: Bool, remove: (() throws -> Void)?, save: @escaping (PersonalWord) throws -> Void) {
        _word = State(initialValue: word)
        _score = State(initialValue: String(word.posScore))
        self.template = template; self.save = save; self.remove = remove
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("読み", text: $word.reading).accessibilityIdentifier("personalReading")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if template {
                    TextEditor(text: $word.word).frame(minHeight: 100).accessibilityLabel("定型文の内容")
                        .accessibilityIdentifier("personalText")
                } else {
                    TextField("表記", text: $word.word).accessibilityIdentifier("personalText")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("品詞", selection: $word.posIndex) {
                        ForEach(parts.indices, id: \.self) { Text(parts[$0]).tag($0) }
                        if !parts.indices.contains(word.posIndex) { Text("元の品詞番号 \(word.posIndex)（名詞扱い）").tag(word.posIndex) }
                    }
                }
                TextField("変換コスト", text: $score).keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("personalScore")
                Text("小さいコストほど候補の上位になりやすくなります。")
                    .font(.caption).foregroundStyle(.secondary)
                if let remove {
                    Button("この登録を削除", role: .destructive) {
                        do { try remove(); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(template ? "定型文の編集" : "単語の編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let number = Int(score) else { throw PersonalDataError("コストには整数を指定してください") }
                            word.posScore = number
                            try word.validate()
                            try save(word)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
