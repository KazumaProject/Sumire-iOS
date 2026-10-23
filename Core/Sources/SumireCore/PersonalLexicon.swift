import Foundation
import CryptoKit

public struct PersonalWord: Codable, Equatable {
    public var id: Int64?
    public var word: String
    public var reading: String
    public var posIndex: Int
    public var posScore: Int
    public init(word: String, reading: String, posIndex: Int = 0, posScore: Int = 4000) {
        self.word = word; self.reading = reading; self.posIndex = posIndex; self.posScore = posScore
    }
    public func validate() throws {
        guard !reading.isEmpty, !word.isEmpty else { throw PersonalDataError("読みと表記を入力してください") }
        guard reading.utf16.count <= 8192, reading.utf8.count <= 32768, word.utf8.count <= 65536 else {
            throw PersonalDataError("読みまたは表記が長すぎます。文字は切り捨てません")
        }
        guard !reading.contains("\0"), !word.contains("\0"), Int32(exactly: posIndex) != nil, Int32(exactly: posScore) != nil else {
            throw PersonalDataError("文字または品詞・コストの値が不正です")
        }
    }
}

/// User-authored Android-compatible text macro definition.
public struct PersonalTextMacro: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var reading: String?
    public var body: String
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        reading: String? = nil,
        body: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.reading = reading
        self.body = body
        self.enabled = enabled
    }

    public func normalized() -> Self {
        Self(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            reading: reading?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            body: body,
            enabled: enabled
        )
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil else { throw PersonalDataError("定型マクロIDが不正です") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= AndroidTextMacroLimits.name else {
            throw PersonalDataError("名前は1〜\(AndroidTextMacroLimits.name)文字で入力してください")
        }
        guard (reading?.utf16.count ?? 0) <= AndroidTextMacroLimits.reading else {
            throw PersonalDataError("読みは\(AndroidTextMacroLimits.reading)文字以下で入力してください")
        }
        guard body.utf16.count <= AndroidTextMacroLimits.body else {
            throw PersonalDataError("内容は\(AndroidTextMacroLimits.body)文字以下で入力してください")
        }
        _ = try AndroidTextMacroCompiler.compile(body)
    }
}

/// Android's repository queries macro names with SQLite's built-in NOCASE
/// collation, which folds ASCII A–Z only (unlike Unicode lowercasing).
public enum AndroidTextMacroNameComparison {
    public static func sqliteNoCaseKey(_ name: String) -> [UInt8] {
        // SQLite's built-in text collations stop at the first embedded NUL.
        // Keep this as bytes: Swift String equality treats canonically
        // equivalent Unicode spellings as equal, while SQLite NOCASE does not.
        return name.utf8.prefix { $0 != 0 }.map { byte in
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
    }

    public static func androidRootLowercaseKey(_ name: String) -> [UInt16] {
        // Kotlin String equality compares UTF-16 code units, not Swift's
        // canonically-equivalent String values.
        Array(name.lowercased().utf16)
    }
}

public struct PersonalDataError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct PersonalLexicon: Codable, Equatable {
    public var formatVersion = 1
    public var words: [PersonalWord] = []
    public var templates: [PersonalWord] = []
    public var textMacros: [PersonalTextMacro] = []

    private enum CodingKeys: String, CodingKey {
        case formatVersion, words, templates, textMacros
    }

    public init() {}

    /// `textMacros` was added without changing the format version so previously
    /// saved dictionaries and backups continue to load as an empty macro list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        words = try container.decodeIfPresent([PersonalWord].self, forKey: .words) ?? []
        templates = try container.decodeIfPresent([PersonalWord].self, forKey: .templates) ?? []
        textMacros = try container.decodeIfPresent([PersonalTextMacro].self, forKey: .textMacros) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(words, forKey: .words)
        try container.encode(templates, forKey: .templates)
        try container.encode(textMacros, forKey: .textMacros)
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw PersonalDataError("未対応のユーザーデータ形式です") }
        guard words.count + templates.count + textMacros.count <= 100000 else {
            throw PersonalDataError("登録件数の上限は100000件です")
        }
        var bytes = 0
        for group in [words, templates] {
            var seen = Set<String>()
            for entry in group {
                try entry.validate()
                // Length prefix avoids collisions even if the text contains separators.
                let key = "\(entry.reading.utf8.count):" + entry.reading + entry.word
                guard seen.insert(key).inserted else { throw PersonalDataError("同じ読みと表記が重複しています") }
                bytes += entry.reading.utf8.count + entry.word.utf8.count
            }
        }
        var macroIDs = Set<String>()
        var macroNames = Set<[UInt8]>()
        for macro in textMacros {
            try macro.validate()
            guard macroIDs.insert(macro.id).inserted else {
                throw PersonalDataError("定型マクロIDが重複しています")
            }
            guard macroNames.insert(AndroidTextMacroNameComparison.sqliteNoCaseKey(macro.name)).inserted else {
                throw PersonalDataError("同じ名前の定型マクロが重複しています")
            }
            bytes += macro.name.utf8.count + (macro.reading?.utf8.count ?? 0) + macro.body.utf8.count
        }
        guard bytes <= 16 * 1024 * 1024 else { throw PersonalDataError("ユーザーデータの文字容量は16 MiBまでです") }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
public struct PersonalImportPreview {
    public let entries: [PersonalWord]
    public let rejected: Int
    public let errors: [String]
    public let duplicates: Int
    /// Android exports a top-level array of UserWord/UserTemplate records.
    /// Valid rows are staged; callers explicitly apply the preview atomically.
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw PersonalDataError("JSONファイルが大きすぎます") }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any], rows.count <= 100000 else {
            throw PersonalDataError("100000件以下のJSON配列を指定してください")
        }
        var result: [PersonalWord] = [], errors: [String] = []
        var positions: [String: Int] = [:]
        var rejected = 0, duplicates = 0
        for (index, row) in rows.enumerated() {
            do {
                let encoded = try JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed])
                let word = try JSONDecoder().decode(PersonalWord.self, from: encoded)
                try word.validate()
                let key = "\(word.reading.utf8.count):" + word.reading + word.word
                if let position = positions[key] { result[position] = word; duplicates += 1 }
                else { positions[key] = result.count; result.append(word) }
            } catch {
                rejected += 1
                if errors.count < 100 { errors.append("\(index + 1)件目: \(error.localizedDescription)") }
            }
        }
        return Self(entries: result, rejected: rejected, errors: errors, duplicates: duplicates)
    }
}

/// Encodes one Android-compatible user dictionary or template export.
/// Android's import path assigns a fresh database ID to every row, so exported
/// rows use the same `id: 0` placeholder instead of carrying platform-local IDs.
public enum PersonalAndroidListExport {
    private struct Entry: Encodable {
        let id: Int
        let word: String
        let reading: String
        let posIndex: Int
        let posScore: Int
    }

    public static func encode(_ entries: [PersonalWord]) throws -> Data {
        guard entries.count <= 100_000 else { throw PersonalDataError("登録件数の上限は100000件です") }

        var seen = Set<String>()
        var textBytes = 0
        let rows = try entries.map { entry -> Entry in
            try entry.validate()
            let key = "\(entry.reading.utf8.count):" + entry.reading + entry.word
            guard seen.insert(key).inserted else { throw PersonalDataError("同じ読みと表記が重複しています") }
            textBytes += entry.reading.utf8.count + entry.word.utf8.count
            guard textBytes <= 16 * 1024 * 1024 else { throw PersonalDataError("ユーザーデータの文字容量は16 MiBまでです") }
            return Entry(id: 0, word: entry.word, reading: entry.reading,
                         posIndex: entry.posIndex, posScore: entry.posScore)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rows)
        guard data.count <= 32 * 1024 * 1024 else { throw PersonalDataError("JSONファイルが大きすぎます") }
        return data
    }
}

/// Immutable generations plus an atomic pointer. A validated previous pointer is
/// retained for corruption/interrupted-update recovery; generation files are never overwritten.
public struct PersonalLexiconStore {
    public struct Loaded {
        public let lexicon: PersonalLexicon
        public let generation: String
        public let recovered: Bool
    }
    private struct Pointer: Codable { let formatVersion: Int; let file: String; let sha256: String }
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var current: URL { directory.appendingPathComponent("current.json") }
    private var previous: URL { directory.appendingPathComponent("previous.json") }
    private func read(_ url: URL) throws -> (Loaded, Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096 else { throw PersonalDataError("世代情報が不正です") }
        let pointerData = try Data(contentsOf: url)
        let pointer = try JSONDecoder().decode(Pointer.self, from: pointerData)
        guard pointer.formatVersion == 1, pointer.file.hasSuffix(".json"), UUID(uuidString: String(pointer.file.dropLast(5))) != nil else {
            throw PersonalDataError("世代情報の形式が不正です")
        }
        let file = directory.appendingPathComponent(pointer.file)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard let size, size.intValue <= 32 * 1024 * 1024 else { throw PersonalDataError("データファイルが大きすぎます") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard Self.digest(data) == pointer.sha256 else { throw PersonalDataError("ユーザーデータのチェックサムが一致しません") }
        let lexicon = try JSONDecoder().decode(PersonalLexicon.self, from: data)
        try lexicon.validate()
        return (Loaded(lexicon: lexicon, generation: pointer.file, recovered: url == previous), pointerData)
    }
    public func load() throws -> Loaded {
        if !FileManager.default.fileExists(atPath: current.path), !FileManager.default.fileExists(atPath: previous.path) {
            return Loaded(lexicon: PersonalLexicon(), generation: "", recovered: false)
        }
        do { return try read(current).0 }
        catch {
            if let fallback = try? read(previous).0 { return fallback }
            throw error
        }
    }
    @discardableResult public func save(_ lexicon: PersonalLexicon) throws -> Loaded {
        try lexicon.validate()
        let data = try JSONEncoder().encode(lexicon)
        guard data.count <= 32 * 1024 * 1024 else { throw PersonalDataError("保存データが大きすぎます") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = (try? read(current)) ?? (try? read(previous))
        let file = UUID().uuidString.lowercased() + ".json"
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        let pointer = try JSONEncoder().encode(Pointer(formatVersion: 1, file: file, sha256: Self.digest(data)))
        if let old { try old.1.write(to: previous, options: .atomic) }
        try pointer.write(to: current, options: .atomic)
        return Loaded(lexicon: lexicon, generation: file, recovered: false)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
