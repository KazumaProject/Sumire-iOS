import SwiftUI
import SumireCore

struct KeyboardToolbarSettingsView: View {
    @State private var actions = KeyboardToolbarPreferences.defaultActions
    @State private var editMode: EditMode = .inactive

    private var availableActions: [KeyboardToolbarAction] {
        KeyboardToolbarAction.allCases.filter { !actions.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("キーボードに表示") {
                    ForEach(actions) { action in
                        Label(action.title, systemImage: action.symbolName)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: remove)
                    .deleteDisabled(actions.count == 1)
                }

                if !availableActions.isEmpty {
                    Section("追加できる操作") {
                        ForEach(availableActions) { action in
                            Button {
                                actions.append(action)
                                save()
                            } label: {
                                Label(action.title, systemImage: "plus.circle")
                            }
                        }
                    }
                }

                Section {
                    Text("表示中の操作は、入力中の候補欄が表示されていない時に使えます。並べ替えは右上の「編集」から行えます。Androidバックアップのツールバーは、iOSに対応する操作だけを順序を保って取り込みます。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("ツールバーの項目と順序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
            .onAppear {
                actions = KeyboardToolbarPreferences.load(defaults: KeyboardSettings.appDefaults)
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func remove(at offsets: IndexSet) {
        guard actions.count - offsets.count >= 1 else { return }
        actions.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        actions = KeyboardToolbarPreferences.save(actions, defaults: KeyboardSettings.appDefaults)
    }
}
