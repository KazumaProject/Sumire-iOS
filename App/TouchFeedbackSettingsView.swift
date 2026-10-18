import SwiftUI
import SumireCore

struct TouchFeedbackSettingsView: View {
    @State private var settings = TouchFeedbackSettings.load(defaults: KeyboardSettings.appDefaults)
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
            Section {
                Button("標準に戻す") { settings = TouchFeedbackSettings() }
            }
        }
        .navigationTitle("入力の操作と表示")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, value in value.save(defaults: KeyboardSettings.appDefaults) }
    }
}
