import SwiftUI

struct DictionarySettings: View {
    @Binding var categoryMask: Int
    @Binding var englishReadingEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    private let names = ["address":"住所", "agreement":"条約・協定", "award":"賞", "character":"キャラクター",
                         "event":"出来事", "facility":"施設", "initiative":"事業・計画", "kampo":"漢方",
                         "lineage":"家系", "medical":"医学", "mythological_figure":"神話の人物", "organization":"組織",
                         "person":"人名", "place":"地名", "product":"製品", "station":"駅", "term":"用語",
                         "transport_route":"交通路線", "vehicle":"乗り物", "work_anime":"アニメ", "work_book":"書籍",
                         "work_film":"映画", "work_franchise":"作品シリーズ", "work_game":"ゲーム", "work_manga":"漫画",
                         "work_music":"音楽", "work_other":"その他の作品", "work_periodical":"定期刊行物",
                         "work_program":"番組", "work_stage":"舞台"]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("システム辞書は常に有効です。分類辞書は必要なものを選べます。")
                    Button("すべて有効") { categoryMask = 0x3fff_ffff }
                    Button("分類辞書をすべて無効") { categoryMask = 0 }
                }
                Section("英単語読み辞書") {
                    Toggle("かなから英単語を表示", isOn: $englishReadingEnabled)
                    Text("学習済み・ユーザー辞書の英単語は、この設定とは別に表示されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("分類辞書") {
                    ForEach(0..<Int(sumire_category_count()), id: \.self) { index in
                        let id = String(cString: sumire_category_name(index))
                        Toggle(names[id] ?? id, isOn: Binding(
                            get: { categoryMask & (1 << index) != 0 },
                            set: { enabled in
                                if enabled { categoryMask |= 1 << index }
                                else { categoryMask &= ~(1 << index) }
                            }))
                            .accessibilityIdentifier("category-" + id)
                    }
                }
            }
            .navigationTitle("辞書")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}
