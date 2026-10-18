import SwiftUI

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
                notice("特殊キーのアイコン", url: Bundle.main.url(forResource: "KeyboardIconsNotice", withExtension: "txt"))
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

    private func notice(_ title: String, url: URL?) -> some View {
        NavigationLink {
            LicenseNoticeView(title: title, url: url)
        } label: {
            Text(title)
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
        let candidates = [
            bundle.bundleURL.appendingPathComponent("cli-english-v1", isDirectory: true),
            bundle.bundleURL.appendingPathComponent("PlugIns/SumireKeyboard.appex/cli-english-v1", isDirectory: true)
        ]
        dictionaryRoot = candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
    }

    var dictionaryNotices: [URL] { files(in: "licenses", extension: "html") }
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
