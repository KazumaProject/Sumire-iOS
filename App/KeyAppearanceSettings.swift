import SwiftUI
import UIKit
import SumireCore

struct KeyAppearanceSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = KeyboardKind.sumire
    @State private var group = KeyboardKeyGroup.normal
    @State private var revision = 0
    @State private var sizingOrientation = KeyboardOrientation.portrait
    @State private var sizingSaveFailed = false
    @AppStorage("sumire.keyArrangement", store: KeyboardSettings.appDefaults) private var sumireArrangement = SumireKeyArrangement.toggle.rawValue
    private var sizingStore: KeyboardSizingStore {
        KeyboardSizingStore(defaults: KeyboardSettings.appDefaults)
    }
    private var currentKeyboardSize: KeyboardSize {
        sizingStore.load(sizingOrientation)
    }
    private var appearance: KeyboardAppearance {
        .load(kind, group: group, defaults: KeyboardSettings.appDefaults)
    }
    private var value: Binding<KeyboardAppearance> {
        Binding(get: { appearance }, set: {
            $0.save(kind, group: group, defaults: KeyboardSettings.appDefaults)
            revision += 1
        })
    }
    private func keyboardOption(_ name: String) -> Binding<Bool> {
        let key = "qwerty.\(kind.rawValue).\(name)"
        return Binding(get: { KeyboardSettings.appDefaults.bool(forKey: key) }, set: {
            KeyboardSettings.appDefaults.set($0, forKey: key); revision += 1
        })
    }
    private func sizeValue(_ keyPath: WritableKeyPath<KeyboardSize, Double>) -> Binding<Double> {
        Binding(get: { currentKeyboardSize[keyPath: keyPath] }, set: { newValue in
            var updated = currentKeyboardSize
            updated[keyPath: keyPath] = newValue
            do {
                try sizingStore.save(updated, for: sizingOrientation)
                revision += 1
            } catch {
                sizingSaveFailed = true
            }
        })
    }
    private func resetKeyboardSize() {
        sizingStore.reset(sizingOrientation)
        revision += 1
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("キーボード", selection: $kind) {
                    ForEach(KeyboardKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("appearanceKeyboardPicker")
                if kind == .sumire {
                    Picker("Sumireのキー配置", selection: $sumireArrangement) {
                        ForEach(SumireKeyArrangement.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.accessibilityIdentifier("sumireArrangementPicker")
                        .onChange(of: sumireArrangement) { _, _ in revision += 1 }
                }
                KeyboardAppearancePreview(kind: kind, revision: revision)
                    .frame(height: 300)
                    .accessibilityIdentifier("keyboardAppearancePreview")
                Picker("変更するキー", selection: $group) {
                    ForEach(KeyboardKeyGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal)
                Form {
                    Section("キーボード全体のサイズ") {
                        Picker("画面の向き", selection: $sizingOrientation) {
                            Text("縦向き").tag(KeyboardOrientation.portrait)
                            Text("横向き").tag(KeyboardOrientation.landscape)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("keyboardSizingOrientationPicker")

                        Button("この向きのサイズを標準に戻す", action: resetKeyboardSize)
                            .accessibilityIdentifier("resetKeyboardSizeForOrientationButton")

                        Text("高さ：\(Int(currentKeyboardSize.height)) pt")
                            .accessibilityIdentifier("keyboardSizeHeightValue")
                        Slider(value: sizeValue(\.height), in: 160...600, step: 1)
                            .accessibilityLabel("キーボード高さ")
                            .accessibilityIdentifier("keyboardSizeHeightSlider")

                        Text("幅：\(Int(currentKeyboardSize.width * 100))%")
                            .accessibilityIdentifier("keyboardSizeWidthValue")
                        Slider(value: sizeValue(\.width), in: 0.5...1, step: 0.01)
                            .accessibilityLabel("キーボード幅")
                            .accessibilityIdentifier("keyboardSizeWidthSlider")

                        Text("横位置：余白の左から\(Int(currentKeyboardSize.alignment * 100))%")
                            .accessibilityIdentifier("keyboardSizeAlignmentValue")
                        HStack {
                            Text("左")
                            Slider(value: sizeValue(\.alignment), in: 0...1, step: 0.01)
                                .accessibilityLabel("キーボードの横位置")
                                .accessibilityIdentifier("keyboardSizeAlignmentSlider")
                                .disabled(currentKeyboardSize.width >= 1)
                            Text("右")
                        }

                        Text("すべてのキーボード種類に共通で、縦向きと横向きに別々に保存します。キー領域の高さです。候補欄と画面下端の余白は別に加算されます。ホスト側の高さが足りない場合、指定値より小さく表示されることがあります。幅が100%の場合、横位置は適用されません。上のプレビューはキーの見た目確認用で、全体サイズは反映しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if kind == .romaji || kind == .english {
                        Section("QWERTYフリック") {
                            Toggle("上フリックで記号を入力", isOn: keyboardOption("flickUp"))
                            Toggle("下フリックで大文字を入力", isOn: keyboardOption("flickDown"))
                            Text("初期値はOFFです。日本語配列の下フリックは全角文字になります。数字・記号ページでも使えます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if kind == .romaji {
                        Section("日本語QWERTYの入力文字") {
                            Toggle("数字を半角で入力", isOn: keyboardOption("halfWidthNumbers"))
                            Toggle("記号を半角で入力", isOn: keyboardOption("halfWidthSymbols"))
                            Text("通常入力と上フリックに適用します。下フリックの全角入力は維持します。初期値はOFFです。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section(group.title) {
                        Text("キーサイズ：\(Int(appearance.keyScale * 100))%")
                        Slider(value: value.keyScale, in: 0.7...1, step: 0.01).accessibilityLabel("キーサイズ")
                        Text("文字サイズ：\(Int(appearance.keyFontSize)) pt")
                        Slider(value: value.keyFontSize, in: 10...40, step: 1).accessibilityLabel("キー文字サイズ")
                    }
                    Section("キー内フリックガイド") {
                        Toggle("フリックガイドを表示", isOn: value.guidesVisible)
                        Text("ガイド文字：\(Int(appearance.guideFontSize)) pt")
                        Slider(value: value.guideFontSize, in: 8...22, step: 1).accessibilityLabel("ガイド文字サイズ")
                        Text("フリック操作のあるキーに表示します。初期値はOFFです。文字が収まらない場合は、保存値を変えずに中央文字とガイドを同じ比率で縮小します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("keyAppearanceSettingsForm")
            }
            .navigationTitle("キー・文字サイズ")
            .onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            .alert("サイズを保存できませんでした", isPresented: $sizingSaveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("設定を保存できませんでした。もう一度お試しください。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("標準に戻す") {
                        KeyboardAppearance.reset(kind, group: group, defaults: KeyboardSettings.appDefaults)
                        revision += 1
                    }.accessibilityLabel(group.title + "を標準値に戻す")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完了") { dismiss() } }
            }
        }
    }
}

private struct KeyboardAppearancePreview: UIViewRepresentable {
    let kind: KeyboardKind
    let revision: Int
    final class Coordinator {
        let surface = KeyboardSurface()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        let surface = context.coordinator.surface
        surface.configureAppearancePreview(kind, defaults: KeyboardSettings.appDefaults)
        host.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            surface.topAnchor.constraint(equalTo: host.topAnchor),
            surface.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.surface.configureAppearancePreview(kind, defaults: KeyboardSettings.appDefaults)
    }
}
