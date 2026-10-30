import SwiftUI
import SumireCore

struct CustomLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: CustomLayoutEditor
    @State private var name: String
    @State private var rows: Int
    @State private var columns: Int
    @State private var romaji: Bool
    @State private var direct: Bool
    @State private var error: String?
    @State private var keyEditor: KeyDraft?
    @State private var dropTargetID: String?
    let allLayouts: [ImportedCustomLayout]
    let save: (ImportedCustomLayout) -> Bool
    init(layout: ImportedCustomLayout?, allLayouts: [ImportedCustomLayout], save: @escaping (ImportedCustomLayout) -> Bool) {
        _editor = State(initialValue: layout.map(CustomLayoutEditor.init(layout:)) ?? CustomLayoutEditor())
        _name = State(initialValue: layout?.name ?? "新しい配列")
        _rows = State(initialValue: layout?.rows ?? 4)
        _columns = State(initialValue: layout?.columns ?? 5)
        _romaji = State(initialValue: layout?.source["layout"]?["isRomaji"] == .bool(true))
        _direct = State(initialValue: layout?.source["layout"]?["isDirectMode"] == .bool(true))
        self.allLayouts = allLayouts
        self.save = save
    }
    private var layout: ImportedCustomLayout? { try? editor.validated() }

    private func targetKeyID(at location: CGPoint, excluding draggedID: String,
                            placements: [ImportedCustomLayout.Placement], previewSize: CGSize) -> String? {
        let unitWidth = previewSize.width / CGFloat(columns * 2)
        let unitHeight = previewSize.height / CGFloat(rows * 2)
        return placements.first { placement in
            guard placement.id != draggedID else { return false }
            let frame = CGRect(x: CGFloat(placement.column) * unitWidth,
                               y: CGFloat(placement.row) * unitHeight,
                               width: CGFloat(placement.width) * unitWidth,
                               height: CGFloat(placement.height) * unitHeight)
            return frame.contains(location)
        }?.id
    }

    private func targetKeyID(draggedID: String, translation: CGSize,
                            placements: [ImportedCustomLayout.Placement], previewSize: CGSize) -> String? {
        guard let dragged = placements.first(where: { $0.id == draggedID }) else { return nil }
        let unitWidth = previewSize.width / CGFloat(columns * 2)
        let unitHeight = previewSize.height / CGFloat(rows * 2)
        let start = CGPoint(x: (CGFloat(dragged.column) + CGFloat(dragged.width) / 2) * unitWidth,
                            y: (CGFloat(dragged.row) + CGFloat(dragged.height) / 2) * unitHeight)
        return targetKeyID(at: CGPoint(x: start.x + translation.width, y: start.y + translation.height),
                           excluding: draggedID, placements: placements, previewSize: previewSize)
    }

    private func swapKeys(draggedID: String, targetID: String) {
        guard draggedID != targetID else { return }
        do {
            var next = editor
            try next.swapKeyPlacements(draggedID: draggedID, targetID: targetID)
            editor = next
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            TextField("配列名", text: $name)
            Stepper("行数：\(rows)", value: $rows, in: 1...64)
            Stepper("列数：\(columns)", value: $columns, in: 1...64)
            Toggle("ローマ字をかなに変換", isOn: $romaji).disabled(direct)
            Toggle("直接入力する", isOn: $direct)
            if direct { Text("変換せず、確定した文字として挿入します。").font(.caption).foregroundStyle(.secondary) }
            if let layout {
                Section("プレビュー・キーを選択またはドラッグ") {
                    Text("キーをドラッグして別のキーに重ねると位置を交換できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        let keyPlacements = layout.placements.filter { !$0.isSpacer }
                        ForEach(keyPlacements, id: \.id) { key in
                            CustomEditablePreviewKey(key: key, containerWidth: geometry.size.width,
                                                     rows: rows, columns: columns,
                                                     isDropTargeted: dropTargetID == key.id,
                                                     select: { keyEditor = KeyDraft(key) },
                                                     dragChanged: { draggedID, translation in
                                dropTargetID = targetKeyID(draggedID: draggedID, translation: translation,
                                                           placements: keyPlacements, previewSize: geometry.size)
                            }, dragEnded: { draggedID, translation in
                                let targetID = targetKeyID(draggedID: draggedID, translation: translation,
                                                           placements: keyPlacements, previewSize: geometry.size)
                                dropTargetID = nil
                                if let targetID { swapKeys(draggedID: draggedID, targetID: targetID) }
                            })
                        }
                    }.frame(height: 220)
                }
                Section("キー") {
                    ForEach(layout.placements.filter { !$0.isSpacer }, id: \.id) { key in
                        Button(key.source["key"]?["label"]?.string ?? key.id) { keyEditor = KeyDraft(key) }
                    }
                    Button("キーを追加") { keyEditor = KeyDraft() }
                }
            }
            Text("位置と幅・高さは半キー単位です。取り込んだ追加ジェスチャーは保持します。未対応の入力方式を通常キーへ自動変更しません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("配列を編集")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        var next = editor; next.configure(name: name, rows: rows, columns: columns)
                        next.setInputMode(romaji: romaji, direct: direct)
                        if save(try next.validated()) { dismiss() }
                        else { error = "保存できませんでした。配列一覧のエラーを確認してください。" }
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .sheet(item: $keyEditor) { draft in
            CustomKeyEditor(draft: draft, rows: rows, columns: columns, allLayouts: allLayouts, apply: { draft in
                if draft.type == "NORMAL", draft.action.hasPrefix("MoveToCustomKeyboard:"),
                   case .unsupported = CustomKeyAction.tap(draft.action, targets: CustomLayoutTargets(layouts: allLayouts)) {
                    throw PersonalDataError("切替先の配列を選択してください")
                }
                var next = editor
                next.configure(name: name, rows: rows, columns: columns)
                next.putKey(id: draft.id, label: draft.label, action: draft.action, special: draft.special,
                            row: draft.row, column: draft.column, height: draft.height, width: draft.width)
                if draft.type != draft.originalType { try next.setKeyType(id: draft.id, type: draft.type) }
                if draft.doubleTapEnabled != draft.originalDoubleTapEnabled || draft.doubleTapAction != draft.originalDoubleTapAction {
                    if draft.doubleTapEnabled, draft.doubleTapAction.hasPrefix("MoveToCustomKeyboard:"),
                       case .unsupported = CustomKeyAction.tap(draft.doubleTapAction, targets: CustomLayoutTargets(layouts: allLayouts)) {
                        throw PersonalDataError("ダブルタップの切替先を選択してください")
                    }
                    try next.setDoubleTap(id: draft.id, enabled: draft.doubleTapEnabled, action: draft.doubleTapAction)
                }
                for row in draft.gestures.newlyAssignedLayoutTargets {
                    if case .unsupported = CustomKeyAction.flick(type: "MoveToCustomKeyboard",
                        value: row["actionValue"]?.string, targets: CustomLayoutTargets(layouts: allLayouts)) {
                        throw PersonalDataError("フリックの切替先の配列を選択してください")
                    }
                }
                if !draft.gestures.changes.isEmpty || draft.type != draft.originalType && draft.type != "NORMAL" {
                    try next.setGestureMappings(id: draft.id, fields: draft.gestures.changes)
                }
                _ = try next.validated()
                editor = next
            }, remove: {
                editor.removeKey(id: draft.id)
            })
        }
    }
}

private struct KeyDraft: Identifiable {
    var id = UUID().uuidString
    var label = "あ", action = "Text:あ", special = false
    var row = 0, column = 0, height = 2, width = 2
    var type = "NORMAL", originalType = "NORMAL"
    var gestures = CustomGestureDraft()
    var doubleTapEnabled = false, originalDoubleTapEnabled = false
    var doubleTapAction = "Text:", originalDoubleTapAction = "Text:"
    var existing = false
    init() {}
    init(_ key: ImportedCustomLayout.Placement) {
        id = key.id; label = key.source["key"]?["label"]?.string ?? ""
        action = key.source["key"]?["action"]?.string ?? "Text:" + label
        special = key.source["key"]?["isSpecialKey"] == .bool(true)
        let legacyShift = key.source["key"]?["doubleTapEnabled"] == nil && action == "ShiftKeyPressed"
        doubleTapAction = key.source["key"]?["doubleTapAction"]?.string ?? (legacyShift ? "CapLockKey" : "Text:")
        doubleTapEnabled = key.source["key"]?["doubleTapEnabled"] != .bool(false) &&
            (key.source["key"]?["doubleTapAction"]?.string != nil || legacyShift)
        originalDoubleTapEnabled = doubleTapEnabled; originalDoubleTapAction = doubleTapAction
        row = key.row; column = key.column; height = key.height; width = key.width; existing = true
        type = key.source["key"]?["keyType"]?.string ?? "NORMAL"; originalType = type
        gestures = CustomGestureDraft(source: key.source)
    }
}
private struct CustomKeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: KeyDraft
    let rows: Int, columns: Int
    let allLayouts: [ImportedCustomLayout]
    let apply: (KeyDraft) throws -> Void
    let remove: () -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                TextField("表示文字", text: $draft.label)
                Picker("入力方式", selection: $draft.type) {
                    ForEach(CustomGestureDraft.types, id: \.0) { value, title in Text(title).tag(value) }
                    if !CustomGestureDraft.types.contains(where: { $0.0 == draft.type }) {
                        Text("取り込み済みの方式を保持").tag(draft.type)
                    }
                }.accessibilityIdentifier("customKeyInputType")
                    .onChange(of: draft.type) { _, value in draft.gestures.prepare(type: value, label: draft.label) }
                if !CustomGestureDraft.fields(for: draft.type).isEmpty {
                    NavigationLink {
                        CustomGestureEditorView(draft: $draft.gestures, type: draft.type, label: draft.label, layouts: allLayouts)
                    } label: { Label("フリックの割り当て", systemImage: "hand.draw") }
                        .accessibilityIdentifier("customGestureEditor")
                } else {
                CustomTapActionPicker(title: "操作", raw: $draft.action, initialText: draft.label, accessibilityID: "customKeyAction")
                if draft.action.hasPrefix("MoveToCustomKeyboard:") {
                    Picker("切替先の配列", selection: Binding(get: { String(draft.action.dropFirst(21)) }, set: { draft.action = "MoveToCustomKeyboard:" + $0 })) {
                        Text("選択してください").tag("")
                        ForEach(allLayouts) { layout in Text(layout.name).tag(layout.id) }
                        let current = String(draft.action.dropFirst(21))
                        if !current.isEmpty, !allLayouts.contains(where: { $0.id == current }) {
                            Text("取り込み済みの切替先").tag(current)
                        }
                    }.pickerStyle(.navigationLink).accessibilityIdentifier("customKeyLayoutTarget")
                }
                if draft.action.hasPrefix("Text:") {
                    TextField("入力する文字", text: Binding(get: { String(draft.action.dropFirst(5)) }, set: { draft.action = "Text:" + $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                }
                Toggle("特殊キーの色・サイズを使う", isOn: $draft.special)
                if draft.special {
                    Section("ダブルタップ") {
                        Toggle("ダブルタップ操作を使う", isOn: $draft.doubleTapEnabled)
                            .accessibilityIdentifier("customDoubleTapEnabled")
                        if draft.doubleTapEnabled {
                            CustomTapActionPicker(title: "ダブルタップの操作", raw: $draft.doubleTapAction, initialText: "", accessibilityID: "customDoubleTapAction")
                            if draft.doubleTapAction.hasPrefix("Text:") {
                                TextField("ダブルタップで入力する文字", text: Binding(get: { String(draft.doubleTapAction.dropFirst(5)) }, set: { draft.doubleTapAction = "Text:" + $0 }))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else if draft.doubleTapAction.hasPrefix("MoveToCustomKeyboard:") {
                                Picker("ダブルタップの切替先", selection: Binding(get: { String(draft.doubleTapAction.dropFirst(21)) }, set: { draft.doubleTapAction = "MoveToCustomKeyboard:" + $0 })) {
                                    Text("選択してください").tag("")
                                    ForEach(allLayouts) { layout in Text(layout.name).tag(layout.id) }
                                    let current = String(draft.doubleTapAction.dropFirst(21))
                                    if !current.isEmpty, !allLayouts.contains(where: { $0.id == current }) { Text("取り込み済みの切替先").tag(current) }
                                }.pickerStyle(.navigationLink)
                            }
                            Text("通常のタップは2回目を待って実行します。文字キーの連続入力には適用しません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper("上から：\(draft.row) 半キー", value: $draft.row, in: 0...(rows * 2 - 1))
                Stepper("左から：\(draft.column) 半キー", value: $draft.column, in: 0...(columns * 2 - 1))
                    .accessibilityIdentifier("customKeyColumnPosition")
                Stepper("高さ：\(draft.height) 半キー", value: $draft.height, in: 1...(rows * 2))
                Stepper("幅：\(draft.width) 半キー", value: $draft.width, in: 1...(columns * 2))
                if draft.existing { Button("キーを削除", role: .destructive) { remove(); dismiss() } }
            }
            .navigationTitle("キーを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("適用") {
                    do { try apply(draft); dismiss() } catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}

private struct CustomEditablePreviewKey: View {
    let key: ImportedCustomLayout.Placement
    let containerWidth: CGFloat
    let rows: Int, columns: Int
    let isDropTargeted: Bool
    let select: () -> Void
    let dragChanged: (String, CGSize) -> Void
    let dragEnded: (String, CGSize) -> Void
    @GestureState private var dragTranslation = CGSize.zero
    @State private var isDragging = false

    init(key: ImportedCustomLayout.Placement, containerWidth: CGFloat, rows: Int, columns: Int,
         isDropTargeted: Bool, select: @escaping () -> Void,
         dragChanged: @escaping (String, CGSize) -> Void, dragEnded: @escaping (String, CGSize) -> Void) {
        self.key = key
        self.containerWidth = containerWidth
        self.rows = rows
        self.columns = columns
        self.isDropTargeted = isDropTargeted
        self.select = select
        self.dragChanged = dragChanged
        self.dragEnded = dragEnded
    }

    var body: some View {
        let unitWidth: CGFloat = containerWidth / CGFloat(columns * 2)
        let unitHeight: CGFloat = 220 / CGFloat(rows * 2)
        let width: CGFloat = max(1, unitWidth * CGFloat(key.width) - 3)
        let height: CGFloat = max(1, unitHeight * CGFloat(key.height) - 3)
        let x: CGFloat = unitWidth * (CGFloat(key.column) + CGFloat(key.width) / 2)
        let y: CGFloat = unitHeight * (CGFloat(key.row) + CGFloat(key.height) / 2)
        Button(key.source["key"]?["label"]?.string ?? "", action: select)
            .buttonStyle(.plain)
            .font(.caption).lineLimit(2)
            .frame(width: width, height: height)
            .background(Color.accentColor.opacity(isDropTargeted ? 0.4 : 0.15), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityIdentifier("customLayoutPreviewKey-\(key.id)")
            .accessibilityHint("別のキーへドラッグすると、キーの位置を交換します")
            .position(x: x, y: y)
            .offset(dragTranslation)
            .zIndex(isDragging ? 1 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onChanged { value in
                        isDragging = true
                        dragChanged(key.id, value.translation)
                    }
                    .onEnded { value in
                        isDragging = false
                        dragEnded(key.id, value.translation)
                    }
            )
    }
}

private struct CustomTapActionPicker: View {
    let title: String
    @Binding var raw: String
    let initialText: String
    let accessibilityID: String
    var body: some View {
        Picker(title, selection: Binding(get: { CustomCommandCatalog.tapSelection(raw) }, set: { choice in
            guard choice != CustomCommandCatalog.tapSelection(raw) else { return }
            raw = choice == "Text" ? "Text:" + initialText : choice == "InputText" ? "InputText:ひらがな小文字" :
                choice == "SwitchLayout" ? "MoveToCustomKeyboard:" : choice
        })) {
            Text("文字入力").tag("Text")
            Text("入力文字の修飾・記号操作").tag("InputText")
            ForEach(CustomCommandCatalog.selectableEntries) { Text($0.title).tag($0.tapRaw) }
            Text("カスタム配列に切り替え").tag("SwitchLayout")
            let selection = CustomCommandCatalog.tapSelection(raw)
            if !["Text", "InputText", "SwitchLayout"].contains(selection),
               !CustomCommandCatalog.selectableEntries.contains(where: { $0.tapRaw == selection }) {
                Text("取り込み済みの操作を保持：" + raw).tag(selection)
            }
        }.pickerStyle(.navigationLink).accessibilityIdentifier(accessibilityID)
        if raw.hasPrefix("InputText:") {
            Picker("入力文字への操作", selection: Binding(get: { String(raw.dropFirst(10)) }, set: { raw = "InputText:" + $0 })) {
                ForEach(CustomCommandCatalog.inputTextTokens, id: \.self) { Text($0).tag($0) }
                let value = String(raw.dropFirst(10))
                if !CustomCommandCatalog.inputTextTokens.contains(value) { Text("取り込み済み：" + value).tag(value) }
            }.pickerStyle(.navigationLink)
            Text("通常の文字入力とは異なり、直前の文字の修飾などを行います。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
