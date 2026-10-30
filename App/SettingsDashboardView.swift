import SwiftUI
import UIKit

enum SettingsBrand {
    static let purple = Color(red: 0.48, green: 0.29, blue: 0.70)
}

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
    case keyboards, toolbar, customKeyboard, romaji, specialKeys, physicalShortcuts, conversion, touchFeedback, flickStyle, appearance, theme, candidates
    case personalDictionary, textMacros, dictionaries, dictionaryBrowser, learning, symbols, clipboard, backup, setup, licenses
    var id: String { rawValue }
    var category: SettingsCategory {
        switch self {
        case .keyboards, .toolbar, .customKeyboard, .romaji, .specialKeys, .physicalShortcuts, .conversion, .touchFeedback, .flickStyle: return .input
        case .appearance, .theme, .candidates: return .appearance
        case .personalDictionary, .textMacros, .dictionaries, .dictionaryBrowser, .learning: return .dictionaries
        case .symbols, .clipboard, .backup: return .data
        case .setup, .licenses: return .app
        }
    }
    var title: String {
        switch self {
        case .keyboards: return "キーボードの選択・順序"
        case .toolbar: return "ツールバーの項目と順序"
        case .customKeyboard: return "Custom Keyboard"
        case .romaji: return "カスタムローマ字"
        case .specialKeys: return "Sumire の特殊キー操作"
        case .physicalShortcuts: return "物理キーボードのショートカット"
        case .conversion: return "入力と変換"
        case .flickStyle: return "スミレ入力のスタイル"
        case .touchFeedback: return "入力の操作と表示"
        case .appearance: return "キー・文字サイズ"
        case .theme: return "キーボードの配色"
        case .candidates: return "候補欄の段数"
        case .personalDictionary: return "ユーザー辞書・定型文"
        case .textMacros: return "定型マクロ"
        case .dictionaryBrowser: return "辞書の単語を見る"
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
        case .toolbar: return "キーボード上部の操作を選んで並べ替え"
        case .customKeyboard: return "自分だけの配列を作成・編集"
        case .romaji: return "ローマ字からかなへの変換ルール"
        case .specialKeys: return "タップ・フリック・長押しの動作"
        case .physicalShortcuts: return "外付けキーボードのキー割り当て"
        case .flickStyle: return "二段・三段・ドーナツとガイドの操作"
        case .conversion: return "ライブ変換、文節ごとの変換、修飾キー省略、削除の区切り"
        case .touchFeedback: return "ポップアップ・二本指・長押し時間"
        case .appearance: return "通常キー・特殊キーとフリックガイド"
        case .theme: return "好きな色とライト・ダーク表示"
        case .candidates: return "候補を1・2・3段で表示"
        case .personalDictionary: return "名前、よく使うことば、決まり文句"
        case .textMacros: return "読み・日付・選択文字を含めて展開"
        case .dictionaryBrowser: return "収録した読み・表記を検索して確認"
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
        case .toolbar: return "ellipsis.rectangle"
        case .customKeyboard: return "square.grid.3x3"
        case .romaji: return "textformat.abc"
        case .specialKeys: return "hand.draw"
        case .physicalShortcuts: return "keyboard.badge.ellipsis"
        case .flickStyle: return "hand.point.up.left"
        case .conversion: return "character.cursor.ibeam"
        case .touchFeedback: return "hand.point.up.left"
        case .appearance: return "textformat.size"
        case .theme: return "paintpalette"
        case .candidates: return "rectangle.split.3x1"
        case .personalDictionary: return "book.closed"
        case .textMacros: return "text.badge.plus"
        case .dictionaryBrowser: return "text.book.closed"
        case .dictionaries: return "books.vertical"
        case .learning: return "sparkles"
        case .symbols: return "face.smiling"
        case .clipboard: return "clipboard"
        case .backup: return "externaldrive"
        case .setup: return "checklist"
        case .licenses: return "doc.text"
        }
    }
    private var searchTerms: String {
        switch self {
        case .keyboards: return "テンキー TenKey QWERTY 50音 五十音 Sumire 配列"
        case .toolbar: return "ショートカット toolbar shortcut 並べ替え"
        case .customKeyboard: return "カスタム 配列 編集 JSON"
        case .conversion: return "文節 文節区切り 文節ごと かな漢字変換 先読み 予測 積極性"
        case .touchFeedback: return "フリック ポップアップ popup マルチタッチ 二本指 長押し"
        case .appearance: return "フォント ガイド フリック 通常キー 特殊キー 大きさ"
        case .theme: return "マテリアル Material ライト ダーク 色"
        case .symbols: return "絵文字 顔文字 記号 肌色 履歴 clipboard"
        case .setup: return "フルアクセス App Groups 有効化 設定共有"
        case .backup: return "インポート エクスポート 保存 復元"
        case .dictionaries: return "分類 英語読み ことわざ 諺 kotowaza"
        default: return ""
        }
    }
    func matches(_ query: String) -> Bool {
        [title, subtitle, category.title, searchTerms].contains { $0.localizedStandardContains(query) }
    }
}

struct SettingsDashboardView: View {
    let sharingAvailable: Bool
    let hasDataNotice: Bool
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
                            Image(systemName: "keyboard").font(.title2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("キーボードを試す").font(.headline)
                                Text("文字を打って、使い心地を確かめる").font(.subheadline)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").accessibilityHidden(true)
                        }
                        .foregroundStyle(.white).padding(20)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .background(LinearGradient(colors: [Color(red: 0.48, green: 0.29, blue: 0.70), Color(red: 0.38, green: 0.25, blue: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("settings-preview")
                    Button { open(.setup) } label: {
                        Label(sharingAvailable ? "設定の共有先を確認" : "設定を共有できません", systemImage: sharingAvailable ? "checkmark.circle" : "info.circle")
                            .font(.subheadline).foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("settings-sharing-status")
                    if hasDataNotice {
                        Button { open(.setup) } label: {
                            Label("保存データの状態を確認", systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("settings-data-notice")
                    }
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink(value: category) {
                            HStack(alignment: .center, spacing: 16) {
                                Image(systemName: category.icon).accessibilityHidden(true).font(.title2).foregroundStyle(SettingsBrand.purple)
                                    .frame(width: 44, height: 44).background(SettingsBrand.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
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
            Image(uiImage: UIImage(named: "SumireLogo.png") ?? UIImage()).renderingMode(.original).resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
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
                Image(systemName: item.icon).foregroundStyle(SettingsBrand.purple).frame(width: 28).accessibilityHidden(true)
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
