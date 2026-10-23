import Foundation

/// Filename planning only: no payload is trusted or published by this API.
/// Reference: 9506a0b DictionaryZipEntryNameMapper/DictionaryModels/ClassifiedDictionaries.
public struct DictionaryArchivePlan {
    public enum Group: Hashable {
        case common, system, category(String), english, englishReading, readingCorrection
        public var id: String {
            switch self {
            case .common: return "common"
            case .system: return "system"
            case .category(let id): return "categories/" + id
            case .english: return "english"
            case .englishReading: return "english_reading"
            case .readingCorrection: return "reading_correction"
            }
        }
        public var requiredRoles: [Role] {
            switch self {
            case .common: return [.connection, .posTable]
            case .english: return [.reading, .word, .token]
            default: return [.tango, .yomi, .token]
            }
        }
    }
    public enum Role: String, Hashable { case tango, yomi, token, reading, word, connection, posTable }
    public enum Container: Equatable { case rawData, nestedZIP }
    public struct Key: Hashable {
        public let group: Group
        public let role: Role
        public init(group: Group, role: Role) { self.group = group; self.role = role }
    }
    public struct MappedEntry: Equatable {
        public let entryName: String
        public let key: Key
        public let container: Container
    }
    public enum Resolution: Equatable {
        case mapped(MappedEntry)
        case ignored(String), unknown(String), unsupported(String), unsafe(String)
    }
    public struct EntryResult: Equatable {
        public let entryName: String
        public let resolution: Resolution
    }
    public struct Duplicate: Equatable {
        public let key: Key
        public let entryNames: [String]
    }
    public struct GroupPlan: Equatable {
        public let group: Group
        public let entries: [MappedEntry]
        public let missingRoles: [Role]
        public let duplicates: [Duplicate]
        /// The complete, unambiguous group still needs binary/schema validation.
        public var canValidate: Bool { missingRoles.isEmpty && duplicates.isEmpty }
    }
    public static let categoryIDs = [
        "person", "character", "mythological_figure", "place", "address", "station", "facility",
        "transport_route", "organization", "lineage", "product", "vehicle", "event", "award",
        "agreement", "initiative", "term", "work_franchise", "work_manga", "work_anime", "work_film",
        "work_program", "work_book", "work_game", "work_music", "work_stage", "work_periodical",
        "work_other", "kampo", "medical"
    ]
    public let entryResults: [EntryResult]
    public let groups: [GroupPlan]
    /// Validate every candidate first, then publish successful groups in one atomic batch.
    public var validationCandidates: [GroupPlan] { groups.filter(\.canValidate) }
    public var duplicates: [Duplicate] { groups.flatMap(\.duplicates) }
    public var recognizedEntries: Int { groups.reduce(0) { $0 + $1.entries.count } }

    public init(entryNames: [String]) throws {
        guard entryNames.count <= 4096 else { throw PersonalDataError("辞書ZIPの項目数が上限を超えています") }
        var results: [EntryResult] = [], mapped: [Group: [MappedEntry]] = [:], order: [Group] = []
        for name in entryNames {
            let resolution = Self.resolve(name)
            results.append(.init(entryName: name, resolution: resolution))
            if case .mapped(let entry) = resolution {
                if mapped[entry.key.group] == nil { order.append(entry.key.group) }
                mapped[entry.key.group, default: []].append(entry)
            }
        }
        entryResults = results
        groups = order.map { group in
            let entries = mapped[group]!
            let duplicates = group.requiredRoles.compactMap { role -> Duplicate? in
                let matches = entries.filter { $0.key.role == role }
                return matches.count > 1 ? .init(key: .init(group: group, role: role), entryNames: matches.map(\.entryName)) : nil
            }
            return .init(group: group, entries: entries,
                         missingRoles: group.requiredRoles.filter { role in !entries.contains { $0.key.role == role } },
                         duplicates: duplicates)
        }
    }

    public static func resolve(_ entryName: String) -> Resolution {
        // Also guard direct callers; normalization must never hide traversal or separators.
        guard !entryName.isEmpty, entryName.utf8.count <= 4096,
              !entryName.hasPrefix("/"), !entryName.contains("\\"), !entryName.contains(":"),
              !entryName.contains("\0") else { return .unsafe("絶対パス・不正な区切り・空または長すぎる名前です") }
        let parts = entryName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.dropLast().contains(""), !parts.contains("."), !parts.contains("..") else {
            return .unsafe("親ディレクトリ参照・空のパス要素は使用できません")
        }
        let path = parts.map { $0.lowercased() }
        guard let basename = path.last else { return .unsafe("項目名がありません") }
        if basename.isEmpty { return .ignored("ディレクトリ項目です") }
        if path.contains("__macosx") || basename == ".ds_store" || basename.hasPrefix("._") {
            return .ignored("macOSの付加情報です")
        }
        let nested = basename.hasSuffix(".dat.zip")
        let raw = nested ? String(basename.dropLast(4)) : basename
        func mapped(_ group: Group, _ role: Role) -> Resolution {
            .mapped(.init(entryName: entryName, key: .init(group: group, role: role), container: nested ? .nestedZIP : .rawData))
        }
        let trio: [String: Role] = ["tango.dat": .tango, "yomi.dat": .yomi, "token.dat": .token]
        // A classified path never falls back to the system basename aliases.
        if let index = path.firstIndex(of: "categories") {
            let tail = Array(path[index...])
            guard tail.count == 3, categoryIDs.contains(tail[1]), let role = trio[raw] else {
                return .unknown("分類辞書のカテゴリ名またはファイル役割を認識できません")
            }
            return mapped(.category(tail[1]), role)
        }
        let readingCorrectionRoles: [String: Role] = [
            "tango_reading_correction.dat": .tango,
            "yomi_reading_correction.dat": .yomi,
            "token_reading_correction.dat": .token
        ]
        if let index = path.firstIndex(of: "reading_correction") {
            let tail = Array(path[index...])
            guard tail.count == 2, let role = readingCorrectionRoles[tail[1]] else {
                return .unknown("読み補正辞書のファイル名を認識できません")
            }
            return mapped(.readingCorrection, role)
        }
        if let role = readingCorrectionRoles[basename] { return mapped(.readingCorrection, role) }

        let unsupported = ["single_kanji", "emoji", "emoticon", "symbol", "kotowaza"]
        if let group = path.dropLast().first(where: { unsupported.contains($0) }) {
            return .unsupported("\(group)辞書の差し替えは現在のiOS取込で未対応です")
        }
        for suffix in ["singlekanji", "emoji", "emoticon", "symbol", "kotowaza"] {
            if ["tango", "yomi", "token"].contains(where: { raw == "\($0)_\(suffix).dat" }) {
                return .unsupported("\(suffix)の旧形式辞書は現在のiOS取込で未対応です")
            }
        }
        if raw == "id.def" { return .unsupported("id.defによる品詞定義の差し替えは未対応です") }
        if raw == "qwerty_glide_index.dat" { return .unsupported("Androidの英字グライド索引はiOSで使用しません") }
        if raw == "connectionid.dat" { return mapped(.common, .connection) }
        if raw == "pos_table.dat" { return mapped(.common, .posTable) }
        if let index = path.firstIndex(where: { ["system", "english", "english_reading"].contains($0) }) {
            guard path.count - index == 2 else { return .unknown("辞書グループ内のパスを認識できません") }
            switch path[index] {
            case "english":
                guard let role = ["reading.dat": Role.reading, "word.dat": .word, "token.dat": .token][raw] else {
                    return .unknown("英語辞書のファイル役割を認識できません")
                }
                return mapped(.english, role)
            case "english_reading":
                guard let role = trio[raw] else { return .unknown("英語読み辞書のファイル役割を認識できません") }
                return mapped(.englishReading, role)
            default:
                guard let role = trio[raw] else { return .unknown("システム辞書のファイル役割を認識できません") }
                return mapped(.system, role)
            }
        }
        if let role = trio[raw] { return mapped(.system, role) }
        return .unknown("対応する辞書ファイル役割がありません: " + basename)
    }
}
