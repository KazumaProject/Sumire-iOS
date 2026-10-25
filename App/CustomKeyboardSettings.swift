import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CryptoKit
import SumireCore

struct CustomKeyboardSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CustomInputModeStore.rememberKey, store: KeyboardSettings.appDefaults) private var rememberInputMode = false
    @AppStorage(CustomInputModeStore.replaceKey, store: KeyboardSettings.appDefaults) private var replaceComposingOnDirectInput = false
    @State private var library = CustomKeyboardLibrary()
    @State private var layouts: [ImportedCustomLayout] = []
    @State private var baseline: Data?
    @State private var loaded = false
#if DEBUG
    @State private var keyboardUITestState = ""
#endif
    @State private var importing = false
    @State private var editingJSON = false
    @State private var json = ""
    @State private var previewPresentation: ImportPreviewPresentation?
    @State private var error: String?
    private func stage(_ data: Data) {
        do { previewPresentation = ImportPreviewPresentation(preview: try CustomLayoutImportPreview.parse(data)); error = nil }
        catch { previewPresentation = nil; self.error = error.localizedDescription }
    }
    @discardableResult private func save(_ next: CustomKeyboardLibrary) -> Bool {
        do {
            let defaults = KeyboardSettings.appDefaults
            guard defaults.data(forKey: CustomKeyboardLibrary.storageKey) == baseline else {
                throw PersonalDataError("別の画面で配列が変更されています。開き直してください")
            }
            let decoded = try next.layouts()
            try next.save(defaults: defaults)
            library = next; layouts = decoded
            baseline = defaults.data(forKey: CustomKeyboardLibrary.storageKey)
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    var body: some View {
        NavigationStack {
            List {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--sumire-test-export-keyboard-state") {
                    Section {
                        Text(loaded ? keyboardUITestState : "loading")
                            .accessibilityIdentifier("sumire-test-keyboard-state")
                    }
                }
#endif
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    NavigationLink("新しい配列を作成") {
                        CustomLayoutEditorView(layout: nil, allLayouts: layouts) { layout in
                            do { var next = library; try next.append([layout]); if next.activeID == nil { next.activeID = layout.id }; return save(next) }
                            catch { self.error = error.localizedDescription; return false }
                        }
                    }.disabled(!loaded)
                    Button("配列JSONファイルを取り込む") { importing = true }.disabled(!loaded)
                    Button("配列JSONを入力") { json = ""; editingJSON = true }.disabled(!loaded)
                    Text("プレビューからキー配置を編集できます。標準・二段フリック、方向別の長押し、ドーナツ入力の文字や操作も設定できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("入力モード") {
                    Toggle("配列ごとに入力モードを記憶", isOn: $rememberInputMode)
                        .accessibilityIdentifier("customRememberInputMode")
                    Toggle("直接入力への切替後、次の入力で未確定文字を置換", isOn: $replaceComposingOnDirectInput)
                        .accessibilityIdentifier("customReplaceComposing")
                    Text("通常は直接入力へ切り替えた時点で未確定表示を確定します。置換を有効にすると、次の直接入力まで未確定文字を保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("選択する配列") {
                    Picker("カスタム配列", selection: Binding(get: { library.activeID }, set: { value in
                        var next = library; next.activeID = value; save(next)
                    })) {
                        Text("未選択").tag(String?.none)
                        ForEach(layouts) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!loaded).accessibilityIdentifier("selectedCustomLayout")
                }
                Section("保存した配列") {
                    ForEach(layouts) { layout in
                        NavigationLink(layout.name) {
                            CustomLayoutDetails(layout: layout, allLayouts: layouts) {
                                var next = library
                                do { try next.remove(id: layout.id); return save(next) }
                                catch { self.error = error.localizedDescription; return false }
                            }
                            .toolbar {
                                NavigationLink("編集") {
                                    CustomLayoutEditorView(layout: layout, allLayouts: layouts) { edited in
                                        do { var next = library; try next.replace(edited); return save(next) }
                                        catch { self.error = error.localizedDescription; return false }
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("custom-layout-definition:" + layout.id)
                    }
                }
            }
            .navigationTitle("Custom Keyboard")
            .toolbar { Button("完了") { dismiss() } }
            .onAppear {
                do {
                    library = try CustomKeyboardLibrary.load(defaults: KeyboardSettings.appDefaults)
                    layouts = try library.layouts()
                    baseline = KeyboardSettings.appDefaults.data(forKey: CustomKeyboardLibrary.storageKey)
#if DEBUG
                    let testDefaults = KeyboardSettings.appDefaults
                    let restoreStatus = testDefaults.string(forKey: KeyboardUITestSettingsSnapshot.restoreStatusKey) ?? "none"
                    keyboardUITestState = restoreStatus + "|" + KeyboardUITestSettingsSnapshot.capture(defaults: testDefaults).fingerprint
                    testDefaults.removeObject(forKey: KeyboardUITestSettingsSnapshot.restoreStatusKey)
                    _ = testDefaults.synchronize()
#endif
                    loaded = true
                } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $editingJSON, onDismiss: {
                if !json.isEmpty { stage(Data(json.utf8)) }
            }) {
                NavigationStack {
                    LayoutJSONEditor(text: $json)
                        .accessibilityIdentifier("customLayoutJSON").padding()
                        .navigationTitle("配列JSON")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { json = ""; editingJSON = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("内容を検証") { editingJSON = false } }
                        }
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
                    while let chunk = try handle.read(upToCount: min(65536, CustomKeyboardLibrary.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= CustomKeyboardLibrary.maximumBytes else { throw PersonalDataError("配列JSONが大きすぎます") }
                    }
                    stage(data)
                } catch { self.error = error.localizedDescription }
            }
            .sheet(item: $previewPresentation) { presentation in
                let preview = presentation.preview
                NavigationStack {
                    List {
                        Text("有効：\(preview.layouts.count)件／不正：\(preview.errors.count)件")
                        ForEach(preview.layouts) { layout in
                            NavigationLink(layout.name) { CustomLayoutDetails(layout: layout, allLayouts: layouts + preview.layouts, remove: nil) }
                        }
                        ForEach(Array((preview.errors + preview.warnings).enumerated()), id: \.offset) { _, text in Text(text) }
                        if let error { Text(error).foregroundStyle(.red) }
                        Button("有効な配列を追加") {
                            do {
                                var next = library; try next.append(preview.layouts)
                                if save(next) { previewPresentation = nil }
                            } catch { self.error = error.localizedDescription }
                        }.disabled(preview.layouts.isEmpty)
                    }
                    .navigationTitle("配列の取り込み確認")
                    .toolbar { Button("キャンセル") { previewPresentation = nil } }
                }
            }
        }
    }
}

private struct ImportPreviewPresentation: Identifiable {
    let id = UUID()
    let preview: CustomLayoutImportPreview
}

#if DEBUG
struct KeyboardUITestSettingsSnapshot: Codable {
    static let storageKey = "sumire.test.keyboardSettingsSnapshot"
    static let restoreStatusKey = "sumire.test.keyboardSettingsRestoreStatus"

    let customKeyboardLibraryData: Data?
    let lastUsedKeyboardID: String?
    let keyboardSelectionExisted: Bool
    let keyboardSelectionData: Data?

    static func capture(defaults: UserDefaults) -> Self {
        Self(
            customKeyboardLibraryData: defaults.data(forKey: CustomKeyboardLibrary.storageKey),
            lastUsedKeyboardID: defaults.string(forKey: "keyboard.lastUsed"),
            keyboardSelectionExisted: defaults.object(forKey: KeyboardSelection.storageKey) != nil,
            keyboardSelectionData: defaults.data(forKey: KeyboardSelection.storageKey)
        )
    }

    var fingerprint: String {
        "custom=\(Self.digest(customKeyboardLibraryData));last=\(Self.digest(lastUsedKeyboardID));selection=\(keyboardSelectionExisted ? "present" : "absent"),\(Self.digest(keyboardSelectionData))"
    }

    private static func digest(_ data: Data?) -> String {
        guard let data else { return "none" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ value: String?) -> String {
        guard let value else { return "none" }
        return digest(Data(value.utf8))
    }

    func restore(defaults: UserDefaults) throws {
        if let customKeyboardLibraryData {
            defaults.set(customKeyboardLibraryData, forKey: CustomKeyboardLibrary.storageKey)
        } else {
            defaults.removeObject(forKey: CustomKeyboardLibrary.storageKey)
        }

        if keyboardSelectionExisted {
            guard let keyboardSelectionData else {
                throw PersonalDataError("キーボード選択状態を復元できません")
            }
            defaults.set(keyboardSelectionData, forKey: KeyboardSelection.storageKey)
        } else {
            defaults.removeObject(forKey: KeyboardSelection.storageKey)
        }

        if let lastUsedKeyboardID {
            defaults.set(lastUsedKeyboardID, forKey: "keyboard.lastUsed")
        } else {
            defaults.removeObject(forKey: "keyboard.lastUsed")
        }
    }
}
#endif

private struct CustomLayoutDetails: View {
    @Environment(\.dismiss) private var dismiss
    let layout: ImportedCustomLayout
    let allLayouts: [ImportedCustomLayout]
    let remove: (() -> Bool)?
    @State private var confirmDelete = false
    var body: some View {
        List {
            Text("\(layout.rows)行 × \(layout.columns)列／\(layout.placements.filter { !$0.isSpacer }.count)キー")
            GeometryReader { geometry in
                ForEach(layout.placements.indices, id: \.self) { index in
                    CustomLayoutPreviewKey(key: layout.placements[index],
                        unitSize: CGSize(width: geometry.size.width / CGFloat(layout.columns * 2),
                                         height: geometry.size.height / CGFloat(layout.rows * 2)))
                }
            }.frame(height: 220)
            Section("未対応・未解決の操作") {
                let review = CustomLayoutActionReview(layouts: allLayouts).unsupported.filter { $0.layoutID == layout.id }
                if review.isEmpty { Text("現在の操作検査では検出されませんでした。全ジェスチャーの互換性確認は未完了です。") }
                ForEach(Array(review.enumerated()), id: \.offset) { _, item in
                    if case .unsupported(let raw, let reason) = item.action {
                        Text("\(item.keyID)・\(item.location)\n\(raw)\n\(reason)")
                    }
                }
            }
            if remove != nil { Button("この配列を削除", role: .destructive) { confirmDelete = true } }
        }
        .navigationTitle(layout.name)
        .confirmationDialog("この配列を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除する", role: .destructive) { if remove?() == true { dismiss() } }
        }
    }
}

private struct LayoutJSONEditor: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.accessibilityIdentifier = "customLayoutJSON"
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LayoutJSONEditor
        init(_ parent: LayoutJSONEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

private struct CustomLayoutPreviewKey: View {
    let key: ImportedCustomLayout.Placement
    let unitSize: CGSize
    var body: some View {
        let width = max(CGFloat.zero, unitSize.width * CGFloat(key.width) - 3)
        let height = max(CGFloat.zero, unitSize.height * CGFloat(key.height) - 3)
        let x = unitSize.width * (CGFloat(key.column) + CGFloat(key.width) / 2)
        let y = unitSize.height * (CGFloat(key.row) + CGFloat(key.height) / 2)
        if !key.isSpacer {
            Text(key.source["key"]?["label"]?.string ?? "")
                .font(.caption).lineLimit(2).frame(width: width, height: height)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                .position(x: x, y: y)
        }
    }
}
