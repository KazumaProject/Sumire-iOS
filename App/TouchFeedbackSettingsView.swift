import SwiftUI
import SumireCore

struct TouchFeedbackSettingsView: View {
    @State private var settings = TouchFeedbackSettings.load(defaults: KeyboardSettings.appDefaults)
    @State private var keyFeedback = KeyFeedbackSettings.load(defaults: KeyboardSettings.appDefaults)
    var body: some View {
        Form {
            Section("標準フリックのポップアップ") {
                Toggle("押したキーの候補を表示", isOn: $settings.popupVisible)
                    .accessibilityIdentifier("feedback-popup-visible")
                Text("押したときに表示し、指を動かすと選択方向を強調します。指を離すと閉じます。")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("大きさ", value: "\(Int(settings.popupScalePercent))%")
                Slider(value: $settings.popupScalePercent, in: 50...200, step: 5)
                    .accessibilityIdentifier("feedback-popup-scale")
                LabeledContent("文字サイズ", value: "\(Int(settings.popupTextSize))")
                Slider(value: $settings.popupTextSize, in: 8...48, step: 1)
                    .accessibilityIdentifier("feedback-popup-font")
            }
            Section("二本指の操作") {
                Toggle("二本指の入力を独立して扱う", isOn: $settings.independentMultiTouch)
                    .accessibilityIdentifier("feedback-independent-touch")
                Text("オンでは異なるキーを指ごとに操作し、離した順に確定します。同じキーへの二本目のタッチは無視します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("長押し") {
                Stepper("判定時間：\(settings.longPressMilliseconds) ms", value: $settings.longPressMilliseconds, in: 100...2000, step: 50)
                    .accessibilityIdentifier("feedback-long-press-time")
            }
            Section("キー操作のフィードバック") {
                Toggle("振動を有効にする", isOn: $keyFeedback.isVibrationEnabled)
                    .accessibilityIdentifier("feedback-key-vibration-enabled")
                Picker("振動タイミング", selection: $keyFeedback.vibrationTiming) {
                    Text("押した時").tag(KeyFeedbackSettings.VibrationTiming.press)
                    Text("離した時").tag(KeyFeedbackSettings.VibrationTiming.release)
                    Text("押した時と離した時").tag(KeyFeedbackSettings.VibrationTiming.both)
                    if keyFeedback.vibrationTiming == .disabled {
                        Text("不明な値のため無効").tag(KeyFeedbackSettings.VibrationTiming.disabled)
                    }
                }
                .disabled(!keyFeedback.isVibrationEnabled)
                .accessibilityIdentifier("feedback-key-vibration-timing")
                Toggle("キー押下音を有効にする", isOn: $keyFeedback.isKeySoundEnabled)
                    .accessibilityIdentifier("feedback-key-sound-enabled")
                LabeledContent(
                    "キー押下音の音量",
                    value: keyFeedback.keySoundVolumePercent == 0
                        ? "システムデフォルト"
                        : "\(keyFeedback.keySoundVolumePercent)%"
                )
                Slider(
                    value: Binding(
                        get: { Double(keyFeedback.keySoundVolumePercent) },
                        set: { keyFeedback.keySoundVolumePercent = Int($0.rounded()) }
                    ),
                    in: 0...100,
                    step: 1
                )
                .disabled(!keyFeedback.isKeySoundEnabled)
                .accessibilityIdentifier("feedback-key-sound-volume")
                Text("音は押下時に再生します。音量0はiOS標準クリックを使い、iOS設定でキーボードクリックが有効な場合に再生します。1〜100%はキー種別ごとの合成音を使います。Full Access OFF時の拡張での設定反映は実機未検証です。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("feedback-key-runtime-active")
            }
            Section {
                Button("標準に戻す") {
                    settings = TouchFeedbackSettings()
                    keyFeedback = KeyFeedbackSettings()
                }
            }
        }
        .navigationTitle("入力の操作と表示")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, value in value.save(defaults: KeyboardSettings.appDefaults) }
        .onChange(of: keyFeedback) { _, value in value.save(defaults: KeyboardSettings.appDefaults) }
    }
}
