import SwiftUI
import SumireCore

/// Draft rows retain exported metadata; editing a field replaces only that field.
struct CustomGestureDraft: Equatable {
    static let types: [(String, String)] = [
        ("NORMAL", "通常キー"), ("STANDARD_FLICK", "標準フリック"),
        ("PETAL_FLICK", "花びらフリック"), ("CENTER_GUIDE_FLICK", "中央ガイドフリック"),
        ("CROSS_FLICK", "十字フリック"), ("TWO_STEP_FLICK", "二段フリック"),
        ("STICKY_TWO_STEP_FLICK", "二段フリック・方向を保持"),
        ("FLICK_LONG_PRESS", "方向別の長押し"), ("CIRCULAR_FLICK", "ドーナツ入力")]
    static let fieldNames = ["flicks", "longPressFlicks", "circularFlicks", "twoStepFlicks", "twoStepLongPressFlicks"]
    struct Row: Identifiable, Equatable {
        let id: UUID
        var source: LayoutJSON
        init(_ source: LayoutJSON) { id = UUID(); self.source = source }
        mutating func set(_ field: String, _ value: LayoutJSON) {
            guard case .object(var fields) = source else { return }
            fields[field] = value; source = .object(fields)
        }
    }
    var rows: [String: [Row]] = [:]
    var original: [String: [Row]] = [:]
    init(source: LayoutJSON? = nil) {
        for field in Self.fieldNames {
            rows[field] = (source?[field]?.array ?? []).map(Row.init)
        }
        original = rows
    }
    var changes: [String: [LayoutJSON]] {
        rows.filter { original[$0.key] != $0.value }.mapValues { $0.map(\.source) }
    }
    /// Validate only targets newly assigned by this editing session. Retained
    /// imported references may be unresolved and must survive unrelated edits.
    /// Row identity spans arrays so legacy circular materialization is unchanged.
    var newlyAssignedLayoutTargets: [LayoutJSON] {
        let originals = Dictionary(uniqueKeysWithValues: original.values.flatMap { $0 }.map { ($0.id, $0.source) })
        return rows.values.flatMap { $0 }.compactMap { row in
            guard row.source["actionType"]?.string == "MoveToCustomKeyboard" else { return nil }
            if let previous = originals[row.id],
               previous["actionType"] == row.source["actionType"],
               previous["actionValue"] == row.source["actionValue"] { return nil }
            return row.source
        }
    }
    static func fields(for type: String) -> [(String, String)] {
        switch type {
        case "CIRCULAR_FLICK": return [("circularFlicks", "配列と方向")]
        case "TWO_STEP_FLICK", "FLICK_LONG_PRESS":
            return [("twoStepFlicks", "通常入力"), ("twoStepLongPressFlicks", "長押し入力")]
        case "STICKY_TWO_STEP_FLICK": return [("twoStepFlicks", "通常入力")]
        case "PETAL_FLICK", "CROSS_FLICK":
            return [("flicks", "通常入力"), ("longPressFlicks", "長押し入力")]
        case "STANDARD_FLICK", "CENTER_GUIDE_FLICK": return [("flicks", "通常入力")]
        default: return []
        }
    }
    mutating func prepare(type: String, label: String) {
        guard let field = Self.fields(for: type).first?.0, rows[field, default: []].isEmpty else { return }
        if type == "CIRCULAR_FLICK", !(rows["flicks"] ?? []).isEmpty {
            // Older circular exports used FlickDirection. Materialize a native
            // editable map while preserving the original array and row metadata.
            let slots = ["TAP": "TAP", "UP": "SLOT_0", "UP_RIGHT_FAR": "SLOT_1", "DOWN": "SLOT_2",
                         "UP_LEFT_FAR": "SLOT_3", "UP_RIGHT": "SLOT_4", "UP_LEFT": "SLOT_5"]
            let legacy = rows["flicks", default: []]
            let converted = legacy.compactMap { row -> Row? in
                guard let direction = row.source["flickDirection"]?.string, let slot = slots[direction] else { return nil }
                var updated = row; updated.set("circularDirection", .string(slot)); return updated
            }
            // Invalid legacy rows stay untouched and are rejected by validation.
            if converted.count == legacy.count { rows[field] = converted }
            return
        }
        rows[field] = [Self.newRow(field: field, label: label)]
    }
    static func newRow(field: String, label: String = "") -> Row {
        switch field {
        case "twoStepFlicks", "twoStepLongPressFlicks":
            return Row(.object(["firstDirection": .string("TAP"), "secondDirection": .string("TAP"), "output": .string(label)]))
        case "longPressFlicks": return Row(.object(["flickDirection": .string("TAP"), "output": .string(label)]))
        default:
            let direction = field == "circularFlicks" ? "circularDirection" : "flickDirection"
            return Row(.object([direction: .string("TAP"), "stateIndex": .integer(0),
                                "actionType": .string("INPUT_TEXT"), "actionValue": .string(label)]))
        }
    }
}

struct CustomGestureEditorView: View {
    @Binding var draft: CustomGestureDraft
    let type: String
    let label: String
    let layouts: [ImportedCustomLayout]
    var body: some View {
        Form {
            Section {
                Text(instructions).font(.subheadline).foregroundStyle(.secondary)
            }
            if type == "TWO_STEP_FLICK" || type == "STICKY_TWO_STEP_FLICK", !draft.missingTwoStepStarts.isEmpty {
                Section("二段入力の開始方向") {
                    ForEach(draft.missingTwoStepStarts, id: \.self) { direction in
                        Button("「" + CustomGestureRowEditor.title(direction) + " → タップ」に「" + label + "」を追加") {
                            draft.addTwoStepStart(direction, output: label)
                        }
                    }
                    Text("開始方向の通常入力がないため、この方向の二段目には進めません。追加後に入力文字を編集できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if type == "CIRCULAR_FLICK" {
                Section {
                    NavigationLink("配列の順序・追加・削除") { CustomCircularMapOrder(draft: $draft) }
                    if draft.rows["circularFlicks", default: []].isEmpty, !draft.rows["flicks", default: []].isEmpty {
                        Button("旧形式のドーナツ割り当てを編集する") { draft.prepare(type: type, label: label) }
                        Text("旧形式の割り当てを新しい形式へ展開します。元の設定も保持します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(CustomGestureDraft.fields(for: type), id: \.0) { field, title in
                Section(title) {
                    ForEach(draft.rows[field, default: []]) { row in
                        NavigationLink {
                            CustomGestureRowEditor(row: rowBinding(field: field, id: row.id), field: field,
                                                   diagonalOnly: type == "FLICK_LONG_PRESS", layouts: layouts)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rowTitle(row.source, field: field))
                                Text(row.source["output"]?.string ?? row.source["actionValue"]?.string ?? "入力なし")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.accessibilityIdentifier("customGestureRow-" + field)
                    }.onDelete { offsets in draft.rows[field, default: []].remove(atOffsets: offsets) }
                    Button("割り当てを追加", systemImage: "plus") {
                        draft.rows[field, default: []].append(CustomGestureDraft.newRow(field: field))
                    }.accessibilityIdentifier("customGestureAdd-" + field)
                }
            }
            Section {
                Text("同じ配列・方向の重複は適用時に確認します。空文字の割り当ては入力しません。変更していない追加設定は保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("フリックの割り当て")
    }
    private var instructions: String {
        switch type {
        case "CIRCULAR_FLICK": return "配列番号ごとに、中央タップと周囲の位置へ文字や操作を割り当てます。「次のドーナツ配列」で順番に切り替えます。分割数は入力スタイル設定を使用し、分割数を超える位置には入力できません。"
        case "TWO_STEP_FLICK", "STICKY_TWO_STEP_FLICK": return "最初の方向と、その後の方向を選んで文字を割り当てます。斜めを含む9方向を使えます。二段目へ進む方向には「最初の方向 → タップ」の通常入力も設定してください。"
        case "FLICK_LONG_PRESS": return "方向ごとに通常入力と長押し入力を設定します。"
        case "STANDARD_FLICK", "CENTER_GUIDE_FLICK": return "フリックの文字・操作を方向ごとに設定します。配列番号が複数ある場合、最も小さい番号の配列を使います。この方式は長押し別入力を使用しません。"
        default: return "通常のフリックと長押し後の文字・操作を方向ごとに設定します。配列番号が複数ある場合、最も小さい番号の配列を使います。"
        }
    }
    private func rowBinding(field: String, id: UUID) -> Binding<CustomGestureDraft.Row> {
        Binding(get: { draft.rows[field]?.first { $0.id == id } ?? CustomGestureDraft.newRow(field: field) }, set: { updated in
            guard let index = draft.rows[field]?.firstIndex(where: { $0.id == id }) else { return }
            draft.rows[field]?[index] = updated
        })
    }
    private func rowTitle(_ source: LayoutJSON, field: String) -> String {
        if field == "circularFlicks" {
            return "配列 \((source["stateIndex"]?.integer ?? 0) + 1)・" + CustomGestureRowEditor.title(source["circularDirection"]?.string ?? "TAP")
        }
        if field.hasPrefix("twoStep") {
            return CustomGestureRowEditor.title(source["firstDirection"]?.string ?? "TAP") +
                " → " + CustomGestureRowEditor.title(source["secondDirection"]?.string ?? "TAP")
        }
        let state = field == "flicks" ? "配列 \((source["stateIndex"]?.integer ?? 0) + 1)・" : ""
        return state + CustomGestureRowEditor.singleTitle(source["flickDirection"]?.string ?? "TAP")
    }
}

private struct CustomGestureRowEditor: View {
    @Binding var row: CustomGestureDraft.Row
    let field: String
    let diagonalOnly: Bool
    let layouts: [ImportedCustomLayout]
    private let single = ["TAP", "UP_LEFT_FAR", "UP", "UP_RIGHT_FAR", "DOWN"]
    private let multi = ["TAP", "UP_LEFT", "UP", "UP_RIGHT", "LEFT", "RIGHT", "DOWN_LEFT", "DOWN", "DOWN_RIGHT"]
    private let circular = ["TAP"] + (0...6).map { "SLOT_\($0)" }
    private var actions: [(String, String)] {
        [("INPUT_TEXT", "文字入力")] + CustomCommandCatalog.selectableEntries.map { entry in
            (entry.flickType, entry.command == .moveCustomKeyboardTab && field == "circularFlicks"
                ? "次のドーナツ配列" : entry.title)
        } + [("MoveToCustomKeyboard", "カスタム配列へ切替")]
    }
    private var actionType: String { row.source["actionType"]?.string ?? "INPUT_TEXT" }
    var body: some View {
        Form {
            if field == "flicks" || field == "circularFlicks" {
                Stepper("配列番号：\((row.source["stateIndex"]?.integer ?? 0) + 1)", value: state, in: 0...4095)
                    .accessibilityIdentifier("customGestureState")
            }
            if field.hasPrefix("twoStep") {
                directionPicker(diagonalOnly ? "方向" : "最初の方向", key: "firstDirection", values: multi)
                if !diagonalOnly || row.source["firstDirection"] != row.source["secondDirection"] {
                    directionPicker("次の方向", key: "secondDirection", values: multi)
                }
                if diagonalOnly, row.source["firstDirection"] != row.source["secondDirection"] {
                    Text("この取り込み済みの割り当ては方向が一致せず、この入力方式では使用されません。")
                        .foregroundStyle(.secondary)
                    Button("最初の方向の割り当てに変更する") {
                        row.set("secondDirection", row.source["firstDirection"] ?? .string("TAP"))
                    }
                }
                if !diagonalOnly, row.source["firstDirection"]?.string == "TAP", row.source["secondDirection"]?.string != "TAP" {
                    Text("最初がタップの割り当ては二段目へ進みません。最初の方向を指定してください。")
                        .foregroundStyle(.secondary)
                }
            } else {
                directionPicker("方向", key: field == "circularFlicks" ? "circularDirection" : "flickDirection",
                                values: field == "circularFlicks" ? circular : single)
            }
            if field == "flicks" || field == "circularFlicks" {
                Picker("操作", selection: Binding(get: { CustomCommandCatalog.flickSelection(actionType) }, set: { choice in
                    guard choice != CustomCommandCatalog.flickSelection(actionType) else { return }
                    row.set("actionType", .string(choice))
                    let entry = CustomCommandCatalog.selectableEntries.first { $0.flickType == choice }
                    row.set("actionValue", .string(entry?.flickValue ?? ""))
                })) {
                    ForEach(actions, id: \.0) { value, title in
                        Text(value == "MoveCustomKeyboardTab" && field != "circularFlicks" ? "次のカスタム配列" : title).tag(value)
                    }
                    if !actions.contains(where: { $0.0 == CustomCommandCatalog.flickSelection(actionType) }) { Text("取り込み済み：" + actionType).tag(actionType) }
                }.accessibilityIdentifier("customGestureAction")
                if field == "circularFlicks", actionType == "MoveCustomKeyboardTab",
                   let value = row.source["actionValue"]?.string, value != "⇄" {
                    Text("取り込み済みの値では、次のカスタム配列へ切り替わります。")
                    Button("次のドーナツ配列の操作に変更する") { row.set("actionValue", .string("⇄")) }
                }
                if actionType == "MoveToCustomKeyboard" {
                    Picker("切替先", selection: string("actionValue")) {
                        Text("選択してください").tag("")
                        ForEach(layouts) { Text($0.name).tag($0.id) }
                        let current = row.source["actionValue"]?.string ?? ""
                        if !current.isEmpty, !layouts.contains(where: { $0.id == current }) { Text("取り込み済み：" + current).tag(current) }
                    }
                } else if actionType == "INPUT_TEXT" {
                    textField("入力する文字", key: "actionValue")
                } else if !actions.contains(where: { $0.0 == CustomCommandCatalog.flickSelection(actionType) }) {
                    textField("取り込み済みの値", key: "actionValue")
                }
            } else { textField("入力する文字", key: "output") }
        }.navigationTitle("割り当てを編集")
    }
    private var state: Binding<Int64> {
        Binding(get: { row.source["stateIndex"]?.integer ?? 0 }, set: { row.set("stateIndex", .integer($0)) })
    }
    private func string(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { row.source[key]?.string ?? fallback }, set: { value in
            row.set(key, .string(value))
            if diagonalOnly && key == "firstDirection" { row.set("secondDirection", .string(value)) }
            if key == "actionType", value == "MoveCustomKeyboardTab", field == "circularFlicks" { row.set("actionValue", .string("⇄")) }
        })
    }
    private func textField(_ title: String, key: String) -> some View {
        TextField(title, text: string(key)).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("customGestureOutput")
    }
    private func directionPicker(_ title: String, key: String, values: [String]) -> some View {
        Picker(title, selection: string(key, fallback: "TAP")) {
            ForEach(values, id: \.self) { Text(directionTitle($0)).tag($0) }
            if let current = row.source[key]?.string, !values.contains(current) { Text(directionTitle(current)).tag(current) }
        }.accessibilityIdentifier("customGestureDirection-" + key)
    }
    private func directionTitle(_ direction: String) -> String {
        field == "flicks" || field == "longPressFlicks" ? Self.singleTitle(direction) : Self.title(direction)
    }
    static func singleTitle(_ direction: String) -> String {
        if direction == "UP_LEFT" { return "左（旧形式）" }
        if direction == "UP_RIGHT" { return "右（旧形式）" }
        return title(direction)
    }
    static func title(_ direction: String) -> String {
        ["TAP": "タップ", "UP": "上", "DOWN": "下", "LEFT": "左", "RIGHT": "右",
         "UP_LEFT_FAR": "左", "UP_RIGHT_FAR": "右", "UP_LEFT": "左上", "UP_RIGHT": "右上",
         "DOWN_LEFT": "左下", "DOWN_RIGHT": "右下"][direction] ??
        (direction.hasPrefix("SLOT_") ? "位置 " + (Int(direction.dropFirst(5)).map { String($0 + 1) } ?? direction) : direction)
    }
}

private struct CustomCircularMapOrder: View {
    @Binding var draft: CustomGestureDraft
    private var states: [Int64] {
        Array(Set(draft.rows["circularFlicks", default: []].map { $0.source["stateIndex"]?.integer ?? 0 })).sorted()
    }
    var body: some View {
        List {
            Section {
                ForEach(states, id: \.self) { state in
                    Text("配列 \(state + 1)")
                }.onMove { offsets, destination in
                    var order = states; order.move(fromOffsets: offsets, toOffset: destination)
                    draft.reorderCircularMaps(order)
                }.onDelete { offsets in
                    let removed = Set(offsets.map { states[$0] })
                    draft.rows["circularFlicks", default: []].removeAll { removed.contains($0.source["stateIndex"]?.integer ?? 0) }
                }
                Button("配列を追加", systemImage: "plus") { draft.addCircularMap() }
                    .disabled((states.last ?? -1) >= 4095)
            } footer: {
                Text("編集から並び替え・削除できます。順序を変更すると配列番号を振り直します。各配列に「次のドーナツ配列」を割り当てるとキー上で切り替えられます。")
            }
        }.navigationTitle("ドーナツ配列").toolbar { EditButton() }
    }
}

extension CustomGestureDraft {
    mutating func addCircularMap() {
        let next = (rows["circularFlicks", default: []].map { $0.source["stateIndex"]?.integer ?? 0 }.max() ?? -1) + 1
        guard next <= 4095 else { return }
        var row = Self.newRow(field: "circularFlicks")
        row.set("stateIndex", .integer(next)); rows["circularFlicks", default: []].append(row)
    }
    mutating func reorderCircularMaps(_ states: [Int64]) {
        let current = Set(rows["circularFlicks", default: []].map { $0.source["stateIndex"]?.integer ?? 0 })
        guard Set(states) == current, states.count == current.count else { return }
        let mapping = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element, Int64($0.offset)) })
        rows["circularFlicks"] = rows["circularFlicks", default: []].map { row in
            var updated = row
            if let index = mapping[row.source["stateIndex"]?.integer ?? 0] { updated.set("stateIndex", .integer(index)) }
            return updated
        }
    }
}

extension CustomGestureDraft {
    var missingTwoStepStarts: [String] {
        let normal = rows["twoStepFlicks", default: []]
        let starts = Set(normal.compactMap { row -> String? in
            guard let first = row.source["firstDirection"]?.string, first != "TAP",
                  row.source["secondDirection"]?.string != "TAP", row.source["output"]?.string?.isEmpty == false else { return nil }
            return first
        })
        return starts.filter { first in
            !normal.contains { $0.source["firstDirection"]?.string == first && $0.source["secondDirection"]?.string == "TAP" && $0.source["output"]?.string?.isEmpty == false }
        }.sorted()
    }
    mutating func addTwoStepStart(_ direction: String, output: String) {
        guard direction != "TAP" else { return }
        if let index = rows["twoStepFlicks", default: []].firstIndex(where: {
            $0.source["firstDirection"]?.string == direction && $0.source["secondDirection"]?.string == "TAP"
        }) {
            rows["twoStepFlicks"]?[index].set("output", .string(output))
        } else {
            rows["twoStepFlicks", default: []].append(Row(.object(["firstDirection": .string(direction), "secondDirection": .string("TAP"), "output": .string(output)])))
        }
    }
}
