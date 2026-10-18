import SwiftUI
import UniformTypeIdentifiers
import SumireCore

struct RomajiSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = RomajiLibrary()
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: RomajiProfile?
    @State private var importing = false
    @State private var imported: [RomajiProfile] = []
    @State private var importErrors: [String] = []
    @State private var confirmImport = false
    @discardableResult private func save(_ next: RomajiLibrary) -> Bool {
        do { try next.save(defaults: KeyboardSettings.appDefaults); library = next; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                Section("使用する設定") {
                    Picker("ローマ字設定", selection: Binding(get: { library.activeID }, set: { id in
                        var next = library; next.activeID = id; save(next)
                    })) {
                        Text("標準（312規則）").tag(UUID?.none)
                        ForEach(library.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!loaded).accessibilityIdentifier("activeRomajiProfile")
                }
                Section {
                    Button("標準をコピーして作成") {
                        do { editing = RomajiProfile(name: "カスタム", rules: try RomajiConverter.standard().rules) }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!loaded)
                    Button("Android JSONを取り込む") { importing = true }.disabled(!loaded)
                    Text("取り込んだ設定は選択してから使用します。編集中の読みは保持し、以降のローマ字入力に新しい規則を使います。")
                        .font(.caption)
                }
                Section("編集") {
                    ForEach(library.profiles) { profile in
                        Button(profile.name) { editing = profile }
                    }.onDelete { indices in
                        var next = library
                        next.profiles.remove(atOffsets: indices)
                        if !next.profiles.contains(where: { $0.id == next.activeID }) { next.activeID = nil }
                        save(next)
                    }
                }
            }
            .navigationTitle("カスタムローマ字")
            .toolbar { Button("完了") { dismiss() } }
            .onAppear {
                do { library = try RomajiLibrary.load(defaults: KeyboardSettings.appDefaults); loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .sheet(item: $editing) { profile in
                RomajiProfileEditor(profile: profile, remove: library.profiles.contains(where: { $0.id == profile.id }) ? {
                    var next = library
                    next.profiles.removeAll { $0.id == profile.id }
                    if next.activeID == profile.id { next.activeID = nil }
                    try next.save(defaults: KeyboardSettings.appDefaults)
                    library = next
                } : nil) { updated in
                    var next = library
                    if let index = next.profiles.firstIndex(where: { $0.id == updated.id }) { next.profiles[index] = updated }
                    else { next.profiles.append(updated) }
                    try next.save(defaults: KeyboardSettings.appDefaults)
                    library = next
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while let chunk = try handle.read(upToCount: min(65536, RomajiLibrary.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= RomajiLibrary.maximumBytes else { throw PersonalDataError("JSONが大きすぎます") }
                    }
                    let preview = try RomajiImportPreview.parse(data)
                    imported = preview.profiles
                    importErrors = preview.errors
                    error = nil
                    var next = library; next.profiles += imported; try next.validate()
                    confirmImport = true
                } catch { imported = []; self.error = error.localizedDescription }
            }
            .sheet(isPresented: $confirmImport) {
                NavigationStack {
                    List {
                        Text("有効：\(imported.count)件／不正：\(importErrors.count)件")
                        Text("有効な設定だけを追加します。現在の設定と選択は保持します。")
                        ForEach(imported) { Text($0.name) }
                        ForEach(Array(importErrors.enumerated()), id: \.offset) { _, message in Text(message).foregroundStyle(.red) }
                        if let error { Text(error).foregroundStyle(.red) }
                        Button("有効な設定を追加する") {
                            var next = library; next.profiles += imported
                            if save(next) { imported = []; confirmImport = false }
                        }.disabled(imported.isEmpty)
                    }
                    .navigationTitle("取り込み内容")
                    .toolbar { Button("キャンセル") { imported = []; confirmImport = false } }
                }
            }
        }
    }
}

private struct RomajiProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: RomajiProfile
    let remove: (() throws -> Void)?
    let save: (RomajiProfile) throws -> Void
    @State private var input = ""
    @State private var output = ""
    @State private var count = "1"
    @State private var error: String?
    @State private var search = ""
    private var keys: [String] { profile.rules.keys.filter { search.isEmpty || $0.contains(search) }.sorted() }
    var body: some View {
        NavigationStack {
            List {
                TextField("名前", text: $profile.name)
                Toggle("自動促音", isOn: $profile.autoSokuon)
                Toggle("自動ん", isOn: $profile.autoN)
                if let remove {
                    Button("この設定を削除", role: .destructive) {
                        do { try remove(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Section("規則の追加・置き換え") {
                    TextField("入力", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("romajiRuleInput")
                    TextField("出力", text: $output).accessibilityIdentifier("romajiRuleOutput")
                    TextField("消費するUTF-16文字数", text: $count).keyboardType(.numberPad)
                    Button("規則を反映") {
                        do {
                            guard let n = Int(count) else { throw PersonalDataError("消費文字数を入力してください") }
                            var next = profile; next.rules[input] = RomajiRule(output, n); try next.validate()
                            profile = next; input = ""; output = ""; count = "1"; error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("\(profile.rules.count)規則（タップで編集）") {
                    TextField("入力を検索", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(keys, id: \.self) { key in
                        Button("\(key) → \(profile.rules[key]!.first)（\(profile.rules[key]!.second)）") {
                            input = key; output = profile.rules[key]!.first; count = String(profile.rules[key]!.second)
                        }
                    }.onDelete { indices in let removed = indices.map { keys[$0] }; for key in removed { profile.rules.removeValue(forKey: key) } }
                }
            }
            .navigationTitle("ローマ字の編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try profile.validate(); try save(profile); dismiss() }
                    catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}
