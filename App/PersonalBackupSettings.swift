import SwiftUI
import UniformTypeIdentifiers
import SumireCore

private struct PersonalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PersonalDataError("ファイルを読み込めません") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PersonalBackupSettings: View {
    @ObservedObject var library: PersonalLibrary
    var onRestore: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var document: PersonalBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var staged: PersonalBackup.Contents?
    @State private var stagedAndroid: AndroidPreferenceBackup?
    @State private var confirming = false
    @State private var confirmingAndroidSettings = false
    @State private var message: String?
    @State private var processing = false
    var body: some View {
        NavigationStack {
            Form {
                Text("ユーザー辞書・定型文と入力設定をJSONファイルに保存します。配色、キーサイズ、配列・ローマ字、辞書の有効設定を含みます。学習データも含みます。標準・外部辞書の本体は含みません。")
                Text("Android版の設定バックアップJSONも選択できます。iOS対応の設定を取り込み、バックアップに記録されていない対応設定はAndroidの既定値に戻します。未対応の設定やツールバー項目、iOS専用設定、辞書、学習データは変更しません。")
                Text("単語：\(library.lexicon.words.count)件／定型文：\(library.lexicon.templates.count)件")
                Button("バックアップを保存") {
                    processing = true; message = nil
                    library.exportBackup { result in
                        processing = false
                        switch result {
                        case .success(let data): document = PersonalBackupDocument(data: data); exporting = true
                        case .failure(let error): message = error.localizedDescription
                        }
                    }
                }.disabled(!library.writable || processing)
                Button("バックアップから復元") { importing = true }.disabled(processing)
                if processing { ProgressView("バックアップを処理中…") }
                if let notice = library.notice { Text(notice).foregroundStyle(.red) }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("辞書のバックアップ")
            .toolbar { Button("完了") { dismiss() }.disabled(processing) }
            .interactiveDismissDisabled(processing)
            .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                          defaultFilename: "Sumire-backup") { result in
                switch result {
                case .success: message = "バックアップを保存しました"
                case .failure(let error): message = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    processing = true; message = nil
                    PersonalLibrary.readBackup(url) { result in
                        processing = false
                        switch result {
                        case .success(.sumire(let contents)):
                            stagedAndroid = nil
                            staged = contents
                            confirming = true
                        case .success(.androidSettings(let backup)):
                            staged = nil
                            stagedAndroid = backup
                            confirmingAndroidSettings = true
                        case .failure(let error):
                            staged = nil
                            stagedAndroid = nil
                            message = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    staged = nil
                    stagedAndroid = nil
                    message = error.localizedDescription
                }
            }
            .alert("辞書を復元しますか？", isPresented: $confirming) {
                Button("キャンセル", role: .cancel) { staged = nil }
                Button("置き換えて復元", role: .destructive) {
                    guard let staged else { return }
                    processing = true; message = nil
                    library.restoreBackup(staged) { result in
                        processing = false
                        switch result {
                        case .success:
                            onRestore()
                            message = "ユーザー辞書・定型文を復元しました" + (staged.settings == nil ? "（設定は変更していません）" : "（入力設定を含む）") + (staged.learning == nil ? "" : "（学習データを含む）")
                        case .failure(let error): message = error.localizedDescription
                        }
                    }
                    self.staged = nil
                }
            } message: {
                Text("現在の登録を、単語\(staged?.lexicon.words.count ?? 0)件・定型文\(staged?.lexicon.templates.count ?? 0)件に置き換えます。\(staged?.settings == nil ? "設定は変更しません。" : "入力設定もバックアップの内容に置き換えます。")\(staged?.learning == nil ? "学習データは変更しません。" : "学習データも置き換えます。")必要な場合は先に現在のバックアップを保存してください。")
            }
            .confirmationDialog("Android設定を取り込みますか？", isPresented: $confirmingAndroidSettings, titleVisibility: .visible) {
                if stagedAndroidClipboardExpiryWarningHours != nil {
                    Button("期限切れ履歴が削除される可能性を承知して取り込む", role: .destructive) {
                        applyStagedAndroidSettings()
                    }
                } else {
                    Button("対応する設定を取り込む") {
                        applyStagedAndroidSettings()
                    }
                }
                Button("キャンセル", role: .cancel) { stagedAndroid = nil }
            } message: {
                Text(androidImportConfirmationMessage)
            }
        }
    }

    private func restoreAndroidSettings(_ backup: AndroidPreferenceBackup) {
        processing = true
        message = nil
        library.restoreAndroidSettings(backup) { result in
            processing = false
            switch result {
            case .success(let count):
                onRestore()
                message = "Android設定からiOS対応の \(count) 項目を取り込みました。\(androidToolbarResultMessage(backup)) 未対応のAndroid設定は変更していません。"
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func applyStagedAndroidSettings() {
        guard let stagedAndroid else { return }
        restoreAndroidSettings(stagedAndroid)
        self.stagedAndroid = nil
    }

    private var androidImportConfirmationMessage: String {
        var text = "iOS対応の設定 \(stagedAndroid?.importedSettingCount ?? 0) 項目を取り込み、記録されていない設定はAndroidの既定値に戻します。未対応のAndroid設定 \(stagedAndroid?.unsupportedEntryCount ?? 0) 項目は変更しません。\(androidToolbarConfirmationMessage) iOS専用設定、辞書、学習データは変更しません。"
        if let hours = stagedAndroidClipboardExpiryWarningHours {
            text += "取込後は期限削除が有効で、\(hours)時間を超えた未固定のクリップボード履歴がキーボード側の次回読み込み時に削除される場合があります。"
        }
        return text
    }

    private var androidToolbarConfirmationMessage: String {
        guard let backup = stagedAndroid else { return "" }
        guard let shortcutIDs = backup.shortcutIDs else {
            return "AndroidバックアップにツールバーIDがないため、現在のiOSツールバー配置を維持します。"
        }
        guard let toolbarImport = backup.toolbarShortcutImport, !toolbarImport.actions.isEmpty else {
            let fallback = shortcutIDs.isEmpty ? "Android側の「設定」既定" : "このID一覧"
            return "\(fallback)に対応するiOSキーボード操作がないため、現在のiOSツールバー配置を維持します。"
        }
        let skipped = toolbarImport.unsupportedIDs.count
        let skippedText = skipped == 0 ? "" : "。iOSに対応する動作がないID \(skipped) 件はスキップします"
        return "ツールバーは対応する \(toolbarImport.actions.count) 項目をAndroidの順序で取り込みます\(skippedText)。"
    }

    private func androidToolbarResultMessage(_ backup: AndroidPreferenceBackup) -> String {
        guard let shortcutIDs = backup.shortcutIDs else {
            return "ツールバーIDが記録されていないため、iOSの配置は維持しました。"
        }
        guard let toolbarImport = backup.toolbarShortcutImport, !toolbarImport.actions.isEmpty else {
            let fallback = shortcutIDs.isEmpty ? "Androidの設定ショートカット既定" : "AndroidツールバーID"
            return "対応するツールバー操作がないため、iOSの配置は維持しました（\(fallback)）。"
        }
        let skippedText = toolbarImport.unsupportedIDs.isEmpty ? "" : "。未対応ID \(toolbarImport.unsupportedIDs.count) 件はスキップしました"
        return "対応するツールバー \(toolbarImport.actions.count) 項目をAndroidの順序で設定しました\(skippedText)。"
    }

    private var stagedAndroidClipboardExpiryWarningHours: Int? {
        stagedAndroid?.clipboardExpiryDeletionWarningHours(currentDefaults: KeyboardSettings.appDefaults)
    }
}
