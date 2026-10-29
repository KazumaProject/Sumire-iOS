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
                        do {
                            let standard = try RomajiConverter.standard()
                            editing = RomajiProfile(name: "カスタム", rules: standard.rules, ruleOrder: standard.ruleOrder)
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!loaded)
                    Button("Android JSONを取り込む") { importing = true }.disabled(!loaded)
                    Text("取り込んだ設定は選択してから使用します。編集中の読みは保持し、以降のローマ字入力に新しい規則を使います。")
                        .font(.caption)
                }
                Section("編集") {
                    ForEach(library.profiles) { profile in
                        Button {
                            guard profile.isDeletable else { return }
                            editing = profile
                        } label: {
                            HStack {
                                Text(profile.name)
                                Spacer()
                                if !profile.isDeletable {
                                    Text("編集・削除不可").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!profile.isDeletable)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if profile.isDeletable {
                                Button("削除", systemImage: "trash", role: .destructive) {
                                    deleteProfile(profile.id)
                                }
                            }
                        }
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
                RomajiProfileEditor(profile: profile, remove: library.profiles.contains(where: { $0.id == profile.id && $0.isDeletable }) ? {
                    var next = library
                    guard next.profiles.first(where: { $0.id == profile.id })?.isDeletable == true else {
                        throw PersonalDataError("この設定は削除できません")
                    }
                    next.profiles.removeAll { $0.id == profile.id }
                    if next.activeID == profile.id { next.activeID = nil }
                    try next.save(defaults: KeyboardSettings.appDefaults)
                    library = next
                } : nil) { updated in
                    var next = library
                    if let index = next.profiles.firstIndex(where: { $0.id == updated.id }) {
                        guard next.profiles[index].isDeletable else {
                            throw PersonalDataError("この設定は編集できません")
                        }
                        next.profiles[index] = updated
                    }
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

    private func deleteProfile(_ id: UUID) {
        guard library.profiles.first(where: { $0.id == id })?.isDeletable == true else { return }
        var next = library
        next.profiles.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = nil }
        save(next)
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
    private var keys: [String] { profile.ruleOrder.filter { search.isEmpty || $0.contains(search) } }
    var body: some View {
        NavigationStack {
            List {
                TextField("名前", text: $profile.name).disabled(!profile.isDeletable)
                Toggle("自動促音", isOn: $profile.autoSokuon).disabled(!profile.isDeletable)
                Toggle("自動ん", isOn: $profile.autoN).disabled(!profile.isDeletable)
                if let remove {
                    Button("この設定を削除", role: .destructive) {
                        do { try remove(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Section("規則の追加・置き換え") {
                    TextField("入力", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("romajiRuleInput")
                        .disabled(!profile.isDeletable)
                    TextField("出力", text: $output).accessibilityIdentifier("romajiRuleOutput")
                        .disabled(!profile.isDeletable)
                    TextField("消費するUTF-16文字数", text: $count).keyboardType(.numberPad)
                        .disabled(!profile.isDeletable)
                    Button("規則を反映") {
                        do {
                            guard let n = Int(count) else { throw PersonalDataError("消費文字数を入力してください") }
                            var next = profile; next.setRule(RomajiRule(output, n), for: input); try next.validate()
                            profile = next; input = ""; output = ""; count = "1"; error = nil
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!profile.isDeletable)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("\(profile.rules.count)規則（タップで編集）") {
                    TextField("入力を検索", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(keys, id: \.self) { key in
                        Button("\(key) → \(profile.rules[key]!.first)（\(profile.rules[key]!.second)）") {
                            input = key; output = profile.rules[key]!.first; count = String(profile.rules[key]!.second)
                        }
                    }
                    .onDelete { indices in let removed = indices.map { keys[$0] }; for key in removed { profile.removeRule(for: key) } }
                    .disabled(!profile.isDeletable)
                }
            }
            .navigationTitle("ローマ字の編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try profile.validate(); try save(profile); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(!profile.isDeletable) }
            }
        }
    }
}
