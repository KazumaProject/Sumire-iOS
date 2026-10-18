import SwiftUI

/// Navigation labels describe user tasks; storage and diagnostics stay in detail screens.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case input, appearance, dictionaries, data, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .input: return "入力"
        case .appearance: return "見た目"
        case .dictionaries: return "辞書と学習"
        case .data: return "データ"
        case .app: return "アプリについて"
        }
    }
    var subtitle: String {
        switch self {
        case .input: return "配列も、指の動きも、自分のペースに。"
        case .appearance: return "色・文字・候補欄を心地よく。"
        case .dictionaries: return "よく使うことばを、すぐそばに。"
        case .data: return "記号・クリップボード・バックアップ。"
        case .app: return "使いはじめの準備とライセンス。"
        }
    }
    var icon: String {
        switch self {
        case .input: return "keyboard"
        case .appearance: return "paintpalette"
        case .dictionaries: return "character.book.closed"
        case .data: return "tray.2"
        case .app: return "info.circle"
        }
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case keyboards, customKeyboard, romaji, specialKeys, conversion, appearance, theme, candidates
    case personalDictionary, dictionaries, learning, symbols, clipboard, backup, setup, licenses
    var id: String { rawValue }
    var category: SettingsCategory {
        switch self {
        case .keyboards, .customKeyboard, .romaji, .specialKeys, .conversion: return .input
        case .appearance, .theme, .candidates: return .appearance
        case .personalDictionary, .dictionaries, .learning: return .dictionaries
        case .symbols, .clipboard, .backup: return .data
        case .setup, .licenses: return .app
        }
    }
    var title: String {
        switch self {
        case .keyboards: return "キーボードの選択・順序"
        case .customKeyboard: return "Custom Keyboard"
        case .romaji: return "カスタムローマ字"
        case .specialKeys: return "Sumire の特殊キー操作"
        case .conversion: return "入力と変換"
        case .appearance: return "キー・文字サイズ"
        case .theme: return "キーボードの配色"
        case .candidates: return "候補欄の段数"
        case .personalDictionary: return "ユーザー辞書・定型文"
        case .dictionaries: return "分類辞書・英語辞書"
        case .learning: return "変換の学習"
        case .symbols: return "記号・クリップボード"
        case .clipboard: return "クリップボードの自動表示"
        case .backup: return "辞書のバックアップ"
        case .setup: return "キーボードの準備と共有"
        case .licenses: return "ライセンス・出典"
        }
    }
    var subtitle: String {
        switch self {
        case .keyboards: return "使う配列を選んで、好きな順番に"
        case .customKeyboard: return "自分だけの配列を作成・編集"
        case .romaji: return "ローマ字からかなへの変換ルール"
        case .specialKeys: return "タップ・フリック・長押しの動作"
        case .conversion: return "ライブ変換、修飾キー省略、削除の区切り"
        case .appearance: return "通常キー・特殊キーとフリックガイド"
        case .theme: return "好きな色とライト・ダーク表示"
        case .candidates: return "候補を1・2・3段で表示"
        case .personalDictionary: return "名前、よく使うことば、決まり文句"
        case .dictionaries: return "30のカテゴリと英語の読みを選択"
        case .learning: return "学習の有効化と履歴の削除"
        case .symbols: return "最初に開くタブ、肌色、履歴の保存"
        case .clipboard: return "コピーした文字・画像の表示方法"
        case .backup: return "設定と辞書を保存・復元"
        case .setup: return "有効化の手順と設定の保存先を確認"
        case .licenses: return "コード・辞書・画像の出典"
        }
    }
    var icon: String {
        switch self {
        case .keyboards: return "list.bullet"
        case .customKeyboard: return "square.grid.3x3"
        case .romaji: return "textformat.abc"
        case .specialKeys: return "hand.draw"
        case .conversion: return "character.cursor.ibeam"
        case .appearance: return "textformat.size"
        case .theme: return "paintpalette"
        case .candidates: return "rectangle.split.3x1"
        case .personalDictionary: return "book.closed"
        case .dictionaries: return "books.vertical"
        case .learning: return "sparkles"
        case .symbols: return "face.smiling"
        case .clipboard: return "clipboard"
        case .backup: return "externaldrive"
        case .setup: return "checklist"
        case .licenses: return "doc.text"
        }
    }
    func matches(_ query: String) -> Bool {
        [title, subtitle, category.title].contains { $0.localizedStandardContains(query) }
    }
}

struct SettingsDashboardView: View {
    let sharingAvailable: Bool
    let openPreview: () -> Void
    let open: (SettingsDestination) -> Void
    @State private var query = ""
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if search.isEmpty {
                    welcome
                    Button(action: openPreview) {
                        HStack(spacing: 14) {
                            Image(systemName: "keyboard").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("キーボードを試す").font(.headline)
                                Text("文字を打って、使い心地を確かめる").font(.subheadline)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }
                        .foregroundStyle(.white).padding(20)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .background(LinearGradient(colors: [.purple, Color(red: 0.38, green: 0.25, blue: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("settings-preview")
                    Button { open(.setup) } label: {
                        Label(sharingAvailable ? "設定の共有先を確認" : "設定の共有は未設定です", systemImage: sharingAvailable ? "checkmark.circle" : "info.circle")
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("settings-sharing-status")
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink(value: category) {
                            HStack(alignment: .center, spacing: 16) {
                                Image(systemName: category.icon).font(.title2).foregroundStyle(.purple)
                                    .frame(width: 44, height: 44).background(.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(category.title).font(.headline).foregroundStyle(.primary)
                                    Text(category.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                            .padding(18).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("settings-category-" + category.rawValue)
                    }
                } else {
                    let matches = SettingsDestination.allCases.filter { $0.matches(search) }
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ForEach(matches) { item in SettingsDestinationRow(item: item) { open(item) } }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sumire")
        .searchable(text: $query, prompt: "色・配列・辞書などを検索")
        .navigationDestination(for: SettingsCategory.self) { category in
            List {
                Section {
                    ForEach(SettingsDestination.allCases.filter { $0.category == category }) { item in
                        SettingsDestinationRow(item: item) { open(item) }
                    }
                } header: { Text(category.subtitle).textCase(nil) }
            }
            .navigationTitle(category.title)
        }
    }
    private var welcome: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("SumireLogo.png").resizable().scaledToFit().frame(width: 52, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sumireを、あなたらしく。").font(.title3.bold())
                Text("お気に入りの入力を育てましょう。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsDestinationRow: View {
    let item: SettingsDestination
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: item.icon).foregroundStyle(.purple).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).foregroundStyle(.primary)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 6)
        }
        .accessibilityIdentifier("settings-destination-" + item.rawValue)
        .accessibilityElement(children: .combine)
    }
}
