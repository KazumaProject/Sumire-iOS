import SwiftUI
import SumireCore

struct CircularSlotSettingsView: View {
    @State private var settings = CircularSlotSetting.load(defaults: KeyboardSettings.appDefaults)
    @State private var mode = 0
    @State private var arrangement = SumireKeyArrangement.toggle
    @State private var keys: [ReferenceFlickMaps.Key] = []
    @State private var keyIdentifier = ""
    @State private var loadError: String?
    var body: some View {
        Form {
            Section("編集するキー") {
                Picker("文字モード", selection: $mode) {
                    Text("日本語").tag(0); Text("英字").tag(1); Text("数字・記号").tag(2)
                }
                Picker("配列", selection: $arrangement) {
                    ForEach(SumireKeyArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("キー", selection: $keyIdentifier) {
                    ForEach(keys, id: \.label) { key in Text(key.label).tag(key.keyId ?? key.label) }
                }
            }
            if let loadError { Text(loadError).foregroundStyle(.red) }
            if !keyIdentifier.isEmpty {
                ForEach(4...6, id: \.self) { slot in
                    Section("追加方向 \(slot + 1)") {
                        Picker("操作", selection: setting(slot).action) {
                            ForEach(CircularSlotSetting.Action.allCases, id: \.self) { Text(title($0)).tag($0) }
                        }
                        if setting(slot).wrappedValue.action == .inputText {
                            TextField("入力する文字", text: setting(slot).value)
                        }
                    }
                }
            }
            Section {
                Text("分割数を5〜7にすると追加方向を使用できます。未設定の追加方向は除外されます。「マップ切替」は同じキーの小書き文字・濁音などの定義へ切り替えます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ドーナツの追加方向")
        .task(id: "\(mode)-\(arrangement.rawValue)") { loadKeys() }
        .onChange(of: settings) { _, values in
            if !CircularSlotSetting.save(values, defaults: KeyboardSettings.appDefaults) {
                loadError = "設定の容量上限を超えたため保存できませんでした。入力文字を短くしてください。"
            }
        }
    }
    private func loadKeys() {
        do {
            let profile = try ReferenceFlickMaps(arrangement: arrangement, mode: TenKeyMode(rawValue: mode) ?? .japanese, style: .donut)
            keys = profile.keys.filter { !$0.isSpecialKey && $0.keyType == "CIRCULAR_FLICK" && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            if !keys.contains(where: { ($0.keyId ?? $0.label) == keyIdentifier }) { keyIdentifier = keys.first.map { $0.keyId ?? $0.label } ?? "" }
            loadError = nil
        } catch { keys = []; keyIdentifier = ""; loadError = error.localizedDescription }
    }
    private func setting(_ slot: Int) -> Binding<CircularSlotSetting> {
        Binding(get: {
            settings.last { $0.mode == mode && $0.keyIdentifier == keyIdentifier && $0.slot == slot }
                ?? CircularSlotSetting(mode: mode, keyIdentifier: keyIdentifier, slot: slot)
        }, set: { value in
            settings.removeAll { $0.mode == mode && $0.keyIdentifier == keyIdentifier && $0.slot == slot }
            settings.append(value)
        })
    }
    private func title(_ action: CircularSlotSetting.Action) -> String {
        switch action {
        case .none: return "なし"
        case .inputText: return "文字を入力"
        case .showEmoji: return "記号キーボード"
        case .nextIME: return "次のキーボード"
        case .kana: return "日本語へ切替"
        case .english: return "英字へ切替"
        case .number: return "数字・記号へ切替"
        case .switchMap: return "マップ切替"
        }
    }
}
