import SwiftUI
import UniformTypeIdentifiers
import SumireCore

private struct AndroidTextMacroFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
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

struct PersonalTextMacroSettings: View {
    @ObservedObject var library: PersonalLibrary
    @AppStorage(TextMacroCandidateSettings.enabledKey, store: KeyboardSettings.appDefaults) private var candidatesEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditItem?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: AndroidTextMacroFile?
    @State private var staged: AndroidTextMacroImportPreview?
    @State private var error: String?
    @State private var message: String?
    @State private var processing = false

    private struct EditItem: Identifiable {
        let id = UUID()
        let macro: PersonalTextMacro
        let originalID: String?
    }

    private var macros: [PersonalTextMacro] {
        library.lexicon.textMacros.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            macroList
            .navigationTitle("定型マクロ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(item: $editing) { item in
                PersonalTextMacroEditor(macro: item.macro) { changed in
                    try library.putTextMacro(changed, originalID: item.originalID)
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                          defaultFilename: "sumire-text-macros") { result in
                switch result {
                case .success: message = "Android形式のマクロを保存しました"
                case .failure(let failure):
                    if !(failure is CancellationError) { error = failure.localizedDescription }
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { startImport(try result.get()) }
                catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: Binding(
                get: { staged != nil },
                set: { if !$0 { staged = nil } }
            )) {
                if let staged {
                    AndroidTextMacroImportConfirmation(
                        preview: staged,
                        processing: processing,
                        canApply: library.writable,
                        cancel: { self.staged = nil },
                        apply: { applyImport(staged) }
                    )
                }
            }
            .alert("処理できませんでした", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("閉じる", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var macroList: some View {
        List {
            Section {
                Toggle("マクロを候補に表示", isOn: $candidatesEnabled)
                    .accessibilityIdentifier("text-macro-candidates-enabled")
            }
            if let notice = library.notice { Text(notice).foregroundStyle(.red) }
            managementSection
            macroSection
        }
    }

    private var managementSection: some View {
        Section {
            Button("定型マクロを追加") {
                editing = EditItem(macro: PersonalTextMacro(name: "", body: ""), originalID: nil)
            }
            .disabled(!library.writable || processing)
            Button("Android形式を取り込む") { importing = true }
                .disabled(!library.writable || processing)
            Button("Android形式で書き出す", systemImage: "square.and.arrow.up", action: exportMacros)
                .disabled(!library.writable || processing || macros.isEmpty)
            if processing { ProgressView("マクロを処理中…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("読みが一致した候補から、またはキーボードのマクロ一覧から展開します。日付・時刻・選択文字・クリップボード・カーソル位置を本文に挿入できます。保存先は端末内です。")
        }
    }

    private var macroSection: some View {
        Section("\(macros.count)件") {
            if macros.isEmpty {
                ContentUnavailableView("定型マクロがありません", systemImage: "text.badge.plus",
                                       description: Text("よく使う文面を登録できます。"))
            }
            ForEach(macros) { macro in
                TextMacroListRow(macro: macro, isEnabled: enabledBinding(for: macro), canEdit: library.writable && !processing) {
                    editing = EditItem(macro: macro, originalID: macro.id)
                }
            }
            .onDelete(perform: deleteMacros)
            .deleteDisabled(processing)
        }
    }

    private func exportMacros() {
        do {
            exportDocument = AndroidTextMacroFile(data: try AndroidTextMacroBackup.encode(library.lexicon.textMacros))
            message = nil
            error = nil
            exporting = true
        } catch { self.error = error.localizedDescription }
    }

    private func enabledBinding(for macro: PersonalTextMacro) -> Binding<Bool> {
        Binding(
            get: { library.lexicon.textMacros.first(where: { $0.id == macro.id })?.enabled ?? false },
            set: { enabled in
                do { try library.setTextMacroEnabled(id: macro.id, enabled: enabled) }
                catch { self.error = error.localizedDescription }
            }
        )
    }

    private func deleteMacros(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { macros.indices.contains($0) ? macros[$0].id : nil })
        do { try library.removeTextMacros(ids: ids) }
        catch { self.error = error.localizedDescription }
    }

    private func startImport(_ url: URL) {
        guard !processing else { return }
        processing = true
        message = nil
        let existing = library.lexicon.textMacros
        DispatchQueue.global(qos: .userInitiated).async {
            let access = url.startAccessingSecurityScopedResource()
            let result = Result { () throws -> AndroidTextMacroImportPreview in
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(65_536, AndroidTextMacroBackup.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= AndroidTextMacroBackup.maximumBytes else {
                        throw PersonalDataError("定型マクロのバックアップが大きすぎます")
                    }
                }
                return try AndroidTextMacroBackup.decode(data, existing: existing)
            }
            DispatchQueue.main.async {
                processing = false
                switch result {
                case .success(let preview): staged = preview
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func applyImport(_ preview: AndroidTextMacroImportPreview) {
        guard !processing else { return }
        processing = true
        do {
            try library.importTextMacros(preview)
            staged = nil
            message = "追加 \(preview.added)件・更新 \(preview.overwritten)件のマクロを反映しました"
            processing = false
        } catch {
            processing = false
            self.error = error.localizedDescription
        }
    }
}

private struct AndroidTextMacroImportConfirmation: View {
    let preview: AndroidTextMacroImportPreview
    let processing: Bool
    let canApply: Bool
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            List { summarySection; macrosSection }
                .navigationTitle("取り込みの確認")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("反映する", action: apply)
                            .disabled(processing || preview.entries.isEmpty || !canApply)
                    }
                }
        }
        .interactiveDismissDisabled(processing)
    }

    private var summarySection: some View {
        Section("取り込み内容") {
            LabeledContent("追加", value: "\(preview.added)件")
            LabeledContent("更新", value: "\(preview.overwritten)件")
            Text("名前が一致する登録を更新し、その他のユーザーデータは保持します。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var macrosSection: some View {
        Section("マクロ") {
            ForEach(preview.entries) { TextMacroImportRow(macro: $0) }
        }
    }
}

private struct TextMacroEditorBlockItem: Identifiable, Equatable {
    let id: UUID
    var block: AndroidTextMacroEditorBlock

    init(id: UUID = UUID(), block: AndroidTextMacroEditorBlock) {
        self.id = id
        self.block = block
    }
}

enum TextMacroEditorMode: String, CaseIterable, Identifiable {
    case blocks = "ブロック"
    case source = "構文"
    var id: String { rawValue }

    static func initial(for parsedDocument: AndroidTextMacroEditorDocument?) -> TextMacroEditorMode {
        parsedDocument == nil ? .source : .blocks
    }
}

private struct RemovedTextMacroEditorBlock: Identifiable {
    let id = UUID()
    let item: TextMacroEditorBlockItem
    let index: Int
}

private struct PersonalTextMacroEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var macro: PersonalTextMacro
    @State private var blocks: [TextMacroEditorBlockItem]
    @State private var mode: TextMacroEditorMode
    @State private var removedBlock: RemovedTextMacroEditorBlock?
    @State private var error: String?
    @State private var showDiscardConfirmation = false
    @State private var previewTimestamp = Date()
    private let originalMacro: PersonalTextMacro
    let save: (PersonalTextMacro) throws -> Void

    init(macro: PersonalTextMacro, save: @escaping (PersonalTextMacro) throws -> Void) {
        _macro = State(initialValue: macro)
        originalMacro = macro
        let parsedDocument = try? AndroidTextMacroEditorDocument.parse(macro.body)
        let parsed = parsedDocument?.blocks ?? []
        let initialBlocks: [AndroidTextMacroEditorBlock] = parsed.isEmpty ? [.text("")] : parsed
        _blocks = State(initialValue: initialBlocks.map { TextMacroEditorBlockItem(block: $0) })
        _mode = State(initialValue: TextMacroEditorMode.initial(for: parsedDocument))
        self.save = save
    }

    private var validation: Result<CompiledAndroidTextMacro, Error> {
        Result { try AndroidTextMacroCompiler.compile(macro.body) }
    }

    private var expansionPreview: Result<AndroidExpandedTextMacro, Error> {
        validation.flatMap { compiled in
            Result {
                try compiled.expand(context: AndroidTextMacroContext(
                    selection: "選択文字の例", clipboard: "クリップボードの例", timestamp: previewTimestamp
                ))
            }
        }
    }

    var body: some View {
        NavigationStack {
            editorForm
                .navigationTitle("定型マクロの編集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { cancelEditing() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                let normalized = macro.normalized()
                                try normalized.validate()
                                _ = try AndroidTextMacroEditorDocument.parse(normalized.body)
                                try save(normalized)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                        .disabled(macro.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validationFailure != nil)
                    }
                }
                .confirmationDialog("編集内容を破棄しますか？", isPresented: $showDiscardConfirmation,
                                    titleVisibility: .visible) {
                    Button("変更を破棄", role: .destructive) { dismiss() }
                    Button("編集を続ける", role: .cancel) {}
                }
                .onChange(of: mode) { oldMode, newMode in
                    switch (oldMode, newMode) {
                    case (.blocks, .source): synchronizeSource()
                    case (.source, .blocks): loadBlocksFromSource()
                    default: break
                    }
                }
        }
    }

    private var editorForm: some View {
        Form {
            basicInfoSection
            editorModeSection
            if mode == .blocks { visualBodySection } else { sourceBodySection }
            previewSection
        }
    }

    private var basicInfoSection: some View {
        Section("基本情報") {
            TextField("名前", text: $macro.name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("読み（任意）", text: Binding(
                get: { macro.reading ?? "" }, set: { macro.reading = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("有効", isOn: $macro.enabled)
        }
    }

    private var editorModeSection: some View {
        Section {
            Picker("本文の編集方法", selection: $mode) {
                ForEach(TextMacroEditorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var visualBodySection: some View {
        Section("本文のブロック") {
            Menu("ブロックを追加") {
                Button("文章") { insertBlock(.text(""), at: blocks.count) }
                variableButtons(at: blocks.count)
            }
            ForEach(Array(blocks.indices), id: \.self) { index in
                TextMacroEditorBlockRow(
                    block: blocks[index].block,
                    onTextChanged: { replaceBlock(at: index, with: .text($0)) },
                    onPatternChanged: { replaceDatePattern(at: index, with: $0) }
                )
                HStack {
                    Menu("ここに挿入") {
                        Button("文章") { insertBlock(.text(""), at: index) }
                        variableButtons(at: index)
                    }
                    .font(.caption)
                    Spacer()
                    Button("上へ", systemImage: "arrow.up") { moveBlock(at: index, by: -1) }
                        .disabled(index == 0)
                    Button("下へ", systemImage: "arrow.down") { moveBlock(at: index, by: 1) }
                        .disabled(index == blocks.count - 1)
                    Button("削除", systemImage: "xmark", role: .destructive) { removeBlock(at: index) }
                }
                .buttonStyle(.borderless)
            }
            if let removedBlock {
                Button("削除したブロックを元に戻す") { undoRemoveBlock(removedBlock) }
            }
            Text("文章の波括弧は自動でエスケープされます。ブロックは上・下のボタンで並べ替えられます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourceBodySection: some View {
        Section("本文の構文") {
            TextEditor(text: $macro.body).frame(minHeight: 150)
                .accessibilityLabel("マクロ本文")
            Menu("変数を末尾に挿入") { variableButtons(at: blocks.count) }
            Text("波括弧を本文に書く場合は {{ と }} にします。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func variableButtons(at index: Int) -> some View {
        Button("日付") { insertToken(.token(name: "date"), at: index) }
        Button("時刻") { insertToken(.token(name: "time"), at: index) }
        Button("選択文字") { insertToken(.token(name: "selection"), at: index) }
        Button("クリップボード") { insertToken(.token(name: "clipboard"), at: index) }
        Button("カーソル位置") { insertToken(.token(name: "cursor"), at: index) }
            .disabled(mode == .source ? sourceContainsCursor : containsCursor)
        Button("改行") { insertToken(.token(name: "newline"), at: index) }
    }

    private var previewSection: some View {
        Section("プレビュー") {
            expansionPreviewContent
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var expansionPreviewContent: some View {
        switch expansionPreview {
        case .success(let sample):
            VStack(alignment: .leading, spacing: 6) {
                Text(sample.text.isEmpty ? "（空の本文）" : sample.text).textSelection(.enabled)
                Text("展開後のカーソル位置: \(sample.cursorOffset)（UTF-16）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failure(let previewError):
            Label(previewError.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private var containsCursor: Bool {
        blocks.contains { if case .token(name: "cursor", argument: _) = $0.block { true } else { false } }
    }

    private var sourceContainsCursor: Bool {
        if let parsed = try? AndroidTextMacroEditorDocument.parse(macro.body) {
            return parsed.blocks.contains {
                if case .token(name: "cursor", argument: _) = $0 { true } else { false }
            }
        }
        // Keep the insertion control conservative while the source is malformed;
        // an existing cursor must not become a second cursor after the user fixes it.
        return macro.body.contains("{cursor}")
    }

    private var validationFailure: Error? {
        if case .failure(let error) = validation { return error }
        return nil
    }

    private var isDirty: Bool { macro != originalMacro }

    private func cancelEditing() {
        if isDirty { showDiscardConfirmation = true } else { dismiss() }
    }

    private func synchronizeSource() {
        macro.body = AndroidTextMacroEditorDocument(blocks: blocks.map(\.block)).toSource()
    }

    private func loadBlocksFromSource() {
        do {
            let parsed = try AndroidTextMacroEditorDocument.parse(macro.body)
            let values: [AndroidTextMacroEditorBlock] = parsed.blocks.isEmpty ? [.text("")] : parsed.blocks
            blocks = values.map { TextMacroEditorBlockItem(block: $0) }
            removedBlock = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
            mode = .source
        }
    }

    private func insertBlock(_ block: AndroidTextMacroEditorBlock, at index: Int) {
        if case let .token(name, _) = block, name == "cursor", containsCursor { return }
        var changed = blocks
        changed.insert(TextMacroEditorBlockItem(block: block), at: min(max(index, 0), changed.count))
        blocks = changed
        synchronizeSource()
    }

    private func insertToken(_ block: AndroidTextMacroEditorBlock, at index: Int) {
        guard case let .token(name, _) = block else { return }
        if mode == .source {
            if name == "cursor", sourceContainsCursor { return }
            macro.body.append(block.source)
        } else {
            insertBlock(block, at: index)
        }
    }

    private func replaceBlock(at index: Int, with block: AndroidTextMacroEditorBlock) {
        guard blocks.indices.contains(index) else { return }
        blocks[index].block = block
        synchronizeSource()
    }

    private func replaceDatePattern(at index: Int, with pattern: String) {
        guard blocks.indices.contains(index),
              case let .token(name, _) = blocks[index].block,
              name == "date" || name == "time" else { return }
        replaceBlock(at: index, with: .token(name: name, argument: pattern.isEmpty ? nil : pattern))
    }

    private func moveBlock(at index: Int, by offset: Int) {
        let destination = index + offset
        guard blocks.indices.contains(index), blocks.indices.contains(destination) else { return }
        var changed = blocks
        let item = changed.remove(at: index)
        changed.insert(item, at: destination)
        blocks = changed
        synchronizeSource()
    }

    private func removeBlock(at index: Int) {
        guard blocks.indices.contains(index) else { return }
        var changed = blocks
        let item = changed.remove(at: index)
        blocks = changed
        removedBlock = RemovedTextMacroEditorBlock(item: item, index: index)
        synchronizeSource()
    }

    private func undoRemoveBlock(_ removed: RemovedTextMacroEditorBlock) {
        var changed = blocks
        changed.insert(removed.item, at: min(removed.index, changed.count))
        blocks = changed
        removedBlock = nil
        synchronizeSource()
    }
}

private struct TextMacroEditorBlockRow: View {
    let block: AndroidTextMacroEditorBlock
    let onTextChanged: (String) -> Void
    let onPatternChanged: (String) -> Void

    var body: some View {
        switch block {
        case let .text(value):
            TextField("文章", text: Binding(get: { value }, set: onTextChanged), axis: .vertical)
                .accessibilityLabel("文章ブロック")
        case let .token(name, argument):
            HStack {
                Label(tokenTitle(name), systemImage: "curlybraces")
                Spacer(minLength: 8)
                if name == "date" || name == "time" {
                    TextField("形式（任意）", text: Binding(get: { argument ?? "" }, set: onPatternChanged))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .accessibilityLabel(tokenTitle(name))
        }
    }

    private func tokenTitle(_ name: String) -> String {
        switch name {
        case "date": "日付"
        case "time": "時刻"
        case "selection": "選択文字"
        case "clipboard": "クリップボード"
        case "cursor": "カーソル位置"
        case "newline": "改行"
        default: name
        }
    }
}

private struct TextMacroImportRow: View {
    let macro: PersonalTextMacro

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(macro.name)
            if let reading = macro.reading {
                Text("読み: \(reading)").font(.caption).foregroundStyle(.secondary)
            }
            Text(macro.body).lineLimit(3).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TextMacroListRow: View {
    let macro: PersonalTextMacro
    @Binding var isEnabled: Bool
    let canEdit: Bool
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(macro.name).foregroundStyle(.primary)
                    Text(subtitle).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)

            Toggle("\(macro.name)を有効", isOn: $isEnabled)
                .labelsHidden()
                .disabled(!canEdit)
                .accessibilityLabel("\(macro.name)を有効")
        }
    }

    private var subtitle: String { macro.reading.map { "読み: \($0)" } ?? macro.body }
}
