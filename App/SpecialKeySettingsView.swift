import SwiftUI
import SumireCore

struct SpecialKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SumireSpecialKeySettings()
    @State private var arrangement = SumireKeyArrangement.toggle
    @State private var mode = TenKeyMode.japanese
    @State private var selectedKey = SumireSpecialKeyID.paste
    @State private var notice: String?
    @State private var loaded = false
    @State private var confirmResetAll = false
    private let defaults = KeyboardSettings.appDefaults

    var body: some View {
        NavigationStack {
            Form {
                Section("設定するキー") {
                    Picker("Sumire の配置", selection: $arrangement) {
                        ForEach(SumireKeyArrangement.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("special-key-arrangement")
                    Picker("入力モード", selection: $mode) {
                        Text("日本語").tag(TenKeyMode.japanese)
                        Text("英語").tag(TenKeyMode.english)
                        Text("数字").tag(TenKeyMode.number)
                    }.accessibilityIdentifier("special-key-mode")
                    Picker("キー", selection: $selectedKey) {
                        ForEach(keys, id: \.rawValue) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("special-key-selection")
                }.disabled(!loaded)
                Section("ジェスチャーごとの動作") {
                    ForEach(SumireSpecialKeyGesture.allCases, id: \.rawValue) { gesture in
                        Picker(gesture.title, selection: actionBinding(gesture)) {
                            Text("標準の動作").tag(Optional<SumireSpecialKeyAction>.none)
                            ForEach(SumireSpecialKeyAction.allCases, id: \.rawValue) { action in
                                Text(action.title).tag(Optional(action))
                            }
                        }.accessibilityIdentifier("special-key-gesture-" + gesture.rawValue)
                        let normal = SumireSpecialKeySettings.defaultAction(for: selectedKey, gesture: gesture, arrangement: arrangement, mode: mode)
                        let composing = SumireSpecialKeySettings.defaultAction(for: selectedKey, gesture: gesture, arrangement: arrangement, mode: mode, hasComposition: true)
                        Text(gesture == .longPress && selectedKey != .keyboardSwitch ? "標準：タップが削除・カーソル操作なら繰り返し、それ以外は何もしない" : normal == composing ? "標準：\(normal.title)" : "標準：未入力時は\(normal.title)、編集中は\(composing.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!loaded)
                Section {
                    Text("配置・入力モード・キーごとに保存します。「何もしない」でその操作を無効にできます。長押しの標準動作は、削除とカーソルの繰り返し、またはキーボード選択メニューです。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("このキーを標準に戻す") {
                        var next = settings
                        next.reset(key: selectedKey, arrangement: arrangement, mode: mode)
                        save(next)
                    }.disabled(!loaded)
                    Button("すべての特殊キーを標準に戻す", role: .destructive) { confirmResetAll = true }
                    if let notice { Text(notice).foregroundStyle(.red).accessibilityIdentifier("special-key-notice") }
                }
            }
            .navigationTitle("Sumire の特殊キー操作")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear {
                do { settings = try SumireSpecialKeySettings.load(defaults: defaults); loaded = true }
                catch { notice = error.localizedDescription; loaded = false }
                ensureSelectedKey()
            }
            .onChange(of: arrangement) { _, _ in ensureSelectedKey() }
            .onChange(of: mode) { _, _ in ensureSelectedKey() }
            .confirmationDialog("すべての特殊キー操作を標準に戻しますか？", isPresented: $confirmResetAll, titleVisibility: .visible) {
                Button("標準に戻す", role: .destructive) { save(SumireSpecialKeySettings()) }
            }
            .accessibilityIdentifier("special-key-settings")
        }
    }
    private var keys: [SumireSpecialKeyID] { SumireSpecialKeySettings.keys(arrangement: arrangement, mode: mode) }
    private func ensureSelectedKey() {
        if !keys.contains(selectedKey), let first = keys.first { selectedKey = first }
    }
    private func actionBinding(_ gesture: SumireSpecialKeyGesture) -> Binding<SumireSpecialKeyAction?> {
        Binding(get: {
            settings.assignedAction(for: selectedKey, gesture: gesture, arrangement: arrangement, mode: mode)
        }, set: { value in
            do {
                var next = settings
                try next.set(value, for: selectedKey, gesture: gesture, arrangement: arrangement, mode: mode)
                save(next)
            } catch { notice = error.localizedDescription }
        })
    }
    private func save(_ next: SumireSpecialKeySettings) {
        do { try next.save(defaults: defaults); settings = next; loaded = true; notice = nil }
        catch { notice = error.localizedDescription }
    }
}
