import SumireCore
import SwiftUI

struct PhysicalKeyboardShortcutSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var shortcuts: [PhysicalKeyboardShortcutItem] = []
  @State private var editor: EditorRoute?
  @State private var notice: String?
  @State private var isLoaded = false
  @State private var storageAvailable = false

  var body: some View {
    NavigationStack {
      List {
        if let notice {
          Section {
            Text(notice)
              .font(.footnote)
              .foregroundStyle(.red)
              .accessibilityIdentifier("physical-shortcuts-notice")
          }
        }

        Section("ショートカット") {
          ForEach(shortcuts, id: \.id) { item in
            HStack(spacing: 12) {
              Button {
                editor = EditorRoute(item: item)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(
                    "\(item.shortcutTitle(languageCode: locale.language.languageCode?.identifier))  ·  \(item.actionTitle)"
                  )
                  .foregroundStyle(.primary)
                  Text(PhysicalKeyboardShortcutContext.fromID(item.contextID).displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("physical-shortcut-edit-\(item.id)")

              Toggle(
                "有効",
                isOn: Binding(
                  get: { shortcuts.first(where: { $0.id == item.id })?.enabled ?? false },
                  set: { setEnabled($0, for: item.id) }
                )
              )
              .labelsHidden()
              .accessibilityLabel(
                "\(item.shortcutTitle(languageCode: locale.language.languageCode?.identifier))を有効"
              )
              .accessibilityIdentifier("physical-shortcut-enabled-\(item.id)")
            }
          }
        }

        Section {
          Text("保存した割り当ては、外付けキーボードから対応するキーが押されたときに実行します。対応しない操作はアプリに渡します。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .overlay {
        if !isLoaded {
          ProgressView("読み込み中")
        } else if shortcuts.isEmpty && notice == nil {
          ContentUnavailableView("割り当てがありません", systemImage: "keyboard")
        }
      }
      .navigationTitle("物理キーボード")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("追加", systemImage: "plus") { editor = EditorRoute(item: nil) }
            .disabled(!isLoaded || !storageAvailable)
            .accessibilityIdentifier("physical-shortcut-add")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("完了") { dismiss() }
        }
      }
      .onAppear {
        if !isLoaded { loadAndSeed() }
      }
      .sheet(item: $editor) { route in
        PhysicalKeyboardShortcutEditorView(
          item: route.item,
          onSave: save,
          onDelete: delete
        )
      }
    }
  }

  private func loadAndSeed() {
    guard let defaults = KeyboardSettings.sharedDefaults else {
      shortcuts = []
      storageAvailable = false
      notice = "ショートカットをキーボード拡張と共有するApp Groupsコンテナを利用できません。署名設定を確認してください。"
      isLoaded = true
      return
    }

    do {
      var store = try PhysicalKeyboardShortcutStore.load(defaults: defaults)
      try store.ensureDefaultShortcuts()
      try store.save(defaults: defaults)
      shortcuts = store.orderedItems
      storageAvailable = true
      notice = nil
    } catch {
      shortcuts = []
      notice = error.localizedDescription
    }
    isLoaded = true
  }

  private func setEnabled(_ enabled: Bool, for id: Int64) {
    guard var item = shortcuts.first(where: { $0.id == id }) else { return }
    item.enabled = enabled
    _ = commit(item, replacing: true)
  }

  private func save(_ item: PhysicalKeyboardShortcutItem) -> String? {
    commit(item, replacing: item.id > 0)
  }

  private func delete(_ id: Int64) {
    do {
      guard let defaults = KeyboardSettings.sharedDefaults else {
        storageAvailable = false
        notice = "ショートカットをキーボード拡張と共有するApp Groupsコンテナを利用できません。署名設定を確認してください。"
        return
      }
      var store = try PhysicalKeyboardShortcutStore.load(defaults: defaults)
      guard store.delete(id: id) else { return }
      try store.save(defaults: defaults)
      shortcuts = store.orderedItems
      notice = nil
    } catch {
      notice = error.localizedDescription
    }
  }

  private func commit(_ item: PhysicalKeyboardShortcutItem, replacing: Bool) -> String? {
    do {
      guard let defaults = KeyboardSettings.sharedDefaults else {
        let message = "ショートカットをキーボード拡張と共有するApp Groupsコンテナを利用できません。署名設定を確認してください。"
        storageAvailable = false
        notice = message
        return message
      }
      var store = try PhysicalKeyboardShortcutStore.load(defaults: defaults)
      let accepted: Bool
      if replacing {
        accepted = store.update(item)
      } else {
        accepted = try store.insert(item)
      }
      guard accepted else {
        let message = "同じキーと修飾キーの割り当てがすでにあります。"
        notice = message
        return message
      }
      try store.save(defaults: defaults)
      shortcuts = store.orderedItems
      notice = nil
      editor = nil
      return nil
    } catch {
      notice = error.localizedDescription
      return error.localizedDescription
    }
  }

  private struct EditorRoute: Identifiable {
    let id = UUID()
    let item: PhysicalKeyboardShortcutItem?
  }
}

private struct PhysicalKeyboardShortcutEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var context: PhysicalKeyboardShortcutContext
  @State private var keyCode: Int
  @State private var action: PhysicalKeyboardShortcutAction
  @State private var ctrl: Bool
  @State private var shift: Bool
  @State private var alt: Bool
  @State private var meta: Bool
  @State private var enabled: Bool
  @State private var notice: String?
  @State private var confirmsDelete = false

  private let item: PhysicalKeyboardShortcutItem?
  private let onSave: (PhysicalKeyboardShortcutItem) -> String?
  private let onDelete: (Int64) -> Void

  private var availableActions: [PhysicalKeyboardShortcutAction] {
    PhysicalKeyboardShortcutAction.available(for: context)
  }

  init(
    item: PhysicalKeyboardShortcutItem?,
    onSave: @escaping (PhysicalKeyboardShortcutItem) -> String?,
    onDelete: @escaping (Int64) -> Void
  ) {
    self.item = item
    self.onSave = onSave
    self.onDelete = onDelete

    let context = PhysicalKeyboardShortcutContext.fromID(item?.contextID)
    let actions = PhysicalKeyboardShortcutAction.available(for: context)
    let action =
      item.flatMap { PhysicalKeyboardShortcutAction.fromID($0.actionID) }
      .flatMap { actions.contains($0) ? $0 : nil } ?? actions[0]
    let keyCode =
      item.flatMap { PhysicalKeyboardShortcutKey.fromKeyCode($0.keyCode)?.keyCode }
      ?? PhysicalKeyboardShortcutKey.allCases[0].keyCode

    _context = State(initialValue: context)
    _keyCode = State(initialValue: keyCode)
    _action = State(initialValue: action)
    _ctrl = State(initialValue: item?.ctrl ?? false)
    _shift = State(initialValue: item?.shift ?? false)
    _alt = State(initialValue: item?.alt ?? false)
    _meta = State(initialValue: item?.meta ?? false)
    _enabled = State(initialValue: item?.enabled ?? true)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("割り当て") {
          Picker("コンテキスト", selection: $context) {
            ForEach(PhysicalKeyboardShortcutContext.allCases, id: \.self) { value in
              Text(value.displayTitle).tag(value)
            }
          }
          .accessibilityIdentifier("physical-shortcut-context")

          Picker("キー", selection: $keyCode) {
            ForEach(PhysicalKeyboardShortcutKey.allCases) { key in
              Text(key.displayLabel(languageCode: locale.language.languageCode?.identifier))
                .tag(key.keyCode)
            }
          }
          .accessibilityIdentifier("physical-shortcut-key")

          Picker("操作", selection: $action) {
            ForEach(availableActions, id: \.self) { value in
              Text(value.displayTitle).tag(value)
            }
          }
          .accessibilityIdentifier("physical-shortcut-action")
        }

        Section("修飾キー") {
          Toggle("Ctrl", isOn: $ctrl)
          Toggle("Shift", isOn: $shift)
          Toggle("Alt", isOn: $alt)
          Toggle("Meta", isOn: $meta)
        }

        Section {
          Toggle("有効", isOn: $enabled)
        }

        if let notice {
          Section {
            Text(notice).foregroundStyle(.red)
          }
        }

        if item != nil {
          Section {
            Button("削除", role: .destructive) { confirmsDelete = true }
              .accessibilityIdentifier("physical-shortcut-delete")
          }
        }
      }
      .navigationTitle(item == nil ? "割り当てを追加" : "割り当てを編集")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存", action: save)
            .accessibilityIdentifier("physical-shortcut-save")
        }
      }
      .onChange(of: context) { _, value in
        let actions = PhysicalKeyboardShortcutAction.available(for: value)
        if !actions.contains(action), let first = actions.first {
          action = first
        }
      }
      .confirmationDialog("この割り当てを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible)
      {
        Button("削除", role: .destructive) {
          if let item { onDelete(item.id) }
          dismiss()
        }
      }
    }
  }

  private func save() {
    let result = onSave(
      PhysicalKeyboardShortcutItem(
        id: item?.id ?? 0,
        contextID: context.id,
        keyCode: keyCode,
        scanCode: nil,
        ctrl: ctrl,
        shift: shift,
        alt: alt,
        meta: meta,
        actionID: action.id,
        enabled: enabled,
        sortOrder: item?.sortOrder ?? Int.max
      )
    )
    if let result {
      notice = result
    } else {
      dismiss()
    }
  }
}

extension PhysicalKeyboardShortcutContext {
  fileprivate var displayTitle: String {
    switch self {
    case .any: return "すべて"
    case .composition: return "未確定入力中"
    case .conversion: return "変換中"
    case .bunsetsuConversion: return "文節変換中"
    }
  }
}

extension PhysicalKeyboardShortcutAction {
  fileprivate var displayTitle: String {
    switch self {
    case .copy: return "コピー"
    case .paste: return "ペースト"
    case .cut: return "切り取り"
    case .selectAll: return "すべて選択"
    case .switchToJapanese: return "日本語に切り替え"
    case .switchToEnglish: return "英語に切り替え"
    case .cycleInputMode: return "入力モードを切り替え"
    case .convert: return "変換"
    case .commit: return "確定"
    case .cancel: return "キャンセル"
    case .convertToHiragana: return "ひらがなに変換"
    case .convertToFullKatakana: return "全角カタカナに変換"
    case .convertToHalfWidth: return "半角に変換"
    case .convertToFullAlphanumeric: return "全角英数字に変換"
    case .convertToHalfAlphanumeric: return "半角英数字に変換"
    case .convertNext: return "次の候補"
    case .convertPrevious: return "前の候補"
    case .segmentFocusLeft: return "文節を左へ移動"
    case .segmentFocusRight: return "文節を右へ移動"
    case .segmentWidthShrink: return "文節を縮小"
    case .segmentWidthExpand: return "文節を拡大"
    }
  }
}

extension PhysicalKeyboardShortcutItem {
  fileprivate var actionTitle: String {
    PhysicalKeyboardShortcutAction.fromID(actionID)?.displayTitle ?? "未対応の操作"
  }

  fileprivate func shortcutTitle(languageCode: String?) -> String {
    let modifiers = [
      (ctrl, "Ctrl"),
      (shift, "Shift"),
      (alt, "Alt"),
      (meta, "Meta"),
    ].compactMap { $0.0 ? $0.1 : nil }
    let key =
      PhysicalKeyboardShortcutKey.fromKeyCode(keyCode)?.displayLabel(languageCode: languageCode)
      ?? "KeyCode \(keyCode)"
    return (modifiers + [key]).joined(separator: " + ")
  }
}
