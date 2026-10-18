import SwiftUI
import SumireCore

struct KeyboardSelectionSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var available: [(id: String, title: String)] = []
    @State private var selected: [String] = []
    @State private var notice: String?
    private let defaults = KeyboardSettings.appDefaults
    var body: some View {
        NavigationStack {
            List {
                Section("使用するキーボード（上から切り替え）") {
                    ForEach(selected, id: \.self) { id in
                        Text(available.first { $0.id == id }?.title ?? id)
                            .accessibilityIdentifier("keyboard-selection-row-" + id)
                            .deleteDisabled(selected.count == 1)
                    }
                    .onMove { from, to in
                        var next = selected; next.move(fromOffsets: from, toOffset: to); save(next)
                    }
                    .onDelete { offsets in
                        var next = selected; next.remove(atOffsets: offsets)
                        if !next.isEmpty { save(next) }
                    }
                }
                Section("追加") {
                    ForEach(available.filter { !selected.contains($0.id) }, id: \.id) { item in
                        Button(item.title, systemImage: "plus") { save(selected + [item.id]) }
                    }
                }
                Section {
                    Text("最後の1つは削除できません。リストから外してもカスタム配列の定義は残ります。")
                    if let notice { Text(notice).foregroundStyle(.red) }
                }
            }
            .navigationTitle("キーボードの選択・順序")
            .environment(\.editMode, .constant(.active))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear {
                available = [KeyboardKind.tenKey, .english, .gojuon, .sumire, .romaji].map { ("builtin:" + $0.rawValue, $0.title) } as [(String, String)]
                do {
                    let layouts = try CustomKeyboardLibrary.load(defaults: defaults).layouts()
                    available += layouts.map { ("custom:" + $0.id, $0.name) }
                } catch { notice = error.localizedDescription }
                selected = KeyboardSelection.load(defaults: defaults, available: available.map(\.id)).ids
            }
        }
    }
    private func save(_ ids: [String]) {
        do { try KeyboardSelection(ids: ids).save(defaults: defaults); selected = ids }
        catch { notice = error.localizedDescription }
    }
}
