import SwiftUI
import UIKit
import SumireCore

struct ThemeSettingsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @State private var theme = KeyboardTheme.load(defaults: KeyboardSettings.appDefaults)

    var body: some View {
        Form {
            Section("Material 3 の配色") {
                HStack(spacing: 12) {
                    ForEach(Array(Self.seeds.enumerated()), id: \.offset) { index, seed in
                        Button { selectSeed(Color(red: seed.1.red, green: seed.1.green, blue: seed.1.blue)) } label: {
                            Circle().fill(color(seed.1)).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(seed.0)
                        .accessibilityIdentifier("theme-preset-\(index)")
                    }
                }
                ColorPicker("基準色", selection: seedColor, supportsOpacity: false)
                    .accessibilityIdentifier("theme-seed-color")
                Picker("表示モード", selection: $theme.mode) {
                    ForEach(KeyboardColorMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("keyboardColorMode")
                Text("基準色から、背景・キー・変換候補の配色をつくります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("配色のプレビュー") {
                preview
            }
            Section {
                Button("標準の配色に戻す") { theme = KeyboardTheme() }
                Text("「システム」は端末のライト／ダーク設定に合わせます。")
                    .font(.footnote).foregroundStyle(.secondary)
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
        }, set: selectSeed)
    }

    private static let seeds: [(String, KeyboardThemeTone)] = [
        ("すみれ", .init(argb: 0xff67_50a4)), ("空", .init(argb: 0xff00_65a3)),
        ("若葉", .init(argb: 0xff38_6a20)), ("珊瑚", .init(argb: 0xffba_3b46)),
        ("蜜柑", .init(argb: 0xff8b_5000)), ("桜", .init(argb: 0xff9a_405a)),
        ("墨", .init(argb: 0xff60_6060))
    ]

    private func selectSeed(_ color: Color) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return }
        theme = KeyboardTheme(hue: Double(hue), mode: theme.mode,
                              saturation: Double(saturation), brightness: Double(brightness))
    }

    private var preview: some View {
        let tones = theme.tones(dark: dark)
        return VStack(spacing: 8) {
            HStack {
                Text("選択候補")
                    .foregroundStyle(color(tones.accentForeground))
                    .padding(10)
                    .background(color(tones.accent), in: RoundedRectangle(cornerRadius: 8))
                Text("変換候補").foregroundStyle(color(tones.foreground))
                Spacer()
            }
            HStack(spacing: 8) {
                sampleKey("あ", tone: tones.key, text: tones.foreground)
                sampleKey("か", tone: tones.key, text: tones.foreground)
                sampleKey("削除", tone: tones.function, text: tones.foreground)
            }
            Text("通常キー ／ 特殊キー")
                .font(.caption).foregroundStyle(color(tones.foreground))
        }
        .padding(12)
        .background(color(tones.background), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("theme-preview")
    }

    private func sampleKey(_ title: String, tone: KeyboardThemeTone, text: KeyboardThemeTone) -> some View {
        Text(title).font(.title3)
            .foregroundStyle(color(text))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(color(tone), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ tone: KeyboardThemeTone) -> Color {
        Color(red: tone.red, green: tone.green, blue: tone.blue)
    }
}
