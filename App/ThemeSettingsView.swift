import SwiftUI
import UIKit
import SumireCore

struct ThemeSettingsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @State private var theme = KeyboardTheme.load(defaults: KeyboardSettings.appDefaults)

    var body: some View {
        Form {
            Section("基準色からの配色") {
                ColorPicker("基準色", selection: seedColor, supportsOpacity: false)
                    .accessibilityIdentifier("theme-seed-color")
                Picker("表示モード", selection: $theme.mode) {
                    ForEach(KeyboardColorMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("keyboardColorMode")
                Text("基準色から背景・通常キー・特殊キー・選択候補の色を生成します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("配色のプレビュー") {
                preview
            }
            Section {
                Button("標準の配色に戻す") { theme = KeyboardTheme() }
            }
        }
        .navigationTitle("キーボードの配色")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: theme) { _, value in value.save(defaults: KeyboardSettings.appDefaults) }
        .accessibilityIdentifier("theme-settings")
    }

    private var dark: Bool {
        theme.mode == .dark || (theme.mode == .system && systemScheme == .dark)
    }

    private var seedColor: Binding<Color> {
        Binding(get: {
            Color(hue: theme.hue, saturation: theme.saturation, brightness: theme.brightness)
        }, set: { color in
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return }
            theme = KeyboardTheme(hue: Double(hue), mode: theme.mode,
                                  saturation: Double(saturation), brightness: Double(brightness))
        })
    }

    private var preview: some View {
        let tones = theme.tones(dark: dark)
        return VStack(spacing: 8) {
            HStack {
                Text("選択候補")
                    .foregroundStyle(accentForeground(tones.accent))
                    .padding(10)
                    .background(color(tones.accent), in: RoundedRectangle(cornerRadius: 8))
                Text("変換候補").foregroundStyle(dark ? Color.white : Color.black)
                Spacer()
            }
            HStack(spacing: 8) {
                sampleKey("あ", tone: tones.key)
                sampleKey("か", tone: tones.key)
                sampleKey("削除", tone: tones.function)
            }
            Text("通常キー ／ 特殊キー")
                .font(.caption).foregroundStyle(dark ? Color.white : Color.black)
        }
        .padding(12)
        .background(color(tones.background), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("theme-preview")
    }

    private func sampleKey(_ title: String, tone: KeyboardThemeTone) -> some View {
        Text(title).font(.title3)
            .foregroundStyle(dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(color(tone), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ tone: KeyboardThemeTone) -> Color {
        Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness)
    }

    private func accentForeground(_ tone: KeyboardThemeTone) -> Color {
        let color = UIColor(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) > 0.179 ? .black : .white
    }
}
