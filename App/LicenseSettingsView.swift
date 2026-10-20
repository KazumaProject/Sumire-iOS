import SwiftUI
import SumireCore

/// Reads the notices shipped with the actual dictionary bundle. No web view or URL request is used.
struct LicenseSettingsView: View {
    private let catalog = LicenseCatalog()

    var body: some View {
        List {
            Section {
                Text("このアプリに同梱したライセンスと出典を、ネットワークに接続せず表示します。辞書データにはプログラムとは別の利用条件があります。通知中の未確認事項は、確認済みを意味しません。")
                    .font(.footnote)
            }
            Section("プログラム・画像・アイコン") {
                notice("Sumire 変換コア・入力コア", url: Bundle.main.url(forResource: "SumireCoreLicense", withExtension: "txt"))
                notice("アプリのロゴ", url: Bundle.main.url(forResource: "SumireAssetLicense", withExtension: "txt"))
                notice("Noto Serif Hentaigana — SIL OFL 1.1", url: Bundle.main.url(forResource: "NotoSerifHentaigana-OFL", withExtension: "txt"))
                notice("変体仮名フォントの出典・SHA-256", url: Bundle.main.url(forResource: "NotoSerifHentaigana-Source", withExtension: "txt"))
                NavigationLink("スミレ入力スタイルの定義・出典") {
                    ScrollView { Text(ReferenceFlickMaps.provenanceNotice).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding() }
                        .navigationTitle("入力スタイルの出典")
                }
                notice("特殊キーのアイコン", url: Bundle.main.url(forResource: "KeyboardIconsNotice", withExtension: "txt"))
                notice("Material Color Utilities の出典", url: MaterialColorUtilitiesNotice.attributionURL)
                notice("Material Color Utilities — Apache 2.0", url: MaterialColorUtilitiesNotice.licenseURL)
            }
            Section("絵文字・顔文字・記号") {
                notice("収録データ・出典・変更内容", url: SymbolKeyboardCatalog.noticeURL)
                notice("辞書データのライセンス原文", url: SymbolKeyboardCatalog.dataLicenseURL)
                notice("肌色の対応データ・出典", url: EmojiSkinToneVariants.noticeURL)
            }
            Section("英語辞書") {
                Text("英単語辞書は収録しています。固定Android参照のリビジョン、`english/word.dat`のパスとSHA-256は特定済みです。一方、`word.dat`の収録語の元データとその版、各語の帰属、適用ライセンスは未確認です。旧WikiText通知は現在の`word.dat`への適用が確認できるまで、参考情報として区別して表示します。英語読み辞書は別の通知を確認してください。")
                    .font(.footnote)
                    .accessibilityIdentifier("english-dictionary-license-status")
                if let url = catalog.englishWordNotice {
                    notice("英単語辞書の配布通知", url: url, identifier: "english-word-dictionary-notice")
                } else {
                    Text("英単語辞書の配布通知を読み込めません。")
                        .foregroundStyle(.red)
                }
                notice("旧WikiText通知（現行資産への適用範囲未確認）",
                       url: Bundle.main.url(forResource: "EnglishDictionarySourceNotice", withExtension: "txt"),
                       identifier: "english-legacy-wikitext-notice")
                if let url = catalog.englishReadingNotice {
                    notice("英語読み辞書の配布通知", url: url, identifier: "english-reading-dictionary-notice")
                }
            }
            Section("同梱辞書") {
                if let root = catalog.dictionaryRoot {
                    notice("辞書の生成元・資産ハッシュ", url: root.appendingPathComponent("manifest.json"))
                    notice("参照プログラムのライセンス", url: root.appendingPathComponent("SOURCE-LICENSE"))
                    ForEach(catalog.dictionaryNotices, id: \.path) { url in
                        notice(catalog.title(for: url), url: url)
                    }
                } else {
                    Text("同梱辞書の通知を読み込めません。配布データが不足しています。")
                        .foregroundStyle(.red)
                }
            }
            Section("分類辞書（30 カテゴリ）") {
                ForEach(catalog.categoryNotices, id: \.path) { url in
                    notice(catalog.title(for: url), url: url)
                }
            }
            Section("出典の通知・ライセンス原文") {
                ForEach(catalog.sourceNotices, id: \.path) { url in
                    notice(url.deletingPathExtension().lastPathComponent, url: url)
                }
                if let root = catalog.dictionaryRoot {
                    notice("通知の出典 URL・SHA-256", url: root.appendingPathComponent("licenses/notice-snapshots.json"))
                }
            }
        }
        .navigationTitle("ライセンス・出典")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("license-settings")
    }

    @ViewBuilder
    private func notice(_ title: String, url: URL?, identifier: String? = nil) -> some View {
        if let identifier {
            NavigationLink {
                LicenseNoticeView(title: title, url: url)
            } label: {
                Text(title)
            }
            .accessibilityIdentifier(identifier)
        } else {
            NavigationLink {
                LicenseNoticeView(title: title, url: url)
            } label: {
                Text(title)
            }
        }
    }
}

private struct LicenseNoticeView: View {
    let title: String
    let url: URL?

    var body: some View {
        ScrollView {
            Text(verbatim: contents)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("license-notice-text")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("license-notice")
    }

    private var contents: String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "この通知ファイルを読み込めません。配布データが不足しているか、破損しています。"
        }
        return url.pathExtension.lowercased() == "html" ? LicenseCatalog.plainText(text) : text
    }
}

private struct LicenseCatalog {
    let dictionaryRoot: URL?

    init(bundle: Bundle = .main) {
        let containers = [
            bundle.bundleURL,
            bundle.bundleURL.appendingPathComponent("PlugIns/SumireKeyboard.appex", isDirectory: true)
        ]
        let manager = FileManager.default
        dictionaryRoot = containers.lazy.flatMap { container -> [URL] in
            let children = (try? manager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let directories = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return [container] + directories
        }.first { directory in
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return manifest["source_revision"] is String && manifest["output_sha256"] is [String: String]
        }
    }

    var dictionaryNotices: [URL] {
        files(in: "licenses", extension: "html").filter {
            !["english.html", "english-reading.html"].contains($0.lastPathComponent)
        }
    }
    var englishWordNotice: URL? { dictionaryRoot?.appendingPathComponent("licenses/english.html") }
    var englishReadingNotice: URL? { dictionaryRoot?.appendingPathComponent("licenses/english-reading.html") }
    var categoryNotices: [URL] { files(in: "licenses/classified", extension: "html") }
    var sourceNotices: [URL] { files(in: "licenses/sources", extension: "txt") }

    private func files(in directory: String, extension suffix: String) -> [URL] {
        guard let root = dictionaryRoot,
              let urls = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == suffix }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func title(for url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let range = text.range(of: "(?is)<title>.*?</title>", options: .regularExpression) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return Self.plainText(String(text[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preserve link destinations as text; HTML is never executed or passed to a network-capable renderer.
    static func plainText(_ html: String) -> String {
        var result = html.replacingOccurrences(of: "(?is)<(style|script)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?is)<a\\b[^>]*href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>", with: "$2 ($1)", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)</(?:p|h[1-6]|pre|div|li|title)>|<br\\s*/?>", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        if let expression = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: result) else { continue }
                let number = String(result[numberRange])
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
