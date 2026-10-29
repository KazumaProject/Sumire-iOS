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
                        gestureRow(for: gesture)
                    }
                }.disabled(!loaded)
                Section {
                    Text("配置・入力モード・キーごとに保存します。「何もしない」でその操作を無効にできます。長押しでは削除・カーソル操作の繰り返し、空白キーでのカーソル移動、キーボード選択メニュー、日本語入力中のひらがな／全角カタカナ切り替え、文節変換中の区切り切り替えを利用できます。")
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
    @ViewBuilder
    private func gestureRow(for gesture: SumireSpecialKeyGesture) -> some View {
        Menu {
            Button("標準の動作") { setAction(nil, gesture: gesture) }
            ForEach(SumireSpecialKeyAction.allCases, id: \.rawValue) { action in
                actionMenuButton(action, gesture: gesture)
            }
        } label: {
            LabeledContent(gesture.title, value: selectedActionTitle(for: gesture))
        }.accessibilityIdentifier("special-key-gesture-" + gesture.rawValue)
        Text(defaultActionSummary(for: gesture))
            .font(.caption).foregroundStyle(.secondary)
        if let reason = selectedActionUnavailableReason(for: gesture) {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func actionMenuButton(_ action: SumireSpecialKeyAction,
                                  gesture: SumireSpecialKeyGesture) -> some View {
        let unavailable = action.unavailabilityReason(for: selectedKey, gesture: gesture, mode: mode) != nil
        return Button(action.title + (unavailable ? "（iOS で未対応）" : "")) {
            setAction(action, gesture: gesture)
        }.disabled(unavailable)
    }
    private func selectedActionTitle(for gesture: SumireSpecialKeyGesture) -> String {
        settings.assignedAction(for: selectedKey, gesture: gesture,
            arrangement: arrangement, mode: mode)?.title ?? "標準の動作"
    }
    private func defaultActionSummary(for gesture: SumireSpecialKeyGesture) -> String {
        let normal = standardAction(for: gesture, hasComposition: false)
        let composing = standardAction(for: gesture, hasComposition: true)
        if gesture == .longPress && selectedKey == .spaceConvert && mode == .japanese
            && settings.assignedAction(for: selectedKey, gesture: .tap,
                arrangement: arrangement, mode: mode) == nil {
            return "標準：未入力中は長押ししながら左右に動かしてカーソル移動、編集中はひらがな／全角カタカナ切替、文節変換中は区切り切替"
        }
        if gesture == .longPress && selectedKey != .keyboardSwitch {
            return normal == composing ? "標準：\(normal.title)" : "標準：未入力時は\(normal.title)、編集中は\(composing.title)"
        }
        return normal == composing ? "標準：\(normal.title)" : "標準：未入力時は\(normal.title)、編集中は\(composing.title)"
    }
    private func standardAction(for gesture: SumireSpecialKeyGesture,
                                hasComposition: Bool) -> SumireSpecialKeyAction {
        guard gesture == .longPress, selectedKey != .keyboardSwitch else {
            return SumireSpecialKeySettings.defaultAction(for: selectedKey, gesture: gesture,
                arrangement: arrangement, mode: mode, hasComposition: hasComposition)
        }
        let assignedTap = settings.assignedAction(for: selectedKey, gesture: .tap,
            arrangement: arrangement, mode: mode)
        let tap = assignedTap ?? SumireSpecialKeySettings.defaultAction(for: selectedKey, gesture: .tap,
            arrangement: arrangement, mode: mode, hasComposition: hasComposition)
        if selectedKey == .spaceConvert && mode == .japanese && assignedTap == nil {
            return hasComposition ? .cycleBunsetsuSplitPattern : .cursorMoveMode
        }
        return tap.isRepeatable ? tap : .doNothing
    }
    private func selectedActionUnavailableReason(for gesture: SumireSpecialKeyGesture) -> String? {
        let selected = settings.action(for: selectedKey, gesture: gesture,
            arrangement: arrangement, mode: mode)
        return selected.unavailabilityReason(for: selectedKey, gesture: gesture, mode: mode)
    }
    private var keys: [SumireSpecialKeyID] { SumireSpecialKeySettings.keys(arrangement: arrangement, mode: mode) }
    private func ensureSelectedKey() {
        if !keys.contains(selectedKey), let first = keys.first { selectedKey = first }
    }
    private func setAction(_ value: SumireSpecialKeyAction?, gesture: SumireSpecialKeyGesture) {
        if let reason = value?.unavailabilityReason(for: selectedKey, gesture: gesture, mode: mode) {
            notice = reason; return
        }
        do {
            var next = settings
            try next.set(value, for: selectedKey, gesture: gesture, arrangement: arrangement, mode: mode)
            save(next)
        } catch { notice = error.localizedDescription }
    }
    private func save(_ next: SumireSpecialKeySettings) {
        do { try next.save(defaults: defaults); settings = next; loaded = true; notice = nil }
        catch { notice = error.localizedDescription }
    }
}
