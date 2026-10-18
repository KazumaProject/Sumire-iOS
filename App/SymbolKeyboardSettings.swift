import SwiftUI
import SumireCore

struct SymbolKeyboardSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SymbolKeyboardMode.initialModeKey, store: KeyboardSettings.appDefaults) private var initialMode = SymbolKeyboardMode.emoji.rawValue
    @AppStorage(EmojiSkinTone.settingsKey, store: KeyboardSettings.appDefaults) private var skinTone = EmojiSkinTone.standard.rawValue
    @AppStorage(ClipboardHistorySettings.enabledKey, store: KeyboardSettings.appDefaults) private var historyEnabled = false
    @AppStorage("clipboard.expirationEnabled", store: KeyboardSettings.appDefaults) private var expirationEnabled = false
    @AppStorage("clipboard.retentionHours", store: KeyboardSettings.appDefaults) private var retentionHours = 1
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("記号キーボード") {
                    Picker("最初に開くタブ", selection: $initialMode) {
                        ForEach(SymbolKeyboardMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("symbol-initial-mode")
                    Picker("絵文字の既定の肌色", selection: $skinTone) {
                        ForEach(EmojiSkinTone.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("symbol-default-skin-tone")
                    Text("対応する絵文字の長押しでも肌色を変更できます。履歴にある絵文字は、選んだときの肌色を保ちます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("クリップボード履歴") {
                    Toggle("文字・画像の履歴を保存", isOn: $historyEnabled)
                        .accessibilityIdentifier("clipboard-history-enabled")
                    Text("初期値はOFFです。OFFにしても既存の履歴は残ります。保存されるのは、ペーストボタンなどで読み込んだ内容です。自動表示をONにしている場合は、その読み込み内容も対象になります。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("ピン留めしていない履歴を期限で削除", isOn: $expirationEnabled)
                    Stepper("保持時間：\(retentionHours)時間", value: $retentionHours, in: 1...72).disabled(!expirationEnabled)
                    Text("期限削除は履歴を開くときに行います。最大100件・本文合計32MiBを超えると古い未ピン留め項目を削除します。画像は4MiB・400万画素までです。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("画像を選ぶと端末内のクリップボードに戻します。画像の挿入は入力先の貼り付けメニューを使ってください。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("すべてのクリップボード履歴を削除", role: .destructive) { confirmClear = true }.disabled(clearing)
                    if let notice { Text(notice).font(.footnote) }
                }
            }
            .navigationTitle("記号・クリップボード")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .confirmationDialog("ピン留めを含むすべてのクリップボード履歴を削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    clearing = true
                    let url = PersonalDataLocation.clipboardURL(allowShared: true)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let message: String
                        do { try ClipboardHistoryStore(url: url).clear(); message = "履歴を削除しました" }
                        catch { message = error.localizedDescription }
                        DispatchQueue.main.async { notice = message; clearing = false }
                    }
                }
            }
        }
    }
}
