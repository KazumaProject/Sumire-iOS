import SwiftUI
import Foundation
import SumireCore

/// Ordered sources for browsing one dictionary. The shared generation store
/// publishes the active generation first and its previous recovery generation
/// second; the bundled dictionary is the final read-only fallback.
struct DictionaryBrowserSource: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case sharedGeneration(String, recoveredPrevious: Bool)
        case bundled
    }

    let directory: URL
    let origin: Origin
    let sourceRevision: String?
    let dictionarySHA256: String?

    struct OpenedBrowser {
        let cursor: OpaquePointer
        let source: DictionaryBrowserSource
    }

    var title: String {
        switch origin {
        case .sharedGeneration(_, let recoveredPrevious):
            return recoveredPrevious ? "共有辞書（前世代）" : "共有辞書（現行世代）"
        case .bundled:
            return "同梱辞書"
        }
    }

    var generation: String? {
        guard case .sharedGeneration(let generation, _) = origin else { return nil }
        return generation
    }

    static func candidates(name: String, generations: [DictionaryGenerationStore.Loaded],
                           bundled: URL?, fileManager: FileManager = .default) -> [Self] {
        let allowedNames = Set(["system", "english", "english_reading"] + DictionaryArchivePlan.categoryIDs)
        guard allowedNames.contains(name) else { return [] }

        let filename = name + ".sud"
        var seen = Set<String>()
        var sources: [Self] = []
        for generation in generations {
            let directory = generation.directory.standardizedFileURL
            guard seen.insert(directory.path).inserted,
                  Self.isRegularFile(filename, in: directory, fileManager: fileManager) else { continue }
            let metadata = Self.manifestMetadata(in: directory, filename: filename)
            sources.append(Self(directory: directory,
                                origin: .sharedGeneration(generation.generation,
                                                         recoveredPrevious: generation.recoveredPrevious),
                                sourceRevision: metadata.revision,
                                dictionarySHA256: metadata.sha256))
        }
        if let bundled {
            let directory = bundled.standardizedFileURL
            if seen.insert(directory.path).inserted,
               Self.isRegularFile(filename, in: directory, fileManager: fileManager) {
                let metadata = Self.manifestMetadata(in: directory, filename: filename)
                sources.append(Self(directory: directory, origin: .bundled,
                                    sourceRevision: metadata.revision,
                                    dictionarySHA256: metadata.sha256))
            }
        }
        return sources
    }

    static func open(name: String, query: String, mode: UInt32,
                     candidates: [Self]) throws -> OpenedBrowser {
        var lastError: String?
        for source in candidates {
            var opened: OpaquePointer?
            var error = [CChar](repeating: 0, count: 512)
            let status = sumire_dictionary_browser_open(source.directory.path, name, query,
                                                        mode, &opened, &error, error.count)
            if status == 0, let opened { return OpenedBrowser(cursor: opened, source: source) }
            lastError = String(cString: error)
        }
        throw Failure(message: lastError ?? "閲覧できる辞書が見つかりません。")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func isRegularFile(_ filename: String, in directory: URL,
                                     fileManager: FileManager) -> Bool {
        let url = directory.appendingPathComponent(filename)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private static func manifestMetadata(in directory: URL, filename: String) -> (revision: String?, sha256: String?) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let hashes = manifest["output_sha256"] as? [String: String]
        return (manifest["source_revision"] as? String, hashes?[filename])
    }
}

/// The worker owns the native cursor on one queue; only one bounded page crosses
/// onto the main queue. Generation changes cancel scans between native steps.
private final class DictionaryBrowserWorker: @unchecked Sendable {
    struct Row: Identifiable { let id: UInt32; let reading: String; let surface: String; let context: UInt16; let cost: Int16 }
    struct Page {
        let rows: [Row]
        let done: Bool
        let total: Int
        let tokens: Int
        let bytes: Int
        let source: DictionaryBrowserSource
    }
    private let queue = DispatchQueue(label: "sumire.dictionary-browser", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cursor: OpaquePointer?
    private var selectedSource: DictionaryBrowserSource?
    deinit { if let cursor { sumire_dictionary_browser_close(cursor) } }
    @discardableResult func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; generation &+= 1; return generation
    }
    func current(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
    func page(name: String, query: String, mode: Int, restart: Bool,
              generation: UInt64, completion: @escaping (Result<Page, Error>) -> Void) {
        queue.async { [self] in
            guard current(generation) else { return }
            do {
                if restart {
                    if let cursor { sumire_dictionary_browser_close(cursor); self.cursor = nil }
                    selectedSource = nil
                    let sources = DictionaryBrowserSource.candidates(
                        name: name,
                        generations: PersonalDataLocation.readableDictionaryGenerations(),
                        bundled: ConversionService.bundledDictionary)
                    let opened = try DictionaryBrowserSource.open(name: name, query: query,
                                                                 mode: UInt32(mode), candidates: sources)
                    cursor = opened.cursor
                    selectedSource = opened.source
                }
                guard let cursor, let selectedSource else { throw Failure(message: "辞書を開き直してください。") }
                var rows: [Row] = []
                while rows.count < 100 && sumire_dictionary_browser_done(cursor) == 0 {
                    guard current(generation) else { return }
                    var error = [CChar](repeating: 0, count: 512)
                    guard sumire_dictionary_browser_step(cursor, 100 - rows.count, &error, error.count) == 0 else {
                        throw Failure(message: String(cString: error))
                    }
                    for index in 0..<sumire_dictionary_browser_count(cursor) {
                        var row = sumire_dictionary_row()
                        guard sumire_dictionary_browser_row(cursor, index, &row) == 0 else { continue }
                        rows.append(Row(id: row.token_id,
                                        reading: String(decoding: UnsafeRawBufferPointer(start: row.reading, count: row.reading_bytes), as: UTF8.self),
                                        surface: String(decoding: UnsafeRawBufferPointer(start: row.surface, count: row.surface_bytes), as: UTF8.self),
                                        context: row.context_id, cost: row.word_cost))
                    }
                }
                let result = Page(rows: rows, done: sumire_dictionary_browser_done(cursor) != 0,
                                  total: sumire_dictionary_browser_entry_count(cursor),
                                  tokens: sumire_dictionary_browser_token_count(cursor),
                                  bytes: sumire_dictionary_browser_mapped_bytes(cursor),
                                  source: selectedSource)
                DispatchQueue.main.async { [self] in if current(generation) { completion(.success(result)) } }
            } catch {
                DispatchQueue.main.async { [self] in if current(generation) { completion(.failure(error)) } }
            }
        }
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
}

private final class DictionaryBrowserModel: ObservableObject {
    @Published var rows: [DictionaryBrowserWorker.Row] = []
    @Published var loading = false
    @Published var done = true
    @Published var error: String?
    @Published var pageNumber = 1
    @Published var total = 0
    @Published var tokens = 0
    @Published var bytes = 0
    @Published var source: DictionaryBrowserSource?
    private let worker = DictionaryBrowserWorker()
    private var pending: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var name = "system", query = ""
    private var mode = 0
    func reload(name: String, query: String, mode: Int, debounce: Bool = false) {
        pending?.cancel(); generation = worker.invalidate()
        self.name = name; self.query = query; self.mode = mode
        rows = []; total = 0; tokens = 0; bytes = 0; source = nil
        error = nil; done = true; loading = true; pageNumber = 1
        let task = DispatchWorkItem { [weak self] in self?.load(restart: true) }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.3 : 0), execute: task)
    }
    func next() { guard !loading && !done else { return }; load(restart: false) }
    func cancel() { pending?.cancel(); worker.invalidate(); loading = false }
    private func load(restart: Bool) {
        loading = true; error = nil
        worker.page(name: name, query: query, mode: mode,
                    restart: restart, generation: generation) { [weak self] result in
            guard let self else { return }
            loading = false
            switch result {
            case .success(let page):
                if !restart { pageNumber += 1 }
                rows = page.rows; done = page.done; total = page.total; tokens = page.tokens; bytes = page.bytes
                source = page.source
            case .failure(let failure): error = failure.localizedDescription; done = true
            }
        }
    }
}

struct DictionaryBrowserView: View {
    @StateObject private var model = DictionaryBrowserModel()
    @State private var dictionary = "system"
    @State private var query = ""
    @State private var mode = 2
    @FocusState private var searchFocused: Bool
    private var dictionaries: [(id: String, title: String)] {
        [("system", "システム"), ("english", "英単語"), ("english_reading", "かなから英単語")] +
        (0..<sumire_category_count()).map { index in
            let name = String(cString: sumire_category_name(index))
            return (name, DictionarySettings.names[name] ?? name)
        }
    }
    var body: some View {
        List {
            Section {
                Picker("閲覧する辞書", selection: $dictionary) {
                    ForEach(dictionaries, id: \.id) { item in Text(item.title).tag(item.id) }
                }.accessibilityIdentifier("dictionary-browser-choice")
                Picker("検索方法", selection: $mode) {
                    Text("読み・表記").tag(2); Text("読みの先頭").tag(0); Text("表記に含む").tag(1)
                }.pickerStyle(.segmented).accessibilityIdentifier("dictionary-browser-search-mode")
                HStack {
                    TextField(mode == 0 ? "読みを入力" : mode == 1 ? "探したい表記を入力" : "読み・表記を検索", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                        .accessibilityIdentifier("dictionary-browser-query")
                    if searchFocused {
                        Button { searchFocused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down").frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.borderless).accessibilityLabel("検索を閉じる")
                    }
                }
                Text(model.source.map(provenance(for:)) ?? "辞書を選択中…")
                    .font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("dictionary-browser-source")
            }
            Section {
                HStack {
                    Button("先頭に戻る") { reload() }.disabled(model.loading).frame(minHeight: 44)
                    Spacer()
                    Button("次の100件") { model.next() }.disabled(model.loading || model.done).frame(minHeight: 44)
                        .accessibilityIdentifier("dictionary-browser-next")
                }.buttonStyle(.borderless)
            }
            Section {
                if model.loading {
                    HStack { ProgressView(); Text(mode == 0 ? "読み込み中…" : "辞書を検索中…") }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("再試行") { reload() }
                }
                if !model.loading && model.rows.isEmpty && model.error == nil {
                    Text("該当する単語はありません").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.surface).font(.headline).textSelection(.enabled)
                        Text(row.reading).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("品詞・接続ID \(row.context) · 単語コスト \(row.cost)").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dictionary-browser-row-\(row.id)")
                }
            } header: { Text("\(model.pageNumber)ページ · \(model.rows.count)件表示 / 辞書全体 \(model.total)件") }
            Section {
                DisclosureGroup("この一覧について") {
                    Text("この画面は対象の辞書ファイルを、共有領域の現行世代、前世代、同梱辞書の順に開きます。無効にしている分類も閲覧できます。学習や個人辞書は含みません。「読み・表記」は幅や英字の大小、かなの違いをそろえて途中の文字も探します。ほかの検索方法は入力した文字のまま照合します。")
                    Text("表示は1ページずつ切り替わります。表記検索は辞書全体を調べるため時間がかかる場合があります。品詞・接続IDは配布辞書の数値で、品詞名ではありません。")
                }.font(.footnote)
            }
            Section("辞書データ") {
                if model.total != model.tokens {
                    Text("格納トークン \(model.tokens)件のうち、読みから参照できる \(model.total)件を表示対象にしています。読みのないトークンは表示しません。")
                        .font(.caption).accessibilityIdentifier("dictionary-browser-unreferenced")
                }
                Text("\(dictionary).sud · \(model.bytes) bytes").font(.caption).textSelection(.enabled)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("辞書の単語を見る")
        .onAppear { reload() }
        .onDisappear { model.cancel() }
        .onChange(of: dictionary) { _, _ in reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onChange(of: query) { _, _ in reload(debounce: true) }
    }
    private func reload(debounce: Bool = false) { model.reload(name: dictionary, query: query, mode: mode, debounce: debounce) }
    private func provenance(for source: DictionaryBrowserSource) -> String {
        let generation: String
        if let value = source.generation { generation = "\n世代: \(value)" }
        else { generation = "" }
        return "\(source.title)\(generation)\n生成元: \(source.sourceRevision ?? "未記載")\nmanifest記載 SHA-256: \(source.dictionarySHA256 ?? "未記載")"
    }
}
