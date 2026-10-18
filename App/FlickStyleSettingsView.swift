import SwiftUI
import SumireCore

struct FlickStyleSettingsView: View {
    @State private var settings = FlickStyleSettings.load(defaults: KeyboardSettings.appDefaults)
    var body: some View {
        Form {
            Section("スミレ入力") {
                Picker("入力スタイル", selection: $settings.style) {
                    Text("標準").tag(SumireFlickStyle.standard)
                    Text("サークル").tag(SumireFlickStyle.circle)
                    Text("二段フリック").tag(SumireFlickStyle.twoStep)
                    Text("三段フリック").tag(SumireFlickStyle.threeStep)
                    Text("中央ガイド").tag(SumireFlickStyle.centerGuide)
                    Text("ドーナツ").tag(SumireFlickStyle.donut)
                }.accessibilityIdentifier("sumire-flick-style")
                Text("各配列・文字モードの本家のキー定義を使用します。英字・数字など、選択したスタイルを使用しないキーもあります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("二段・三段フリック") {
                Picker("濁音・拗音の配置", selection: $settings.rotation) {
                    Text("標準").tag(FlickStyleSettings.Rotation.standard)
                    Text("時計回り").tag(FlickStyleSettings.Rotation.clockwise)
                    Text("反時計回り").tag(FlickStyleSettings.Rotation.counterclockwise)
                }
                Picker("斜め方向の判定", selection: $settings.diagonal) {
                    Text("従来").tag(FlickStyleSettings.Diagonal.legacy)
                    Text("安定").tag(FlickStyleSettings.Diagonal.stable)
                }
                Picker("ガイドの表示", selection: $settings.presentation) {
                    Text("従来のグリッド").tag(FlickStyleSettings.Presentation.legacyGrid)
                    Text("キー上のガイド").tag(FlickStyleSettings.Presentation.guideAboveKey)
                }
                Picker("フリックの開始位置", selection: $settings.startPosition) {
                    Text("タッチ位置").tag(FlickStyleSettings.StartPosition.touchPoint)
                    Text("キーの中央").tag(FlickStyleSettings.StartPosition.keyCenter)
                }
            }
            Section("三段フリック") {
                Picker("入力する文字", selection: $settings.threeStepInput) {
                    Text("すべて").tag(FlickStyleSettings.ThreeStepInput.all)
                    Text("拗音").tag(FlickStyleSettings.ThreeStepInput.contracted)
                    Text("濁音").tag(FlickStyleSettings.ThreeStepInput.voiced)
                }
                Stepper("濁音切替の角度余白：\(settings.hierarchicalModeAngleMargin)°", value: $settings.hierarchicalModeAngleMargin, in: 0...34)
            }
            Section("ドーナツ入力") {
                Stepper("分割数：\(settings.circularDirectionCount)", value: $settings.circularDirectionCount, in: 4...7)
                    .accessibilityIdentifier("sumire-donut-count")
                NavigationLink("追加方向の操作") { CircularSlotSettingsView() }
            }
            Button("標準に戻す") { settings = FlickStyleSettings() }
        }
        .navigationTitle("スミレ入力のスタイル")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, value in value.save(defaults: KeyboardSettings.appDefaults) }
    }
}
